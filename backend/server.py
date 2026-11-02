import hmac
import logging
import os
import sys
import warnings
from pathlib import Path

# Automatically load environment variables from .env
try:
    from dotenv import load_dotenv
    _env_path = Path(__file__).resolve().parent / ".env"
    if _env_path.exists():
        load_dotenv(dotenv_path=_env_path)
except Exception:
    pass

# Suppress noisy oneDNN and deprecation terminal spam
os.environ["TF_ENABLE_ONEDNN_OPTS"] = os.environ.get("TF_ENABLE_ONEDNN_OPTS", "0")
os.environ["TF_CPP_MIN_LOG_LEVEL"] = os.environ.get("TF_CPP_MIN_LOG_LEVEL", "3")
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=DeprecationWarning)

import cv2
import mediapipe as mp
import uvicorn
import numpy as np
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import List, Optional

from tts_api import tts_api
from hand_tracker import HandTracker, HandValidationResult
from email_service import suppression_manager

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("tinigsenyas.backend")

try:
    from sign_classifier import SignClassifier
    HAS_SIGN_CLASSIFIER = True
except Exception as _e:
    logger.warning("SignClassifier not loaded yet: %s", _e)
    HAS_SIGN_CLASSIFIER = False

app = FastAPI(
    title="TinigSenyas Backend API",
    description="Multimodal Sign Language Translation & Asynchronous OTA Synchronization Backend for KAINAKAP Inclusive and Opportunity Inc.",
    version="1.0.0",
)

# Secure CORS configuration for Flutter web / mobile clients.
# Localhost entries back the local dev launcher; hosted frontends must be listed in
# APP_ALLOWED_ORIGINS (comma-separated) or their preflight requests are rejected.
ALLOWED_ORIGINS = [
    "http://localhost:5001",
    "http://127.0.0.1:5001",
    "http://localhost:3000",
    "http://127.0.0.1:3000",
] + [
    item.strip()
    for item in os.environ.get("APP_ALLOWED_ORIGINS", "").split(",")
    if item.strip()
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_origin_regex=r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$",
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


@app.middleware("http")
async def add_security_headers(request, call_next):
    """Enforces standard web security headers on all API responses."""
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    if not request.url.path.startswith("/video_feed"):
        response.headers["X-Frame-Options"] = "SAMEORIGIN"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Cross-Origin-Resource-Policy"] = "cross-origin"
    return response

@app.get("/health", tags=["Health"])
@app.get("/tts/health", tags=["Health"])
async def health_check():
    return {"status": "ok", "service": "TinigSenyas Backend"}

# Mount TTS Router
app.include_router(tts_api)

# ---------------------------------------------------------------------------
# Over-The-Air (OTA) Synchronization Endpoints (Chapters 1 & 3 Specification)
# ---------------------------------------------------------------------------

class FSLVocabularyItem(BaseModel):
    fsl_id: int
    word: str
    meaning: str
    gesture_label: str
    video_path: Optional[str] = None
    created_at: Optional[str] = None

class ModelManifest(BaseModel):
    version: str
    url: str
    sha256: str
    min_app_version: str
    notes: str

# Default seeded FSL transactional vocabulary as described in Scope
_DEFAULT_VOCABULARY: List[FSLVocabularyItem] = [
    FSLVocabularyItem(fsl_id=1, word="Salamat", meaning="Pagpapahayag ng pasasalamat (Thank you)", gesture_label="salamat"),
    FSLVocabularyItem(fsl_id=2, word="Magkano", meaning="Pagtatanong ng presyo o bayad (How much)", gesture_label="magkano"),
    FSLVocabularyItem(fsl_id=3, word="Tulong", meaning="Humihingi ng saklolo o tulong (Help)", gesture_label="tulong"),
    FSLVocabularyItem(fsl_id=4, word="Kumusta", meaning="Pambungad na pagbati (Hello / How are you)", gesture_label="kumusta"),
    FSLVocabularyItem(fsl_id=5, word="Oo", meaning="Pagsang-ayon (Yes)", gesture_label="oo"),
    FSLVocabularyItem(fsl_id=6, word="Hindi", meaning="Pagtanggi (No)", gesture_label="hindi"),
    FSLVocabularyItem(fsl_id=7, word="Saan", meaning="Pagtatanong ng lokasyon o direksyon (Where)", gesture_label="saan"),
    FSLVocabularyItem(fsl_id=8, word="Pakiusap", meaning="Magalang na kahilingan (Please)", gesture_label="pakiusap"),
]

# OTA defaults describe the model actually bundled in this repository. Publish a new
# .tflite asset and override these three variables to push an update to installed apps.
_OTA_MODEL_URL = os.environ.get(
    "OTA_MODEL_URL",
    "https://github.com/Sundaylechaim/TinigSenyas/releases/latest/download/fsl_model.tflite",
)
_OTA_MODEL_SHA256 = os.environ.get(
    "OTA_MODEL_SHA256",
    "b35f40d6dc2ca8f7b73b0412834d462b71dbcbfefe29a9ab4b1ab8a810baa3a4",
)
_OTA_MODEL_VERSION = os.environ.get("OTA_MODEL_VERSION", "1.0.1")


@app.get("/api/v1/ota/manifest", response_model=ModelManifest, tags=["OTA Updates"])
async def get_model_manifest():
    """
    Returns the latest ST-GCN quantized model metadata for mobile Over-The-Air deployment.
    """
    return ModelManifest(
        version=_OTA_MODEL_VERSION,
        url=_OTA_MODEL_URL,
        sha256=_OTA_MODEL_SHA256,
        min_app_version="1.0.0",
        notes="Optimized ST-GCN quantized model for transactional FSL isolated gestures.",
    )

@app.get("/api/v1/ota/vocabulary", response_model=List[FSLVocabularyItem], tags=["OTA Updates"])
async def get_vocabulary_sync():
    """
    Asynchronous OTA dictionary synchronization endpoint.
    Updates the mobile client's localized SQLite database without disrupting core offline translation.
    """
    return _DEFAULT_VOCABULARY

# ---------------------------------------------------------------------------
# CAN-SPAM Compliance Endpoint (15 U.S.C. § 7704)
# ---------------------------------------------------------------------------

@app.get("/api/v1/unsubscribe", tags=["Legal & CAN-SPAM"])
async def unsubscribe_email(email: str):
    """
    CAN-SPAM mandatory 1-click opt-out endpoint.
    Permanently suppresses future commercial messages to this email address.
    """
    try:
        suppression_manager.add_suppression(email)
        return {
            "status": "success",
            "message": f"Successfully unsubscribed {email}. You will not receive further marketing emails.",
        }
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

# ---------------------------------------------------------------------------
# DMCA Safe Harbor Endpoints (17 U.S.C. § 512)
# ---------------------------------------------------------------------------

class DMCATakedownRequest(BaseModel):
    item_id: int
    item_type: str  # 'vocabulary', 'gesture', 'media'
    complaining_party: str
    alleged_copyright_holder: str
    work_description: str
    infringing_url_or_label: str
    signature: str

class DMCABanRequest(BaseModel):
    user_id: str
    infringement_count: int
    reason: str

_BANNED_REPEAT_INFRINGERS = set()


def _require_admin(authorization: Optional[str]) -> None:
    """Fails closed when ADMIN_API_TOKEN is unset, so content removal can never be anonymous."""
    expected = os.environ.get("ADMIN_API_TOKEN", "")
    if not expected:
        raise HTTPException(
            status_code=503,
            detail="Content administration is disabled. Set ADMIN_API_TOKEN to enable it.",
        )
    if not hmac.compare_digest(authorization or "", f"Bearer {expected}"):
        raise HTTPException(status_code=401, detail="Unauthorized administration request.")


@app.post("/api/v1/dmca/takedown", tags=["DMCA Safe Harbor"])
async def process_dmca_takedown(
    payload: DMCATakedownRequest,
    authorization: Optional[str] = Header(None),
):
    """
    DMCA § 512(c) expedited content removal endpoint.
    Immediately disables or removes alleged infringing content upon notice.
    """
    _require_admin(authorization)
    logger.warning("Processing DMCA takedown notice for %s %s from %s", payload.item_type, payload.item_id, payload.complaining_party)
    global _DEFAULT_VOCABULARY
    if payload.item_type == "vocabulary":
        _DEFAULT_VOCABULARY = [item for item in _DEFAULT_VOCABULARY if item.fsl_id != payload.item_id]
    return {
        "status": "content_removed",
        "takedown_id": f"dmca-{payload.item_id}",
        "message": f"Content item {payload.item_id} disabled in compliance with 17 U.S.C. § 512(c).",
    }

@app.post("/api/v1/dmca/ban_user", tags=["DMCA Safe Harbor"])
async def ban_repeat_infringer(
    payload: DMCABanRequest,
    authorization: Optional[str] = Header(None),
):
    """
    DMCA § 512(i) repeat infringer policy enforcement endpoint.
    Permanently bans accounts or users found to repeatedly infringe intellectual property.
    """
    _require_admin(authorization)
    if payload.infringement_count < 2:
        raise HTTPException(status_code=400, detail="Repeat infringer status requires at least 2 substantiated violations.")
    _BANNED_REPEAT_INFRINGERS.add(payload.user_id)
    logger.warning("User '%s' permanently banned under DMCA repeat infringer policy.", payload.user_id)
    return {
        "status": "user_banned",
        "user_id": payload.user_id,
        "message": f"User '{payload.user_id}' has been permanently terminated under DMCA Repeat Infringer Policy.",
    }

# ---------------------------------------------------------------------------
# MediaPipe Camera Stream & ST-GCN Sign Language Classification
# ---------------------------------------------------------------------------

latest_hand_result: Optional[HandValidationResult] = None
latest_hand_features: dict = {}
latest_prediction: dict = {
    "label": None,
    "confidence": 0.0,
    "top2_label": "",
    "top2_confidence": 0.0,
    "hands_count": 0,
    "buffer_progress": 0.0,
    "window_duration_seconds": 2.0,
    "is_stable": False,
    "is_paused": False,
    "palm_hold_progress": 0.0,
}
global_classifier = None


def generate_frames():
    global latest_hand_result, latest_hand_features, latest_prediction, global_classifier
    if sys.platform == "win32":
        camera = cv2.VideoCapture(0, cv2.CAP_DSHOW)
        if not camera.isOpened():
            camera = cv2.VideoCapture(0)
    else:
        camera = cv2.VideoCapture(0)
    camera.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    camera.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)

    classifier = global_classifier
    if HAS_SIGN_CLASSIFIER:
        try:
            classifier = SignClassifier()
            global_classifier = classifier
            logger.info("ST-GCN SignClassifier active for live video feed.")
        except Exception as exc:
            logger.error("Failed to initialize SignClassifier, falling back to HandTracker: %s", exc)

    tracker = None
    if classifier is None:
        tracker = HandTracker(
            max_num_hands=2,
            min_detection_confidence=0.6,
            min_tracking_confidence=0.5,
            smoothing_alpha=0.7,
            mirror_camera=True,
        )

    try:
        while True:
            success, frame = camera.read()
            if not success:
                break

            if classifier is not None:
                processed_frame, pred_payload = classifier.process_frame(frame)
                latest_prediction = pred_payload
            else:
                processed_frame, result = tracker.process_frame(frame)
                latest_hand_result = result
                latest_hand_features = tracker.extract_model_features(result)

            ret, buffer = cv2.imencode(".jpg", processed_frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
            if not ret:
                continue
            frame_bytes = buffer.tobytes()

            yield (
                b"--frame\r\n"
                b"Content-Type: image/jpeg\r\n\r\n" + frame_bytes + b"\r\n"
            )
    finally:
        camera.release()
        if tracker:
            tracker.close()


@app.get("/video_feed", tags=["Camera Stream"])
def video_feed():
    """
    Live MJPEG stream with real-time MediaPipe ST-GCN sign language recognition HUD.
    """
    return StreamingResponse(
        generate_frames(),
        media_type="multipart/x-mixed-replace; boundary=frame",
    )


@app.get("/api/v1/predict/live", tags=["Sign Language Recognition"])
def get_live_prediction():
    """
    Returns the real-time ST-GCN predicted FSL sign gesture, confidence score, and buffer progress.
    """
    return latest_prediction


@app.post("/api/v1/predict/frame", tags=["Sign Language Recognition"])
async def predict_frame(request: Request):
    """
    Processes an uploaded camera frame for landmarks and ST-GCN sign language recognition.
    Supports raw JPEG bytes and multipart uploads.
    """
    global latest_hand_result, latest_hand_features, latest_prediction, global_classifier

    body = await request.body()
    if not body:
        raise HTTPException(status_code=400, detail="Empty frame request body")

    # Extract JPEG bytes whether passed directly or wrapped in multipart boundary
    soi = body.find(b"\xff\xd8")
    eoi = body.rfind(b"\xff\xd9")
    if soi != -1 and eoi != -1 and eoi > soi:
        contents = body[soi : eoi + 2]
    else:
        contents = body

    nparr = np.frombuffer(contents, np.uint8)
    img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    if img is None:
        raise HTTPException(status_code=400, detail="Invalid image file or format")

    h, w = img.shape[:2]
    landmarks_list = []
    status = "collecting"
    frames_collected = 0
    label = None
    confidence = 0.0

    if global_classifier is None and HAS_SIGN_CLASSIFIER:
        try:
            global_classifier = SignClassifier()
            logger.info("ST-GCN SignClassifier initialized for predict_frame.")
        except Exception as exc:
            logger.error("Failed to initialize SignClassifier: %s", exc)

    if global_classifier is not None:
        processed_frame, pred_payload = global_classifier.process_frame(img)
        latest_prediction = pred_payload
        label = pred_payload.get("label")
        confidence = pred_payload.get("confidence", 0.0)
        status = "recognized" if pred_payload.get("is_stable") else "collecting"
        frames_collected = len(global_classifier.frame_buffer)
        if hasattr(global_classifier, "norm_hand_63") and global_classifier.norm_hand_63 is not None:
            pts = global_classifier.norm_hand_63.reshape(21, 3)[:, :2].tolist()
            landmarks_list.append(pts)
    else:
        tracker = HandTracker(
            max_num_hands=2,
            min_detection_confidence=0.6,
            min_tracking_confidence=0.5,
            smoothing_alpha=0.7,
            mirror_camera=True,
        )
        try:
            _, result = tracker.process_frame(img)
            latest_hand_result = result
            latest_hand_features = tracker.extract_model_features(result)
            for hand in result.hands:
                landmarks_list.append([[lm["x"], lm["y"]] for lm in hand.landmarks])
        finally:
            tracker.close()

    return {
        "status": status,
        "frames_collected": frames_collected,
        "sequence_length": 60,
        "hand_landmarks": landmarks_list,
        "frame_width": w,
        "frame_height": h,
        "label": label,
        "confidence": confidence,
    }


@app.get("/api/v1/hands/status", tags=["Hand Validation"])
def get_hand_status():
    """
    Real-time status of detected hands, left-to-right signing zones, and boundary warnings.
    """
    if latest_hand_result is None:
        return {
            "status": "idle",
            "hands_count": 0,
            "has_left_hand": False,
            "has_right_hand": False,
            "zones_covered": [],
            "edge_warning": False,
            "fps": 0.0,
        }

    return {
        "status": "tracking",
        "hands_count": latest_hand_result.hands_count,
        "has_left_hand": latest_hand_result.has_left_hand,
        "has_right_hand": latest_hand_result.has_right_hand,
        "zones_covered": latest_hand_result.zones_covered,
        "edge_warning": latest_hand_result.edge_warning,
        "fps": latest_hand_result.fps,
        "hands": [
            {
                "handedness": h.handedness,
                "confidence": h.confidence,
                "zone": h.zone,
                "center": h.center,
                "is_clipped": h.is_clipped,
            }
            for h in latest_hand_result.hands
        ],
    }


@app.get("/api/v1/hands/features", tags=["Hand Validation"])
def get_hand_features():
    """
    Structured landmark extraction coordinates for ST-GCN or FSL gesture classification models.
    """
    return latest_hand_features or {
        "hands_count": 0,
        "has_left_hand": False,
        "has_right_hand": False,
        "zones_covered": [],
        "left_hand": None,
        "right_hand": None,
    }

if __name__ == "__main__":
    uvicorn.run("server:app", host="0.0.0.0", port=5000, reload=False)
