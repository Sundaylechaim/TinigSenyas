"""
Automated validation test for TinigSenyas ST-GCN Sign Language Model.
Validates model loading, class dictionary, MediaPipe tasks, and sequence inference.
"""

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

        self.assertEqual(list(input_details[0]["shape"]), [1, 63])
        self.assertEqual(list(output_details[0]["shape"]), [1, 26])

        dummy_hand = np.random.randn(1, 63).astype(np.float32)
        interpreter.set_tensor(input_details[0]["index"], dummy_hand)
        interpreter.invoke()

        out = interpreter.get_tensor(output_details[0]["index"])[0]
        self.assertEqual(len(out), 26)
        alpha_classes = np.load(self.alphabet_classes_path, allow_pickle=True)
        pred_letter = str(alpha_classes[int(np.argmax(out))])
        print(f"[OK] Alphabet model inference succeeded! Predicted letter: '{pred_letter}' (out of 26 letters)")


if __name__ == "__main__":
    unittest.main()
