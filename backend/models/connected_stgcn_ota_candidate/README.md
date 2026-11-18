# Connected ST-GCN model package

This folder contains the 103-class connected ST-GCN model package. Its graph connects the pose skeleton, wrists, and both hand skeletons, then fine-tunes the existing checkpoint. Before export, its classifier output was reordered to match the app's existing `labels.txt` order.

The TFLite model expects `[1, 60, 75, 3]`. Its output indices match `labels_connected_candidate.txt`, which is byte-for-byte identical to `frontend/assets/model/labels.txt`. The app bundle uses this model as `frontend/assets/model/fsl_model.tflite`; the OTA release asset is also named `fsl_model.tflite`.

## Local comparison

Both models were evaluated on the same 418 clips from a stratified, sample-level split of 2,090 clips across 103 classes (`random_state=42`).

| Metric | Current app model | Connected model |
| --- | ---: | ---: |
| Top-1 accuracy | 84.69% | 86.12% |
| Confidence-gate coverage | 66.75% | 68.42% |
| Accuracy on accepted predictions | 97.49% | 97.55% |

Both models had zero recall for `Oktubre`. The gain is modest, and this split does not separate signers or recording sessions. These numbers do not establish real-world accuracy for Deaf FSL users. The model is being released for on-device evaluation, not as evidence that phrase recognition is now reliable.

To train another candidate, provide local `--dataset-dir` and `--init-checkpoint` inputs to `backend/train_connected_stgcn_candidate.py`. The training dataset and source checkpoint are not included in the release repository.
