import os
import sys
import warnings

os.environ["TF_ENABLE_ONEDNN_OPTS"] = "0"
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=DeprecationWarning)

import unittest
import numpy as np


class TestModelInference(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_dir = os.path.dirname(os.path.abspath(__file__))
        cls.models_dir = os.path.join(cls.base_dir, "models")
        cls.classes_path = os.path.join(cls.models_dir, "classes.npy")
        cls.tflite_path = os.path.join(cls.models_dir, "fsl_model.tflite")
        cls.alphabet_classes_path = os.path.join(cls.models_dir, "alphabet_classes.npy")
        cls.alphabet_tflite_path = os.path.join(cls.models_dir, "fsl_alphabet.tflite")
        cls.hand_task = os.path.join(cls.models_dir, "hand_landmarker.task")
        cls.pose_task = os.path.join(cls.models_dir, "pose_landmarker_lite.task")

    def test_01_assets_exist(self):
        """Verify all trained artifacts exist in backend/models/"""
        self.assertTrue(os.path.isfile(self.classes_path), "classes.npy is missing")
        self.assertTrue(os.path.isfile(self.tflite_path), "fsl_model.tflite is missing")
        self.assertTrue(os.path.isfile(self.alphabet_classes_path), "alphabet_classes.npy is missing")
        self.assertTrue(os.path.isfile(self.alphabet_tflite_path), "fsl_alphabet.tflite is missing")
        self.assertTrue(os.path.isfile(self.hand_task), "hand_landmarker.task is missing")
        self.assertTrue(os.path.isfile(self.pose_task), "pose_landmarker_lite.task is missing")

    def test_02_classes_content(self):
        """Verify the 103 conversational FSL classes are properly structured and include core everyday signs"""
        classes = np.load(self.classes_path, allow_pickle=True)
        self.assertEqual(len(classes), 103, f"Expected 103 classes, found {len(classes)}")
        # Check core conversational keywords
        for keyword in ("Salamat", "Walang anuman", "Kamusta", "Oo", "Hindi", "Ina", "Ama"):
            self.assertIn(keyword, classes, f"Keyword '{keyword}' is missing from classes dictionary!")
        print(f"\n[OK] Confirmed core conversational FSL signs exist in {len(classes)} classes.")

    def test_03_tflite_inference(self):
        """Verify the ST-GCN model performs inference on a (1, 60, 75, 3) dummy sequence"""
        try:
            from ai_edge_litert.interpreter import Interpreter
        except Exception:
            import importlib
            tf_interp = importlib.import_module("tensorflow.lite.python.interpreter")
            Interpreter = getattr(tf_interp, "Interpreter")

        interpreter = Interpreter(model_path=self.tflite_path)
        interpreter.allocate_tensors()

        input_details = interpreter.get_input_details()
        output_details = interpreter.get_output_details()

        expected_shape = list(input_details[0]["shape"])
        self.assertEqual(expected_shape, [1, 60, 75, 3], f"Unexpected input shape: {expected_shape}")

        # Create dummy sequence: 60 frames, 75 joints, 3 coordinates
        dummy_sequence = np.random.randn(1, 60, 75, 3).astype(np.float32)

        interpreter.set_tensor(input_details[0]["index"], dummy_sequence)
        interpreter.invoke()

        output_data = interpreter.get_tensor(output_details[0]["index"])[0]
        classes = np.load(self.classes_path, allow_pickle=True)
        self.assertEqual(len(output_data), len(classes), f"Expected {len(classes)} output probabilities, got {len(output_data)}")

        top_class_idx = int(np.argmax(output_data))
        predicted_sign = str(classes[top_class_idx])

        print(f"[OK] Model inference succeeded! Dummy top prediction: '{predicted_sign}' (idx: {top_class_idx})")

    def test_04_alphabet_inference(self):
        """Verify the FSL Alphabet model performs inference on a (1, 63) hand feature vector"""
        try:
            from ai_edge_litert.interpreter import Interpreter
        except Exception:
            import importlib
            tf_interp = importlib.import_module("tensorflow.lite.python.interpreter")
            Interpreter = getattr(tf_interp, "Interpreter")

        interpreter = Interpreter(model_path=self.alphabet_tflite_path)
        interpreter.allocate_tensors()

        input_details = interpreter.get_input_details()
        output_details = interpreter.get_output_details()

        alpha_classes = np.load(self.alphabet_classes_path, allow_pickle=True)
        num_alpha = len(alpha_classes)
        self.assertEqual(list(input_details[0]["shape"]), [1, 63])
        self.assertEqual(list(output_details[0]["shape"]), [1, num_alpha])

        dummy_hand = np.random.randn(1, 63).astype(np.float32)
        interpreter.set_tensor(input_details[0]["index"], dummy_hand)
        interpreter.invoke()

        out = interpreter.get_tensor(output_details[0]["index"])[0]
        self.assertEqual(len(out), num_alpha)
        pred_letter = str(alpha_classes[int(np.argmax(out))])
        print(f"[OK] Alphabet model inference succeeded! Predicted letter: '{pred_letter}' (out of {num_alpha} letters)")

    def test_05_palm_detection_and_pause(self):
        """Verify the Open Palm / Stop gesture detection and pause buffer reset logic."""
        from sign_classifier import SignClassifier

        classifier = SignClassifier()
        self.assertFalse(classifier.is_paused)
        self.assertEqual(classifier.palm_hold_count, 0)

        class MockLandmark:
            def __init__(self, x, y, z=0.0):
                self.x = x
                self.y = y
                self.z = z

        # Construct an upright open palm (21 points)
        # Wrist at y=0.7 (bottom)
        # Knuckles (MCPs 5, 9, 13, 17) at y=0.5
        # PIPs (6, 10, 14, 18) at y=0.38
        # Tips (8, 12, 16, 20) at y=0.2 (top)
        # Thumb spread outward
        open_palm_lms = [MockLandmark(0.5, 0.7)] * 21
        # Wrist
        open_palm_lms[0] = MockLandmark(0.5, 0.70)
        # Thumb
        open_palm_lms[1] = MockLandmark(0.45, 0.65)
        open_palm_lms[2] = MockLandmark(0.40, 0.60)
        open_palm_lms[3] = MockLandmark(0.35, 0.55)
        open_palm_lms[4] = MockLandmark(0.30, 0.50)  # Thumb tip spread outward
        # Index
        open_palm_lms[5] = MockLandmark(0.45, 0.50)  # MCP
        open_palm_lms[6] = MockLandmark(0.45, 0.35)  # PIP
        open_palm_lms[7] = MockLandmark(0.45, 0.28)  # DIP
        open_palm_lms[8] = MockLandmark(0.45, 0.20)  # Tip
        # Middle
        open_palm_lms[9] = MockLandmark(0.50, 0.48)  # MCP
        open_palm_lms[10] = MockLandmark(0.50, 0.33)  # PIP
        open_palm_lms[11] = MockLandmark(0.50, 0.26)  # DIP
        open_palm_lms[12] = MockLandmark(0.50, 0.18)  # Tip
        # Ring
        open_palm_lms[13] = MockLandmark(0.55, 0.50)  # MCP
        open_palm_lms[14] = MockLandmark(0.55, 0.35)  # PIP
        open_palm_lms[15] = MockLandmark(0.55, 0.28)  # DIP
        open_palm_lms[16] = MockLandmark(0.55, 0.21)  # Tip
        # Pinky
        open_palm_lms[17] = MockLandmark(0.60, 0.53)  # MCP
        open_palm_lms[18] = MockLandmark(0.60, 0.40)  # PIP
        open_palm_lms[19] = MockLandmark(0.60, 0.32)  # DIP
        open_palm_lms[20] = MockLandmark(0.60, 0.25)  # Tip

        is_palm = classifier._check_is_open_palm(open_palm_lms)
        self.assertTrue(is_palm, "Expected open palm posture to be detected as True")

        # Now test curled fist (tips are below PIPs)
        fist_lms = list(open_palm_lms)
        fist_lms[8] = MockLandmark(0.45, 0.55)   # Index tip curled down
        fist_lms[12] = MockLandmark(0.50, 0.55)  # Middle tip curled down
        fist_lms[16] = MockLandmark(0.55, 0.55)  # Ring tip curled down
        fist_lms[20] = MockLandmark(0.60, 0.55)  # Pinky tip curled down

        is_fist_palm = classifier._check_is_open_palm(fist_lms)
        self.assertFalse(is_fist_palm, "Expected fist not to be recognized as open palm")

        classifier.close()
        print("[OK] Open palm detection and pause guard tests passed!")

    def test_06_j_gesture_detection(self):
        """Verify the dynamic letter 'J' (I-handshape + downward scooping arc) detection."""
        from sign_classifier import SignClassifier
        classifier = SignClassifier()

        class PointLM:
            def __init__(self, x, y, z=0.0):
                self.x = x
                self.y = y
                self.z = z

        # Construct an 'I' handshape
        i_lms = [PointLM(0.5, 0.5)] * 21
        i_lms[0] = PointLM(0.5, 0.60)   # Wrist
        # Curled Index
        i_lms[5] = PointLM(0.45, 0.42)
        i_lms[6] = PointLM(0.45, 0.38)
        i_lms[8] = PointLM(0.45, 0.45)
        # Curled Middle
        i_lms[9] = PointLM(0.50, 0.42)
        i_lms[10] = PointLM(0.50, 0.38)
        i_lms[12] = PointLM(0.50, 0.45)
        # Curled Ring
        i_lms[13] = PointLM(0.55, 0.42)
        i_lms[14] = PointLM(0.55, 0.38)
        i_lms[16] = PointLM(0.55, 0.45)
        # Extended Pinky
        i_lms[17] = PointLM(0.60, 0.45)  # MCP
        i_lms[18] = PointLM(0.60, 0.35)  # PIP
        i_lms[20] = PointLM(0.60, 0.20)  # Tip (high up)

        self.assertTrue(classifier._check_is_i_handshape(i_lms), "Expected 'I' handshape to be recognized")

        # Simulate synthetic J-motion: drops vertically then curves and hooks up
        t = np.linspace(0, 1, 18)
        y_stroke = 0.38 + 0.12 * np.sin(t * np.pi * 0.8)  # drops to 0.50, hooks up to 0.45
        x_stroke = 0.50 - 0.04 * (t ** 1.5)               # hooks horizontally

        classifier.j_trajectory.clear()
        for i in range(18):
            classifier.j_trajectory.append((float(x_stroke[i]), float(y_stroke[i]), True))

        self.assertTrue(classifier._detect_j_gesture(), "Expected J gesture trajectory to be detected")

        # Non-J motion (flat movement) should return False
        classifier.j_trajectory.clear()
        for i in range(18):
            classifier.j_trajectory.append((0.50, 0.40, True))
        self.assertFalse(classifier._detect_j_gesture(), "Flat trajectory must not trigger J")

        classifier.close()
        print("[OK] Dynamic letter 'J' trajectory recognition passed!")


if __name__ == "__main__":
    unittest.main()
