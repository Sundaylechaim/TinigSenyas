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

        # Open Palm Pause & Buffer Flush State (HCI Error Recovery Guard)
        self.is_paused = False
        self.palm_hold_count = 0
        self.PALM_HOLD_THRESHOLD = 8  # ~250ms of sustained hold to trigger pause / buffer flush

        # Dynamic Fingerspelling Trajectory Tracker ('J')
        self.j_trajectory = deque(maxlen=30)
        self.j_cooldown = 0

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
        with open(HAND_LANDMARKER_PATH, "rb") as f:
            hand_buffer = f.read()
        with open(POSE_LANDMARKER_PATH, "rb") as f:
            pose_buffer = f.read()

        hand_options = vision.HandLandmarkerOptions(
            base_options=python.BaseOptions(model_asset_buffer=hand_buffer),
            running_mode=vision.RunningMode.VIDEO,
            num_hands=2,
            min_hand_detection_confidence=0.5,
            min_hand_presence_confidence=0.5,
            min_tracking_confidence=0.5,
        )
        pose_options = vision.PoseLandmarkerOptions(
            base_options=python.BaseOptions(model_asset_buffer=pose_buffer),
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

    def _check_is_open_palm(self, hand_lms) -> bool:
        """
        Validates whether a detected hand is in an upright Open Palm / Stop posture.
        Used as a hands-free buffer flush and pause guard for error recovery.
        Criteria:
        1. Upright orientation: Wrist (0) is lower than Knuckles (MCP 9).
        2. All 4 fingers (Index, Middle, Ring, Pinky) are extended upwards above PIP joints.
        3. Thumb is spread outward from the palm (not tucked or forming a fist).
        4. Hand span across knuckles is wide (open palm).
        """
        if not hand_lms or len(hand_lms) < 21:
            return False

        wrist = hand_lms[0]
        # MediaPipe normalized y: 0.0 at top, 1.0 at bottom.
        # For upright stop palm, wrist y must be greater than middle MCP (9) y
        if wrist.y <= hand_lms[9].y:
            return False

        # Four fingers: (Tip index, PIP index)
        fingers = [(8, 6), (12, 10), (16, 14), (20, 18)]
        for tip_idx, pip_idx in fingers:
            tip = hand_lms[tip_idx]
            pip = hand_lms[pip_idx]
            # Tip must be higher than PIP on screen (smaller y)
            if tip.y >= pip.y:
                return False
            # Euclidean distance from wrist to tip must exceed wrist to PIP
            dist_tip = float(np.hypot(tip.x - wrist.x, tip.y - wrist.y))
            dist_pip = float(np.hypot(pip.x - wrist.x, pip.y - wrist.y))
            if dist_tip <= dist_pip * 1.15:
                return False

        # Thumb spread check (thumb tip 4 vs pinky MCP 17 and wrist 0)
        thumb_tip = hand_lms[4]
        dist_thumb_pinky = float(np.hypot(thumb_tip.x - hand_lms[17].x, thumb_tip.y - hand_lms[17].y))
        dist_thumb_wrist = float(np.hypot(thumb_tip.x - wrist.x, thumb_tip.y - wrist.y))
        dist_mcp_wrist = float(np.hypot(hand_lms[2].x - wrist.x, hand_lms[2].y - wrist.y))
        if dist_thumb_pinky < 0.10 and dist_thumb_wrist < dist_mcp_wrist * 1.1:
            return False

        # Knuckle span check (Index MCP 5 to Pinky MCP 17)
        span = float(np.hypot(hand_lms[5].x - hand_lms[17].x, hand_lms[5].y - hand_lms[17].y))
        if span < 0.05:
            return False

        return True

    def _check_is_i_handshape(self, hand_lms) -> bool:
        """
        Checks if a hand is in the 'I' posture:
        - Pinky finger extended upright.
        - Index, Middle, and Ring fingers folded/curled into the palm.
        - Thumb folded across knuckles.
        """
        if not hand_lms or len(hand_lms) < 21:
            return False

        pinky_tip = hand_lms[20]
        pinky_pip = hand_lms[18]
        pinky_mcp = hand_lms[17]

        index_tip = hand_lms[8]
        index_pip = hand_lms[6]
        middle_tip = hand_lms[12]
        middle_pip = hand_lms[10]
        ring_tip = hand_lms[16]
        ring_pip = hand_lms[14]

        # Pinky must be extended: tip is above PIP and MCP (lower y means higher on screen)
        pinky_extended = (pinky_tip.y < pinky_pip.y) and (pinky_tip.y < pinky_mcp.y)

        # Index, Middle, Ring should be curled down
        index_curled = index_tip.y > (index_pip.y - 0.03)
        middle_curled = middle_tip.y > (middle_pip.y - 0.03)
        ring_curled = ring_tip.y > (ring_pip.y - 0.03)

        # Pinky tip should be noticeably higher than the curled fingertips
        pinky_dominant = (
            pinky_tip.y < index_tip.y - 0.04
            and pinky_tip.y < middle_tip.y - 0.04
            and pinky_tip.y < ring_tip.y - 0.04
        )

        return bool(pinky_extended and index_curled and middle_curled and ring_curled and pinky_dominant)

    def _detect_j_gesture(self) -> bool:
        """
        Detects dynamic fingerspelled letter 'J'.
        Kinematic criteria:
        1. Performed with single hand in 'I' handshape (pinky extended).
        2. Path of pinky tip traces downward stroke followed by upward hook.
        3. Meaningful vertical descent (drop >= 0.045) and upward recovery (hook >= 0.020).
        4. Curvature / horizontal arc (width >= 0.020).
        """
        n = len(self.j_trajectory)
        if n < 10:
            return False

        for win_len in range(10, min(n + 1, 30)):
            points = list(self.j_trajectory)[-win_len:]

            # Must have significant presence of 'I' handshape
            i_count = sum(1 for p in points if p[2])
            if i_count < int(win_len * 0.35):
                continue

            y_vals = [p[1] for p in points]
            x_vals = [p[0] for p in points]

            first_third = max(3, win_len // 3)
            y_start = min(y_vals[:first_third])
            y_max = max(y_vals)
            idx_max = y_vals.index(y_max)

            # The bottom of the hook must occur between 33% and (win_len - 2)
            if idx_max < win_len // 3 or idx_max >= win_len - 2:
                continue

            y_end = min(y_vals[idx_max:])
            down_drop = y_max - y_start
            up_hook = y_max - y_end
            x_span = max(x_vals) - min(x_vals)

            if down_drop >= 0.045 and up_hook >= 0.020 and x_span >= 0.020:
                return True

        return False

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

        # Check for Open Palm / Stop posture (HCI Error Recovery Guard)
        has_open_palm = (
            any(self._check_is_open_palm(hand_lms) for hand_lms in detected_hands)
            if (detected_hands and hands_in_signing_space)
            else False
        )

        if has_open_palm:
            self.palm_hold_count += 1
            if self.palm_hold_count >= self.PALM_HOLD_THRESHOLD:
                self.is_paused = True
                # Immediately flush the rolling motion sequence buffer and consensus trackers
                self.frame_buffer.clear()
                self.prob_history.clear()
                self._candidate_label = None
                self._candidate_count = 0
                self._alpha_candidate = None
                self._alpha_count = 0
                self.smoothed_left = None
                self.smoothed_right = None
                self.latest_label = None
                self.latest_confidence = 0.0
                self.is_stable = False
        else:
            if self.is_paused:
                # Signer transitioned or lowered palm to begin signing the next word
                self.is_paused = False
                self.palm_hold_count = 0
                self.frame_buffer.clear()
                self.prob_history.clear()
            else:
                self.palm_hold_count = max(0, self.palm_hold_count - 1)

        # Joint Slot Routing:
        if not self.is_paused and detected_hands and hands_in_signing_space:
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

            # Record trajectory for dynamic fingerspelling ('J')
            if len(detected_hands) == 1 and not self.is_paused:
                single_hand_lms = detected_hands[0]
                is_i = self._check_is_i_handshape(single_hand_lms)
                self.j_trajectory.append((float(single_hand_lms[20].x), float(single_hand_lms[20].y), is_i))
            else:
                self.j_trajectory.clear()

            if self.j_cooldown > 0:
                self.j_cooldown -= 1

            self.frame_buffer.append(joints)
            motion_val = self._compute_buffer_motion()

            # Priority 0: Dynamic Fingerspelled Letter 'J' (downward stroke + upward hook)
            alphabet_recognized = False
            if (
                len(detected_hands) == 1
                and not self.is_paused
                and self.j_cooldown == 0
                and self._detect_j_gesture()
            ):
                self.latest_label = "J"
                self.latest_confidence = 0.92
                self.latest_top2 = ("I", 0.08)
                self.is_stable = True
                self.sign_type = "alphabet"
                self.j_cooldown = 24  # Debounce ~0.8s
                self.j_trajectory.clear()
                self.frame_buffer.clear()
                self._alpha_candidate = "J"
                self._alpha_count = 3
                alphabet_recognized = True

            # Priority 1: Alphabet Fingerspelling (A-Z)
            # Evaluated when 1 hand is held relatively steady in the active signing zone
            if not alphabet_recognized and len(detected_hands) == 1 and self.norm_hand_63 is not None and motion_val < 0.015:
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
            self.palm_hold_count = 0
            self.is_paused = False
            self.j_trajectory.clear()
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
            "label": self.latest_label if (self.is_stable and not self.is_paused) else None,
            "raw_label": self.latest_label if not self.is_paused else None,
            "confidence": round(self.latest_confidence, 3) if (self.is_stable and not self.is_paused) else 0.0,
            "top2_label": self.latest_top2[0] if not self.is_paused else "",
            "top2_confidence": round(self.latest_top2[1], 3) if not self.is_paused else 0.0,
            "hands_count": len(detected_hands) if hands_in_signing_space else 0,
            "buffer_progress": 0.0 if self.is_paused else min(1.0, round(len(self.frame_buffer) / float(SEQUENCE_LENGTH), 2)),
            "window_duration_seconds": 2.0,
            "is_stable": self.is_stable and not self.is_paused,
            "sign_type": self.sign_type,
            "is_paused": self.is_paused,
            "palm_hold_progress": min(1.0, round(self.palm_hold_count / float(self.PALM_HOLD_THRESHOLD), 2)),
        }

        return preview, result_payload

    def _render_hud(self, frame: np.ndarray, hands_count: int, hands_in_signing_space: bool = True):
        h, w = frame.shape[:2]

        # Top banner overlay
        overlay = frame.copy()
        cv2.rectangle(overlay, (0, 0), (w, 82), (15, 20, 30), -1)
        cv2.addWeighted(overlay, 0.75, frame, 0.25, 0, frame)

        # Buffer progress indicator (2.0s gesture window)
        if self.is_paused:
            # Solid amber line across HUD indicating active buffer pause
            cv2.rectangle(frame, (16, 72), (w - 16, 77), (0, 180, 255), -1)
        elif self.palm_hold_count > 1:
            # Holding palm progress indicator
            hold_prog = min(1.0, self.palm_hold_count / float(self.PALM_HOLD_THRESHOLD))
            cv2.rectangle(frame, (16, 72), (int(16 + (w - 32) * hold_prog), 77), (0, 215, 255), -1)
        else:
            prog = min(1.0, len(self.frame_buffer) / float(SEQUENCE_LENGTH))
            prog_color = (0, 230, 100) if prog >= 0.75 else (1, 56, 255)
            cv2.rectangle(frame, (16, 72), (int(16 + (w - 32) * prog), 77), prog_color, -1)

        # Display prediction or guidance
        if self.is_paused:
            text = "[PAUSED] Open Palm Detected - Lower hand to resume"
            color = (0, 180, 255)  # Amber / Gold
        elif self.palm_hold_count > 2:
            pct = int((self.palm_hold_count / float(self.PALM_HOLD_THRESHOLD)) * 100)
            text = f"Holding open palm to pause... ({pct}%)"
            color = (0, 215, 255)
        elif not hands_in_signing_space:
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

        cv2.putText(frame, text, (20, 48), cv2.FONT_HERSHEY_DUPLEX, 0.90, color, 2, cv2.LINE_AA)

        # Hand indicator & Dual Mode status
        if self.is_paused:
            sub = "Buffer Flushed | Ready for Next Sign"
        else:
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
