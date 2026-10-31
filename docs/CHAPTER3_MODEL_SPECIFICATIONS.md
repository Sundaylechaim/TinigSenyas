# Chapter 3: System Methodology & AI Model Technical Specifications

**Project Title:** TinigSenyas: Filipino Sign Language (FSL) Translation & E-Learning Module  
**Institution:** Eulogio "Amang" Rodriguez Institute of Science and Technology (EARIST)  
**Community Partner:** KAINAKAP Inclusive and Opportunity Inc.  
**Model Checkpoint:** `best_fsl_model.keras` / `fsl_model.tflite`  
**Vocabulary Capacity:** 127 FSL Classes (Letters A–Z, Numbers, and Transactional Phrases)

---

## 1. System Pipeline Overview

TinigSenyas implements an end-to-end computer vision and deep learning pipeline designed to translate Filipino Sign Language in real-time. The framework continuously samples video input, maps spatial anatomical joints using Google MediaPipe Tasks, normalizes user posture, and feeds graph-structured temporal representations into a **Spatial-Temporal Graph Convolutional Network (ST-GCN)**.

```
+-----------------------------------------------------------------------------------+
|                              1. Video Ingestion                                    |
|              Webcam / Mobile Camera Input (640x480 @ 30 FPS)                      |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                        2. MediaPipe Landmark Extraction                           |
|      - Pose Landmarker Lite: 33 body coordinates                                  |
|      - Hand Landmarker: 21 left-hand joints + 21 right-hand joints                |
|      - Output: 75 anatomical joints per frame [V = 75, C = 3 (x, y, z)]           |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                   3. Posture Normalization & Hand Mirroring                       |
|      - Shoulder Normalization: Translated to mid-shoulder, scaled by width        |
|      - Canonical Hand Mirroring: Left-hand signs horizontally mirrored at wrist   |
|      - Dual-Hypothesis Evaluation: Evaluates single & two-handed topologies       |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                        4. Rolling Temporal Gated Buffer                           |
|      - Sliding window buffer: 60 frames (2.0s duration at 30 FPS)                 |
|      - Fast-path Alphabet sub-window: 0.7s (21 frames resampled to 60)            |
|      - Resampling: Linear interpolation to fixed tensor shape (1, 60, 75, 3)      |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                    5. ST-GCN Deep Neural Network Inference                        |
|      - Graph Convolutions: Spatial adjacency matrix across skeletal connections   |
|      - Temporal 1D Convolutions: Trajectory and kinematic tracking                |
|      - Classification Head: Dense Softmax across 127 FSL classes                  |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                          6. Output Decision & Delivery                            |
|      - Confidence Gating: Score >= 0.60 with Top-1 vs Top-2 Margin >= 0.12        |
|      - Fallback: Strict 0.75 confidence threshold for ambiguous motions           |
|      - Speech Synthesis: TTS conversion (fil-PH-BlessicaNeural)                   |
+-----------------------------------------------------------------------------------+
```

---

## 2. Mathematical Modeling & Landmark Extraction

### 2.1 Skeletal Topology
Every video frame is transformed into a topological graph $\mathcal{G} = (\mathcal{V}, \mathcal{E})$, where:
* $\mathcal{V} = \{v_1, v_2, \dots, v_{75}\}$ represents the **75 key skeletal joints**:
  * **$v_0 \dots v_{32}$ (33 joints):** MediaPipe Pose landmarks (head, shoulders, elbows, wrists, torso).
  * **$v_{33} \dots v_{53}$ (21 joints):** Left hand landmarks (wrist, MCP, PIP, DIP, tip).
  * **$v_{54} \dots v_{74}$ (21 joints):** Right hand landmarks.
* $\mathcal{E}$ represents anatomical connections between connected bones and hand phalanges.
* Each node $v_i$ contains three spatial coordinates $(x_i, y_i, z_i) \in \mathbb{R}^3$.

### 2.2 Invariant Posture Normalization
To make inference invariant to the user's distance from the lens and height differences, landmarks are normalized relative to the user's mid-shoulder coordinate and shoulder width:

$$\mathbf{p}_{\text{mid}} = \frac{\mathbf{p}_{\text{left\_shoulder}} + \mathbf{p}_{\text{right\_shoulder}}}{2}$$

$$w_{\text{shoulder}} = \max\left(\|\mathbf{p}_{\text{left\_shoulder}} - \mathbf{p}_{\text{right\_shoulder}}\|_2,\ \epsilon\right), \quad \epsilon = 0.05$$

$$\hat{\mathbf{p}}_i = \frac{\mathbf{p}_i - \mathbf{p}_{\text{mid}}}{w_{\text{shoulder}}}$$

### 2.3 Canonical Hand Mirroring for Left/Right Invariance
Because FSL single-handed signs (such as the alphabet) are predominantly trained on right-handed performers, a signer using their left hand would traditionally suffer degraded accuracy. TinigSenyas resolves this via **Canonical Hand Mirroring**:

$$\hat{x}_{\text{mirrored}} = 2 \cdot x_{\text{wrist}} - x_i$$

This preserves internal finger orientations (e.g., thumb facing inward) while mapping the left hand into the equivalent right-handed coordinate frame.

---

## 3. Neural Network Architecture (ST-GCN)

The core architecture stored in [`best_fsl_model.keras`](file:///c:/Users/Jebi/Desktop/TinigSenyas/TinigSenyas/backend/models/best_fsl_model.keras) utilizes a custom `TFLiteGraphConv` layer optimized for edge execution.

### Model Layer Breakdown

| Layer Type | Configuration / Kernel | Output Shape | Notes |
| :--- | :--- | :--- | :--- |
| **Input Layer** | `(Time=60, Joints=75, Coords=3)` | `(None, 60, 75, 3)` | Normalized skeletal coordinates |
| **Batch Normalization** | Feature standardization | `(None, 60, 75, 3)` | Stabilizes variance across signers |
| **TFLiteGraphConv 1** | Out Channels = 32, Spatial Adjacency $A$ | `(None, 60, 75, 32)` | Extracts inter-joint bone relationships |
| **Temporal Conv 1D** | Kernel size = 5, Stride = 1, ReLU | `(None, 60, 75, 32)` | Captures local kinematic velocity |
| **TFLiteGraphConv 2** | Out Channels = 64, Spatial Adjacency $A$ | `(None, 60, 75, 64)` | High-level spatial gesture structure |
| **Temporal Conv 1D** | Kernel size = 5, Stride = 2, ReLU | `(None, 30, 75, 64)` | Temporal downsampling |
| **TFLiteGraphConv 3** | Out Channels = 128, Spatial Adjacency $A$ | `(None, 30, 75, 128)` | Global dynamic signing representations |
| **Global Average Pool** | Spatial-Temporal pooling | `(None, 128)` | Collapse temporal and joint dimensions |
| **Dropout** | Rate = 0.30 | `(None, 128)` | Prevents overfitting |
| **Dense (Output)** | Units = 127, Activation = Softmax | `(None, 127)` | Normalized class probabilities |

### Spatial Graph Convolution Formulation
For each frame $t$, joint features $\mathbf{X}_t \in \mathbb{R}^{V \times C_{\text{in}}}$ are propagated according to the normalized adjacency matrix $\tilde{\mathbf{A}}$:

$$\mathbf{Z}_t = \sigma\left(\tilde{\mathbf{A}} \mathbf{X}_t \mathbf{W}\right)$$

Where $\tilde{\mathbf{A}} = \mathbf{D}^{-\frac{1}{2}} (\mathbf{A} + \mathbf{I}) \mathbf{D}^{-\frac{1}{2}}$ and $\mathbf{W} \in \mathbb{R}^{C_{\text{in}} \times C_{\text{out}}}$ is the learnable weight tensor.

---

## 4. Dual-Modal Dataset Strategy for Low-Resource FSL

Because publicly available FSL video repositories are limited in scale, the dataset methodology uses a **Dual-Modal Acquisition Protocol**:

1. **Static Gesture Acquisition (Alphabet A–Z, Numbers 0–9):**
   * High-resolution photographic records taken under diverse lighting conditions and camera angles.
   * MediaPipe landmarks extracted and expanded into 60-frame static sequences with subtle Gaussian temporal perturbation ($\sigma = 0.003$) to simulate realistic hand micro-tremors without losing gesture geometry.
2. **Dynamic Gesture Acquisition (Phrases, Greetings, Medical Terms):**
   * Continuous 2.0-second video recordings captured with Deaf community partners and researchers.
   * Frame sequences resampled via linear interpolation to the standard 60-frame window ($T = 60$).

---

## 5. Confidence Gating & Decision Logic

To eliminate false-positive classifications during natural conversational transitions, predictions must satisfy a two-tier confidence gate:

$$\text{Decision} = \begin{cases}
\hat{y} & \text{if } P(\hat{y}) \ge 0.60 \quad \text{and} \quad P(\hat{y}) - P(y_{\text{second}}) \ge 0.12 \\
\hat{y} & \text{if } P(\hat{y}) \ge 0.75 \\
\text{Reject / Idle} & \text{otherwise}
\end{cases}$$

---

## 6. Mobile & Edge Quantization (TFLite)

The trained Keras model (`best_fsl_model.keras`) is converted into an edge-optimized Float32 package (`fsl_model.tflite`):

* **Model File Size:** 183 KB
* **Inference Latency:** $< 25\text{ ms}$ on mobile CPU / desktop CPU
* **Memory Footprint:** $\approx 18\text{ MB}$ total runtime overhead
* **Integrity Validation:** Monitored via SHA-256 hash and version-controlled OTA manifests (`version.txt`, `manifest.json`).

