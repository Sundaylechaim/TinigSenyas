import os
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from server import app


class ServerEndpointTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)

    def test_ota_manifest(self):
        response = self.client.get("/api/v1/ota/manifest")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIn("version", data)
        self.assertIn("url", data)

    def test_ota_vocabulary(self):
        response = self.client.get("/api/v1/ota/vocabulary")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIsInstance(data, list)
        self.assertGreater(len(data), 0)

    def test_hands_status_idle(self):
        response = self.client.get("/api/v1/hands/status")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIn("hands_count", data)
        self.assertIn("has_left_hand", data)
        self.assertIn("has_right_hand", data)

    def test_hands_features_idle(self):
        response = self.client.get("/api/v1/hands/features")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIn("hands_count", data)
        self.assertIn("zones_covered", data)

    def test_can_spam_unsubscribe(self):
        response = self.client.get("/api/v1/unsubscribe?email=test_user@example.com")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertEqual(data["status"], "success")

    def test_dmca_takedown(self):
        payload = {
            "item_id": 1,
            "item_type": "vocabulary",
            "complaining_party": "Test Copyright Owner",
            "alleged_copyright_holder": "Test Holder",
            "work_description": "Sign vocabulary item",
            "infringing_url_or_label": "salamat",
            "signature": "John Doe",
        }
        with patch.dict(os.environ, {"ADMIN_API_TOKEN": "test-admin-token"}):
            rejected = self.client.post("/api/v1/dmca/takedown", json=payload)
            self.assertEqual(rejected.status_code, 401)

            response = self.client.post(
                "/api/v1/dmca/takedown",
                json=payload,
                headers={"Authorization": "Bearer test-admin-token"},
            )
            self.assertEqual(response.status_code, 200)
            data = response.json()
            self.assertEqual(data["status"], "content_removed")

        disabled = self.client.post("/api/v1/dmca/takedown", json=payload)
        self.assertEqual(disabled.status_code, 503)

    def test_dmca_ban_repeat_infringer(self):
        payload = {
            "user_id": "infringer_99",
            "infringement_count": 3,
            "reason": "Multiple substantiated DMCA copyright takedown notices",
        }
        with patch.dict(os.environ, {"ADMIN_API_TOKEN": "test-admin-token"}):
            response = self.client.post(
                "/api/v1/dmca/ban_user",
                json=payload,
                headers={"Authorization": "Bearer test-admin-token"},
            )
            self.assertEqual(response.status_code, 200)
            data = response.json()
            self.assertEqual(data["status"], "user_banned")

    def test_predict_frame_endpoint(self):
        import cv2
        import numpy as np
        # Generate a test blank 640x480 frame
        blank = np.zeros((480, 640, 3), dtype=np.uint8)
        _, encoded = cv2.imencode(".jpg", blank)
        response = self.client.post(
            "/api/v1/predict/frame",
            content=encoded.tobytes(),
            headers={"Content-Type": "image/jpeg"},
        )
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIn("status", data)
        self.assertIn("sequence_length", data)
        self.assertEqual(data["frame_width"], 640)
        self.assertEqual(data["frame_height"], 480)


if __name__ == "__main__":
    unittest.main()
