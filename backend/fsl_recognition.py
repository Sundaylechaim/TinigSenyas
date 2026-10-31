from __future__ import annotations

from collections import deque
from dataclasses import dataclass
import threading
import time
from pathlib import Path
from typing import Optional

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks import python
from mediapipe.tasks.python import vision


SEQUENCE_LENGTH = 60
TOTAL_JOINTS = 75
CONFIDENCE_THRESHOLD = 0.50
PREDICT_EVERY_N_FRAMES = 3
PROB_HISTORY_SIZE = 4
SESSION_TTL_SECONDS = 600
MAX_SESSIONS = 8

INITIAL_MID_SHOULDER = np.array([0.5, 0.5, 0.0], dtype=np.float32)
INITIAL_SHOULDER_WIDTH = 0.20
MIN_SHOULDER_WIDTH = 0.05

@dataclass(frozen=True)
class RecognitionResult:
    status: str
    frames_collected: int
    label: Optional[str] = None
    confidence: Optional[float] = None
    hand_landmarks: tuple[tuple[tuple[float, float], ...], ...] = ()
    frame_width: int = 0
    frame_height: int = 0


def _normalize_points(landmarks, mid_shoulder, shoulder_width):
    points = np.asarray(
        [[landmark.x, landmark.y, landmark.z] for landmark in landmarks],
        dtype=np.float32,
    )
    return (points - mid_shoulder) / max(
        float(shoulder_width), MIN_SHOULDER_WIDTH
    )


class _RecognitionSession:
    def __init__(self, hand_model: bytes, pose_model: bytes):
        hand_options = vision.HandLandmarkerOptions(
            base_options=python.BaseOptions(model_asset_buffer=hand_model),
            running_mode=vision.RunningMode.VIDEO,
            num_hands=2,
            min_hand_detection_confidence=0.5,
            min_hand_presence_confidence=0.5,
            min_tracking_confidence=0.5,
        )
        pose_options = vision.PoseLandmarkerOptions(
            base_options=python.BaseOptions(model_asset_buffer=pose_model),
            running_mode=vision.RunningMode.VIDEO,
            num_poses=1,
            min_pose_detection_confidence=0.5,
            min_pose_presence_confidence=0.5,
            min_tracking_confidence=0.5,
        )
        self.hand_detector = vision.HandLandmarker.create_from_options(
            hand_options
        )
        try:
            self.pose_detector = vision.PoseLandmarker.create_from_options(
                pose_options
            )
        except Exception:
            self.hand_detector.close()
            raise

        self.frames: deque[np.ndarray] = deque(maxlen=SEQUENCE_LENGTH)
        self.probabilities: deque[np.ndarray] = deque(
            maxlen=PROB_HISTORY_SIZE
        )
        self.mid_shoulder = INITIAL_MID_SHOULDER.copy()
        self.shoulder_width = INITIAL_SHOULDER_WIDTH
        self.cached_pose_joints = np.zeros((33, 3), dtype=np.float32)
        self.smoothed_left = None
        self.smoothed_right = None
        self.frame_index = 0
        self.missing_hand_count = 0
        self.last_prediction: Optional[tuple[str, float]] = None
        self.last_used = time.monotonic()
        self.timestamp_ms = 0
        self.lock = threading.Lock()

    def process(
        self,
        frame: np.ndarray,
        classes: list[str],
        predict,
    ) -> RecognitionResult:
        self.frame_index += 1
        self.timestamp_ms = max(
            self.timestamp_ms + 1, int(time.monotonic() * 1000)
        )

        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        hand_result = self.hand_detector.detect_for_video(
            image, self.timestamp_ms
        )
        detected_hands = hand_result.hand_landmarks or []
        handedness = hand_result.handedness or []
        overlay_landmarks = tuple(
            tuple((float(landmark.x), float(landmark.y)) for landmark in hand)
            for hand in detected_hands
        )

        if self.frame_index % 4 == 0 or self.frame_index == 1:
            pose_result = self.pose_detector.detect_for_video(
                image, self.timestamp_ms
            )
            if pose_result.pose_landmarks:
                pose = pose_result.pose_landmarks[0]
                left_shoulder = np.array(
                    [pose[11].x, pose[11].y, pose[11].z], dtype=np.float32
                )
                right_shoulder = np.array(
                    [pose[12].x, pose[12].y, pose[12].z], dtype=np.float32
                )
                width = float(np.linalg.norm(left_shoulder - right_shoulder))
                if width > MIN_SHOULDER_WIDTH:
                    self.mid_shoulder = (left_shoulder + right_shoulder) / 2.0
                    self.shoulder_width = width
                self.cached_pose_joints = _normalize_points(
                    pose, self.mid_shoulder, self.shoulder_width
                )

        joints = np.zeros((TOTAL_JOINTS, 3), dtype=np.float32)
        joints[:33] = self.cached_pose_joints

        if detected_hands:
            if len(detected_hands) >= 2:
                for hand, handedness_info in zip(detected_hands, handedness):
                    label = (
                        handedness_info[0].category_name
                        if handedness_info
                        else "Unknown"
                    )
                    points = _normalize_points(
                        hand, self.mid_shoulder, self.shoulder_width
                    )
                    if label == "Left":
                        self.smoothed_left = self._smooth(
                            self.smoothed_left, points
                        )
                        joints[33:54] = self.smoothed_left
                    elif label == "Right":
                        self.smoothed_right = self._smooth(
                            self.smoothed_right, points
                        )
                        joints[54:75] = self.smoothed_right
            else:
                points = _normalize_points(
                    detected_hands[0],
                    self.mid_shoulder,
                    self.shoulder_width,
                )
                self.smoothed_right = self._smooth(
                    self.smoothed_right, points
                )
                self.smoothed_left = None
                joints[54:75] = self.smoothed_right

            self.frames.append(joints)
            self.missing_hand_count = 0
            if (
                len(self.frames) == SEQUENCE_LENGTH
                and self.frame_index % PREDICT_EVERY_N_FRAMES == 0
            ):
                sequence = np.expand_dims(
                    np.asarray(self.frames, dtype=np.float32), axis=0
                )
                self.probabilities.append(predict(sequence))
                smoothed = np.mean(
                    np.asarray(self.probabilities), axis=0
                )
                best_index = int(np.argmax(smoothed))
                confidence = float(smoothed[best_index])
                label = classes[best_index]
                if not label or "\ufffd" in label:
                    label = "Unknown sign"
                self.last_prediction = (label, confidence)
        else:
            self.frames.append(joints)
            self.missing_hand_count += 1
            self.smoothed_left = None
            self.smoothed_right = None
            if self.missing_hand_count >= 8:
                self.frames.clear()
                self.probabilities.clear()
                self.last_prediction = None

        self.last_used = time.monotonic()
        label, confidence = self.last_prediction or (None, None)
        status = (
            "recognized"
            if confidence is not None and confidence >= CONFIDENCE_THRESHOLD
            else "uncertain"
            if confidence is not None
            else "collecting"
            if detected_hands
            else "idle"
        )
        return RecognitionResult(
            status=status,
            frames_collected=len(self.frames),
            label=label,
            confidence=confidence,
            hand_landmarks=overlay_landmarks,
            frame_width=frame.shape[1],
            frame_height=frame.shape[0],
        )

    @staticmethod
    def _smooth(previous, points):
        return (
            points.copy()
            if previous is None
            else 0.75 * points + 0.25 * previous
        )

    def close(self):
        self.hand_detector.close()
        self.pose_detector.close()


class FslRecognitionEngine:
    def __init__(self, model_dir: Path):
        self.model_dir = model_dir
        self.model_path = model_dir / "fsl_model.tflite"
        self.classes_path = model_dir / "classes.npy"
        self.hand_model_path = model_dir / "hand_landmarker.task"
        self.pose_model_path = model_dir / "pose_landmarker_lite.task"
        self._interpreter = None
        self._input_index = None
        self._output_index = None
        self._classes: list[str] = []
        self._hand_model: Optional[bytes] = None
        self._pose_model: Optional[bytes] = None
        self._model_lock = threading.Lock()
        self._sessions: dict[str, _RecognitionSession] = {}
        self._sessions_lock = threading.Lock()

    def ensure_ready(self):
        if self._interpreter is not None:
            return
        with self._model_lock:
            if self._interpreter is not None:
                return
            required_files = (
                self.model_path,
                self.classes_path,
                self.hand_model_path,
                self.pose_model_path,
            )
            missing = [path.name for path in required_files if not path.is_file()]
            if missing:
                raise FileNotFoundError(
                    "FSL recognition assets are missing: " + ", ".join(missing)
                )

            from ai_edge_litert.interpreter import Interpreter

            classes = np.load(self.classes_path, allow_pickle=False)
            interpreter = Interpreter(
                model_path=str(self.model_path), num_threads=2
            )
            interpreter.allocate_tensors()
            input_details = interpreter.get_input_details()
            output_details = interpreter.get_output_details()
            expected_input = (1, SEQUENCE_LENGTH, TOTAL_JOINTS, 3)
            if (
                len(input_details) != 1
                or tuple(input_details[0]["shape"]) != expected_input
            ):
                raise ValueError(
                    f"Unexpected FSL model input shape: "
                    f"{input_details[0]['shape'] if input_details else 'none'}"
                )
            if (
                len(output_details) != 1
                or int(output_details[0]["shape"][-1]) != len(classes)
            ):
                raise ValueError(
                    "FSL model output count does not match classes.npy."
                )

            self._classes = [str(label) for label in classes.tolist()]
            self._hand_model = self.hand_model_path.read_bytes()
            self._pose_model = self.pose_model_path.read_bytes()
            self._interpreter = interpreter
            self._input_index = input_details[0]["index"]
            self._output_index = output_details[0]["index"]

    @property
    def class_count(self) -> int:
        self.ensure_ready()
        return len(self._classes)

    def _predict(self, sequence: np.ndarray) -> np.ndarray:
        with self._model_lock:
            self._interpreter.set_tensor(self._input_index, sequence)
            self._interpreter.invoke()
            return self._interpreter.get_tensor(self._output_index)[0]

    def process_frame(self, session_id: str, frame: np.ndarray) -> RecognitionResult:
        self.ensure_ready()
        session = self._get_session(session_id)
        with session.lock:
            return session.process(frame, self._classes, self._predict)

    def reset_session(self, session_id: str):
        with self._sessions_lock:
            session = self._sessions.pop(session_id, None)
        if session is not None:
            with session.lock:
                session.close()

    def _get_session(self, session_id: str) -> _RecognitionSession:
        now = time.monotonic()
        with self._sessions_lock:
            expired = [
                key
                for key, state in self._sessions.items()
                if now - state.last_used > SESSION_TTL_SECONDS
            ]
            for key in expired:
                self._sessions.pop(key).close()

            session = self._sessions.get(session_id)
            if session is not None:
                return session
            if len(self._sessions) >= MAX_SESSIONS:
                raise RuntimeError(
                    "The recognition service is at its active session limit."
                )
            session = _RecognitionSession(
                self._hand_model, self._pose_model
            )
            self._sessions[session_id] = session
            return session

    def close(self):
        with self._sessions_lock:
            sessions = list(self._sessions.values())
            self._sessions.clear()
        for session in sessions:
            session.close()
