"""
TinigSenyas Intelligent ST-GCN Sign Language Classifier Module.
Calibrated for 127 Filipino Sign Language (FSL) classes.
Features:
1. Canonical Hand Mirroring (accurately recognizes single-hand signs whether signed with Left or Right hand).
2. Dual-Hypothesis Evaluation (bridges two-handed and single-handed trained representations).
3. Dynamic rolling buffer with fast static-alphabet recognition (0.7s) and 2.0s gesture windows.
4. Strict confidence gating aligned with Chapter 3 specifications.
"""

import os
import sys
import warnings

# Suppress noisy oneDNN and deprecation terminal spam
os.environ["TF_ENABLE_ONEDNN_OPTS"] = "0"
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=DeprecationWarning)

import cv2
import numpy as np
from collections import deque
from typing import Dict, List, Optional, Tuple

import mediapipe as mp
from mediapipe.tasks import python
from mediapipe.tasks.python import vision

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SEQUENCE_LENGTH = 60
TOTAL_JOINTS = 75

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(BASE_DIR, "models")

CLASSES_PATH = os.path.join(MODELS_DIR, "classes.npy")
TFLITE_PATH = os.path.join(MODELS_DIR, "fsl_model.tflite")
ALPHABET_CLASSES_PATH = os.path.join(MODELS_DIR, "alphabet_classes.npy")
ALPHABET_TFLITE_PATH = os.path.join(MODELS_DIR, "fsl_alphabet.tflite")
HAND_LANDMARKER_PATH = os.path.join(MODELS_DIR, "hand_landmarker.task")
POSE_LANDMARKER_PATH = os.path.join(MODELS_DIR, "pose_landmarker_lite.task")

INITIAL_MID_SHOULDER = np.array([0.5, 0.5, 0.0], dtype=np.float32)
INITIAL_SHOULDER_WIDTH = 0.20
MIN_SHOULDER_WIDTH = 0.05

# Calibrated confidence thresholds for 127 FSL classes
CONFIDENCE_THRESHOLD = 0.58       # Confident threshold
MARGIN_THRESHOLD = 0.10           # Margin between top 1 and top 2 predictions
MIN_CONFIDENCE_FALLBACK = 0.46    # Fallback threshold when top margin is high
HAND_SMOOTH_ALPHA = 0.80
PROB_HISTORY_SIZE = 6             # Smooth across last 6 inference cycles
CONSECUTIVE_STABILITY_REQUIRED = 3 # Must predict same class across 3 consecutive evaluations to switch
MIN_DYNAMIC_MOTION = 0.0065       # Minimum kinetic displacement required to trigger dynamic words

# Classes known to have two-handed training in the dataset
TWO_HANDED_TRAINED_CLASSES = {
    "Abo", "Abril", "Agosto", "Disyembre", "Enero", "Hulyo", "Hunyo",
    "Kasal na", "Kayumanggi", "Lila", "Linggo", "Mabagal", "Madilim",
    "Malamig", "Marso", "Nobyembre", "Ngayon", "Oktubre", "Pebrero",
    "Sabado", "Setyembre", "Tama", "Magulang", "Pinsan", "Spaghetti"
}

HAND_CONNECTIONS = [
    (0, 1), (1, 2), (2, 3), (3, 4),
    (0, 5), (5, 6), (6, 7), (7, 8),
    (5, 9), (9, 10), (10, 11), (11, 12),
    (9, 13), (13, 14), (14, 15), (15, 16),
    (13, 17), (17, 18), (18, 19), (19, 20),
    (0, 17),
]


def normalize_points(landmarks, mid_shoulder: np.ndarray, shoulder_width: float) -> np.ndarray:
    """Normalize landmarks relative to shoulder position and width."""
    pts = np.asarray([[lm.x, lm.y, lm.z] for lm in landmarks], dtype=np.float32)
    width = max(float(shoulder_width), MIN_SHOULDER_WIDTH)
    return (pts - mid_shoulder) / width


def mirror_hand_across_wrist(hand_pts: np.ndarray) -> np.ndarray:
    """
    Horizontally mirrors a hand across its wrist x-coordinate.
    Converts a Left Hand into an anatomically equivalent Right Hand representation,
    aligning with the dataset's right-hand trained single-handed FSL classes.
    """
    wrist_x = hand_pts[0, 0]
    mirrored = hand_pts.copy()
    mirrored[:, 0] = 2.0 * wrist_x - hand_pts[:, 0]
    return mirrored


def resample_sequence(sequence: np.ndarray, target_length: int = SEQUENCE_LENGTH) -> np.ndarray:
    """Exact linear interpolation resampler from convert_all.py"""
    n = len(sequence)
    if n == 0:
        return np.zeros((target_length, TOTAL_JOINTS, 3), dtype=np.float32)
    if n == 1:
        return np.repeat(sequence, target_length, axis=0).astype(np.float32)

    positions = np.linspace(0, n - 1, target_length)
    lower = np.floor(positions).astype(int)
    upper = np.ceil(positions).astype(int)
    alpha = (positions - lower).astype(np.float32)[:, None, None]

    return ((1.0 - alpha) * sequence[lower] + alpha * sequence[upper]).astype(np.float32)


class SignClassifier:
    def __init__(self):
        # Validate paths
        for path in (CLASSES_PATH, HAND_LANDMARKER_PATH, POSE_LANDMARKER_PATH):
            if not os.path.isfile(path):
                raise FileNotFoundError(f"Missing required model asset: {path}")

        self.classes = np.load(CLASSES_PATH, allow_pickle=True)
        self.num_classes = len(self.classes)

        # Initialize Alphabet model if present
        self.has_alphabet_model = False
        if os.path.isfile(ALPHABET_TFLITE_PATH) and os.path.isfile(ALPHABET_CLASSES_PATH):
            try:
                self.alphabet_classes = np.load(ALPHABET_CLASSES_PATH, allow_pickle=True)
                self.has_alphabet_model = True
            except Exception:
                self.has_alphabet_model = False

        # Initialize LiteRT interpreter
        self._init_interpreter()

        # Initialize MediaPipe Tasks detectors
        self._init_detectors()

        # Motion sequence rolling buffer
        self.frame_buffer = deque(maxlen=SEQUENCE_LENGTH)
        self.prob_history = deque(maxlen=PROB_HISTORY_SIZE)

        self.smoothed_left = None
        self.smoothed_right = None
        self.mid_shoulder = INITIAL_MID_SHOULDER.copy()
        self.shoulder_width = INITIAL_SHOULDER_WIDTH
        self.cached_pose_joints = np.zeros((33, 3), dtype=np.float32)

        self.frame_idx = 0
        self.missing_hand_count = 0
        self.latest_label: Optional[str] = None
        self.latest_confidence = 0.0
        self.latest_top2: Tuple[str, float] = ("", 0.0)
        self.is_stable = False
        self.detected_is_left_hand = False
        self.sign_type = "conversational"  # "alphabet" or "conversational"

        # Consensus stability trackers to prevent label flickering
        self._candidate_label: Optional[str] = None
        self._candidate_count: int = 0
        self._alpha_candidate: Optional[str] = None
        self._alpha_count: int = 0

    def _init_interpreter(self):
        try:
            from ai_edge_litert.interpreter import Interpreter
        except Exception:
            import importlib
            tf_interp = importlib.import_module("tensorflow.lite.python.interpreter")
            Interpreter = getattr(tf_interp, "Interpreter")

        self.interpreter = Interpreter(model_path=TFLITE_PATH, num_threads=4)
        self.interpreter.allocate_tensors()
        self.input_index = self.interpreter.get_input_details()[0]["index"]
        self.output_index = self.interpreter.get_output_details()[0]["index"]

        if self.has_alphabet_model:
            try:
                self.alphabet_interpreter = Interpreter(model_path=ALPHABET_TFLITE_PATH, num_threads=2)
                self.alphabet_interpreter.allocate_tensors()
                self.alphabet_input_index = self.alphabet_interpreter.get_input_details()[0]["index"]
                self.alphabet_output_index = self.alphabet_interpreter.get_output_details()[0]["index"]
            except Exception as e:
                self.has_alphabet_model = False

    def _predict_alphabet(self, hand_features_63: np.ndarray) -> Tuple[str, float]:
        if not self.has_alphabet_model:
            return "", 0.0
        inp = np.expand_dims(hand_features_63, axis=0).astype(np.float32)
        self.alphabet_interpreter.set_tensor(self.alphabet_input_index, inp)
        self.alphabet_interpreter.invoke()
        probs = self.alphabet_interpreter.get_tensor(self.alphabet_output_index)[0]
        top_idx = int(np.argmax(probs))
        return str(self.alphabet_classes[top_idx]), float(probs[top_idx])

    def _init_detectors(self):
        hand_options = vision.HandLandmarkerOptions(
            base_options=python.BaseOptions(model_asset_path=HAND_LANDMARKER_PATH),
            running_mode=vision.RunningMode.VIDEO,
            num_hands=2,
            min_hand_detection_confidence=0.5,
            min_hand_presence_confidence=0.5,
            min_tracking_confidence=0.5,
        )
        pose_options = vision.PoseLandmarkerOptions(
            base_options=python.BaseOptions(model_asset_path=POSE_LANDMARKER_PATH),
            running_mode=vision.RunningMode.VIDEO,
            num_poses=1,
            min_pose_detection_confidence=0.5,
            min_pose_presence_confidence=0.5,
            min_tracking_confidence=0.5,
        )
        self.hand_detector = vision.HandLandmarker.create_from_options(hand_options)
        self.pose_detector = vision.PoseLandmarker.create_from_options(pose_options)

    def _predict_raw(self, seq_60: np.ndarray) -> np.ndarray:
        """Runs LiteRT forward pass on shape (1, 60, 75, 3)"""
        input_data = np.expand_dims(seq_60, axis=0).astype(np.float32)
        self.interpreter.set_tensor(self.input_index, input_data)
        self.interpreter.invoke()
        return self.interpreter.get_tensor(self.output_index)[0]

    def _evaluate_hypotheses(self, motion_seq: np.ndarray, detected_hands_count: int) -> Tuple[str, float, str, float]:
        """
        Multi-Hypothesis Evaluation:
        1. Hypothesis A (Raw Slots): Evaluates as assembled.
        2. Hypothesis B (Mirrored Single-Hand): Evaluates with canonical horizontal wrist-mirroring.
           (Ensures left-handed signers have their fingers mapped to canonical right-hand training coordinates).
        3. Hypothesis C (Single Dominant Hand): When 2 hands are detected, also tests single-hand slot
           with left slot zeroed (handles cases where a resting second hand is in frame during a 1-handed sign).
        """
        # Ensure sequence is resampled to 60 frames
        if len(motion_seq) == SEQUENCE_LENGTH:
            seq_a = motion_seq.copy()
        else:
            seq_a = resample_sequence(motion_seq)

        probs_a = self._predict_raw(seq_a)
        best_probs = probs_a.copy()

        # Hypothesis B: Canonical Mirrored Single-Hand (ONLY if detected hand was a Left hand)
        if detected_hands_count == 1 and getattr(self, "detected_is_left_hand", False):
            seq_b = seq_a.copy()
            for f in range(SEQUENCE_LENGTH):
                if np.any(seq_b[f, 54:75, :] != 0):
                    seq_b[f, 54:75, :] = mirror_hand_across_wrist(seq_b[f, 54:75, :])
            seq_b[:, 33:54, :] = 0.0  # Clear left-hand slot

            probs_b = self._predict_raw(seq_b)
            top_b_idx = int(np.argmax(probs_b))
            top_b_name = str(self.classes[top_b_idx])

            # If mirrored hypothesis yields higher confidence for single-hand sign, adopt it
            if top_b_name not in TWO_HANDED_TRAINED_CLASSES and np.max(probs_b) > np.max(best_probs):
                best_probs = probs_b

        # Hypothesis C: If 2 hands were detected, also evaluate raw single-hand (slot 33:54 cleared)
        if detected_hands_count >= 2:
            seq_c = seq_a.copy()
            seq_c[:, 33:54, :] = 0.0
            probs_c = self._predict_raw(seq_c)
            top_c_idx = int(np.argmax(probs_c))
            top_c_name = str(self.classes[top_c_idx])
            if top_c_name not in TWO_HANDED_TRAINED_CLASSES and np.max(probs_c) > np.max(best_probs):
                best_probs = probs_c

        # Smooth probabilities across recent predictions
        self.prob_history.append(best_probs)
        smoothed_probs = np.mean(np.asarray(self.prob_history), axis=0)

        # Suppress invalid / corrupted class label if present at index 126
        if len(smoothed_probs) > 126 and str(self.classes[126]) in ('', '\ufffd', '?'):
            smoothed_probs[126] = 0.0

        top_idxs = np.argsort(smoothed_probs)[::-1]
        top1_idx = int(top_idxs[0])
        top2_idx = int(top_idxs[1]) if len(top_idxs) > 1 else top1_idx

        conf1 = float(smoothed_probs[top1_idx])
        conf2 = float(smoothed_probs[top2_idx])
        name1 = str(self.classes[top1_idx])
        name2 = str(self.classes[top2_idx])

        return name1, conf1, name2, conf2

    def _compute_buffer_motion(self) -> float:
        """Computes mean displacement across active hand joints over recent frames."""
        if len(self.frame_buffer) < 6:
            return 0.0
        arr = np.asarray(self.frame_buffer, dtype=np.float32)
        diffs = np.diff(arr[-12:, :, :2], axis=0)
        r_active = np.any(arr[-1, 54:75, :2] != 0)
        l_active = np.any(arr[-1, 33:54, :2] != 0)
        r_disp = np.mean(np.linalg.norm(diffs[:, 54:75, :], axis=-1)) if r_active else 0.0
        l_disp = np.mean(np.linalg.norm(diffs[:, 33:54, :], axis=-1)) if l_active else 0.0
        return float(max(r_disp, l_disp))

    def process_frame(self, frame: np.ndarray) -> Tuple[np.ndarray, Dict]:
        """
        Real-time frame processing pipeline:
        1. MediaPipe Pose & Hands extraction.
        2. Dynamic joint slot routing & canonical hand reflection.
        3. Sliding buffer accumulation (from 20 to 60 frames).
        4. Multi-hypothesis evaluation.
        5. Visual overlay & HUD rendering.
        """
        self.frame_idx += 1
        h, w = frame.shape[:2]
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        timestamp_ms = int(self.frame_idx * 1000 / 30)

        # Detect hands
        hand_result = self.hand_detector.detect_for_video(mp_image, timestamp_ms)
        detected_hands = hand_result.hand_landmarks or []
        handedness = hand_result.handedness or []

        # Detect pose (every 4 frames)
        if self.frame_idx % 4 == 0 or self.frame_idx == 1:
            pose_result = self.pose_detector.detect_for_video(mp_image, timestamp_ms)
            if pose_result.pose_landmarks:
                pose_lms = pose_result.pose_landmarks[0]
                left_sh = np.array([pose_lms[11].x, pose_lms[11].y, pose_lms[11].z], dtype=np.float32)
                right_sh = np.array([pose_lms[12].x, pose_lms[12].y, pose_lms[12].z], dtype=np.float32)
                width = float(np.linalg.norm(left_sh - right_sh))
                if width > MIN_SHOULDER_WIDTH:
                    self.mid_shoulder = (left_sh + right_sh) / 2.0
                    self.shoulder_width = width
                self.cached_pose_joints = normalize_points(pose_lms, self.mid_shoulder, self.shoulder_width)

        joints = np.zeros((TOTAL_JOINTS, 3), dtype=np.float32)
        joints[:33] = self.cached_pose_joints

        # Mirror camera preview for natural display
        preview = cv2.flip(frame, 1)

        # Draw detected hand landmarks on mirrored preview
        for hand_lms, hand_info in zip(detected_hands, handedness):
            label = hand_info[0].category_name if hand_info else "Unknown"
            color = (0, 255, 255) if label == "Right" else (255, 100, 0)
            points = [(int((1.0 - lm.x) * w), int(lm.y * h)) for lm in hand_lms]
            for pt in points:
                cv2.circle(preview, pt, 3, color, -1)
            for a, b in HAND_CONNECTIONS:
                cv2.line(preview, points[a], points[b], color, 2)

        # Check if detected hands are raised in the active signing space (chest/face level)
        # MediaPipe normalized y: 0.0 (top) to 1.0 (bottom).
        # Hands resting on desk/lap have wrist_y >= 0.78 and knuckles >= 0.74.
        hands_in_signing_space = False
        if detected_hands:
            for hand_lms in detected_hands:
                wrist_y = hand_lms[0].y
                mcp_y = hand_lms[9].y
                if wrist_y < 0.78 or mcp_y < 0.74:
                    hands_in_signing_space = True
                    break

        # Joint Slot Routing:
        if detected_hands and hands_in_signing_space:
            self.missing_hand_count = 0
            if len(detected_hands) >= 2:
                self.norm_hand_63 = None
                # Two hands present
                for hand_lms, hand_info in zip(detected_hands, handedness):
                    label = hand_info[0].category_name if hand_info else "Unknown"
                    pts = normalize_points(hand_lms, self.mid_shoulder, self.shoulder_width)
                    if label == "Left":
                        self.smoothed_left = (
                            pts if self.smoothed_left is None
                            else HAND_SMOOTH_ALPHA * pts + (1 - HAND_SMOOTH_ALPHA) * self.smoothed_left
                        )
                        joints[33:54] = self.smoothed_left
                    else:
                        self.smoothed_right = (
                            pts if self.smoothed_right is None
                            else HAND_SMOOTH_ALPHA * pts + (1 - HAND_SMOOTH_ALPHA) * self.smoothed_right
                        )
                        joints[54:75] = self.smoothed_right
            else:
                # Single hand present:
                hand_lms = detected_hands[0]
                label = handedness[0][0].category_name if handedness and handedness[0] else "Unknown"
                pts = normalize_points(hand_lms, self.mid_shoulder, self.shoulder_width)

                # Check if this single hand is a Left hand
                # (either from MediaPipe category or geometric index-vs-pinky MCP x-position)
                is_left_hand = (label == "Left") or (len(hand_lms) >= 18 and hand_lms[5].x > hand_lms[17].x)
                self.detected_is_left_hand = is_left_hand

                # Smooth right hand representation
                self.smoothed_right = (
                    pts if self.smoothed_right is None
                    else HAND_SMOOTH_ALPHA * pts + (1 - HAND_SMOOTH_ALPHA) * self.smoothed_right
                )
                self.smoothed_left = None
                joints[54:75] = self.smoothed_right
                joints[33:54] = 0.0

                # Compute normalized 63-coord hand landmark features for Alphabet A-Z classification
                lms_arr = np.asarray([[lm.x, lm.y, lm.z] for lm in hand_lms], dtype=np.float32)
                wrist_pt = lms_arr[0].copy()
                centered_hand = lms_arr - wrist_pt
                max_dist = float(np.max(np.linalg.norm(centered_hand, axis=1)))
                self.norm_hand_63 = ((centered_hand / max_dist) if max_dist > 1e-4 else centered_hand).flatten().astype(np.float32)

            self.frame_buffer.append(joints)
            motion_val = self._compute_buffer_motion()

            # Priority 1: Alphabet Fingerspelling (A-Z)
            # Evaluated when 1 hand is held relatively steady in the active signing zone
            alphabet_recognized = False
            if len(detected_hands) == 1 and self.norm_hand_63 is not None and motion_val < 0.015:
                alpha_name, alpha_conf = self._predict_alphabet(self.norm_hand_63)
                if alpha_conf >= 0.50:
                    if alpha_name == self._alpha_candidate:
                        self._alpha_count += 1
                    else:
                        self._alpha_candidate = alpha_name
                        self._alpha_count = 1

                    if self._alpha_count >= 2:
                        self.latest_label = alpha_name
                        self.latest_confidence = alpha_conf
                        self.latest_top2 = ("", 0.0)
                        self.is_stable = True
                        self.sign_type = "alphabet"
                        alphabet_recognized = True
                        self._candidate_label = None
                        self._candidate_count = 0

            # Priority 2: Conversational Dynamic Signs (103 FSL classes via ST-GCN)
            # Evaluated when sufficient frames are gathered and dynamic movement is active
            if not alphabet_recognized and len(self.frame_buffer) >= 20 and self.frame_idx % 2 == 0:
                self._alpha_count = 0
                self._alpha_candidate = None
                motion_array = np.asarray(self.frame_buffer, dtype=np.float32)
                name1, conf1, name2, conf2 = self._evaluate_hypotheses(motion_array, len(detected_hands))

                margin = conf1 - conf2

                is_recognized = (
                    len(self.frame_buffer) >= 22
                    and motion_val >= MIN_DYNAMIC_MOTION
                    and (
                        (conf1 >= CONFIDENCE_THRESHOLD)
                        or (conf1 >= MIN_CONFIDENCE_FALLBACK and margin >= MARGIN_THRESHOLD)
                    )
                )

                if is_recognized:
                    # Consensus filter: require candidate label stability across evaluations
                    if name1 == self._candidate_label:
                        self._candidate_count += 1
                    else:
                        self._candidate_label = name1
                        self._candidate_count = 1

                    if self._candidate_count >= CONSECUTIVE_STABILITY_REQUIRED:
                        self.latest_label = name1
                        self.is_stable = True
                        self.sign_type = "conversational"
                        # If recognized and held, trim buffer tail to allow immediate transition to next sign
                        if self._candidate_count > CONSECUTIVE_STABILITY_REQUIRED + 4:
                            recent = list(self.frame_buffer)[-8:]
                            self.frame_buffer.clear()
                            self.frame_buffer.extend(recent)
                            self._candidate_count = CONSECUTIVE_STABILITY_REQUIRED

                    self.latest_confidence = conf1
                    self.latest_top2 = (name2, conf2)
                elif not self.is_stable or self.sign_type != "alphabet":
                    self.is_stable = False
                    self.latest_confidence = 0.0
                    self.latest_top2 = (name2, conf2)
                    self.missing_hand_count += 1
                    if self.missing_hand_count > 6:
                        self.latest_label = None
                        self._candidate_label = None
                        self._candidate_count = 0

        else:
            # Hands not in frame or resting below signing zone:
            self.missing_hand_count += 1
            if self.missing_hand_count > 4:
                self.frame_buffer.clear()
                self.prob_history.clear()
                self.smoothed_left = None
                self.smoothed_right = None
                self.is_stable = False
                self._candidate_label = None
                self._candidate_count = 0
                self.latest_label = None
                self.latest_confidence = 0.0

        # Render HUD Banner
        self._render_hud(preview, len(detected_hands) if hands_in_signing_space else 0, hands_in_signing_space)

        result_payload = {
            "label": self.latest_label if self.is_stable else None,
            "raw_label": self.latest_label,
            "confidence": round(self.latest_confidence, 3) if self.is_stable else 0.0,
            "top2_label": self.latest_top2[0],
            "top2_confidence": round(self.latest_top2[1], 3),
            "hands_count": len(detected_hands) if hands_in_signing_space else 0,
            "buffer_progress": min(1.0, round(len(self.frame_buffer) / float(SEQUENCE_LENGTH), 2)),
            "window_duration_seconds": 2.0,
            "is_stable": self.is_stable,
            "sign_type": self.sign_type,
        }

        return preview, result_payload

    def _render_hud(self, frame: np.ndarray, hands_count: int, hands_in_signing_space: bool = True):
        h, w = frame.shape[:2]

        # Top banner overlay
        overlay = frame.copy()
        cv2.rectangle(overlay, (0, 0), (w, 82), (15, 20, 30), -1)
        cv2.addWeighted(overlay, 0.75, frame, 0.25, 0, frame)

        # Buffer progress indicator (2.0s gesture window)
        prog = min(1.0, len(self.frame_buffer) / float(SEQUENCE_LENGTH))
        prog_color = (0, 230, 100) if prog >= 0.75 else (1, 56, 255)
        cv2.rectangle(frame, (16, 72), (int(16 + (w - 32) * prog), 77), prog_color, -1)

        # Display prediction or guidance
        if not hands_in_signing_space:
            text = "Raise hand(s) to sign"
            color = (180, 180, 180)
        elif self.is_stable and self.latest_label:
            if self.sign_type == "alphabet":
                text = f"Letter {self.latest_label} ({self.latest_confidence * 100:.0f}%) [Alphabet]"
                color = (0, 240, 255)  # Bright Cyan for letters
            else:
                text = f"{self.latest_label} ({self.latest_confidence * 100:.0f}%)"
                color = (0, 230, 100)  # Bright Green for words
        elif len(self.frame_buffer) < 20:
            text = f"Forming sign... ({len(self.frame_buffer)}/{SEQUENCE_LENGTH} frames)"
            color = (255, 200, 0)
        else:
            text = f"Analyzing gesture... ({self.latest_confidence * 100:.0f}%)"
            color = (200, 220, 255)

        cv2.putText(frame, text, (20, 48), cv2.FONT_HERSHEY_DUPLEX, 0.95, color, 2, cv2.LINE_AA)

        # Hand indicator & Dual Mode status
        hand_info = "L-Hand (Auto-Mirrored)" if (hands_count == 1 and self.detected_is_left_hand) else f"Hands: {hands_count}"
        sub = f"{hand_info} | Dual FSL (103 Signs + 26 A-Z Letters)"
        cv2.putText(frame, sub, (w - 460, 48), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (170, 170, 170), 1, cv2.LINE_AA)

    def close(self):
        try:
            if hasattr(self, "hand_detector") and self.hand_detector is not None:
                self.hand_detector.close()
                self.hand_detector = None
        except Exception:
            pass
        try:
            if hasattr(self, "pose_detector") and self.pose_detector is not None:
                self.pose_detector.close()
                self.pose_detector = None
        except Exception:
            pass

    def __del__(self):
        self.close()
