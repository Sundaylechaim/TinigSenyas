import unittest
import numpy as np
import mediapipe as mp
from hand_tracker import HandTracker, HandValidationResult, HandInfo


@unittest.skipUnless(hasattr(mp, "solutions"), "MediaPipe mp.solutions requires Python <=3.12")
class HandTrackerTests(unittest.TestCase):
    def setUp(self):
        self.tracker = HandTracker(
            max_num_hands=2,
            min_detection_confidence=0.5,
            min_tracking_confidence=0.5,
            mirror_camera=True,
        )

    def tearDown(self):
        self.tracker.close()

    def test_process_blank_frame(self):
        # Frame with no hands (black canvas)
        blank = np.zeros((480, 640, 3), dtype=np.uint8)
        processed_frame, result = self.tracker.process_frame(blank)

        self.assertIsInstance(result, HandValidationResult)
        self.assertEqual(result.hands_count, 0)
        self.assertFalse(result.detected)
        self.assertFalse(result.has_left_hand)
        self.assertFalse(result.has_right_hand)
        self.assertFalse(result.edge_warning)
        self.assertEqual(processed_frame.shape, (480, 640, 3))

    def test_zone_classification_and_features(self):
        # Test feature extraction structure for FSL model trainer
        mock_result = HandValidationResult(
            detected=True,
            hands_count=2,
            has_left_hand=True,
            has_right_hand=True,
            zones_covered=["Left Zone", "Center Zone"],
            hands=[
                HandInfo(
                    handedness="Left",
                    confidence=0.95,
                    zone="Left Zone",
                    bbox=(10, 100, 150, 300),
                    center=(0.20, 0.45),
                    is_clipped=False,
                    landmarks=[{"x": 0.2, "y": 0.4, "z": 0.0}] * 21,
                ),
                HandInfo(
                    handedness="Right",
                    confidence=0.98,
                    zone="Center Zone",
                    bbox=(250, 120, 400, 320),
                    center=(0.50, 0.45),
                    is_clipped=False,
                    landmarks=[{"x": 0.5, "y": 0.4, "z": 0.0}] * 21,
                ),
            ],
        )

        features = self.tracker.extract_model_features(mock_result)
        self.assertEqual(features["hands_count"], 2)
        self.assertTrue(features["has_left_hand"])
        self.assertTrue(features["has_right_hand"])
        self.assertIsNotNone(features["left_hand"])
        self.assertIsNotNone(features["right_hand"])
        self.assertEqual(len(features["left_hand"]), 21)
        self.assertEqual(len(features["right_hand"]), 21)

    def test_independent_smoothing(self):
        # Verify smoothing updates history independently per hand
        class MockLandmark:
            def __init__(self, x, y, z):
                self.x = x
                self.y = y
                self.z = z

        raw_left = [MockLandmark(0.2, 0.3, 0.0) for _ in range(21)]
        raw_right = [MockLandmark(0.8, 0.7, 0.0) for _ in range(21)]

        smoothed_left_1 = self.tracker._smooth_landmarks("Left", raw_left)
        smoothed_right_1 = self.tracker._smooth_landmarks("Right", raw_right)

        self.assertAlmostEqual(smoothed_left_1[0][0], 0.2)
        self.assertAlmostEqual(smoothed_right_1[0][0], 0.8)

        # Move left hand slightly, right hand stays
        raw_left_2 = [MockLandmark(0.25, 0.35, 0.0) for _ in range(21)]
        smoothed_left_2 = self.tracker._smooth_landmarks("Left", raw_left_2)

        # 0.2 * 0.3 + 0.25 * 0.7 = 0.06 + 0.175 = 0.235
        self.assertAlmostEqual(smoothed_left_2[0][0], 0.235)
        # Right hand history should be intact and separate
        self.assertAlmostEqual(self.tracker.prev_landmarks["Right"][0][0], 0.8)


if __name__ == "__main__":
    unittest.main()

