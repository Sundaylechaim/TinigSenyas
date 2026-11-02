# TinigSenyas Backend API (FastAPI)

High-performance, asynchronous REST API serving text-to-speech synthesis, alpha camera landmark streaming, and Over-The-Air (OTA) FSL vocabulary and model synchronization for **TinigSenyas**.

Aligned with the architecture specified in **Chapters 1, 2, and 3** for the Capstone Project at Eulogio "Amang" Rodriguez Institute of Science and Technology (EARIST).

---

## Tech Stack Alignment

* **Framework**: FastAPI (Asynchronous ASGI Web Framework)
* **ASGI Server**: Uvicorn
* **Data Validation**: Pydantic v2
* **Computer Vision**: Google MediaPipe (Hands / Skeletal Topologies) & OpenCV
* **Speech Synthesis**: Edge-TTS (local loopback) & Azure Cognitive Speech Services

---

## Interactive API Documentation (Swagger / OpenAPI)

Once the backend is running, open your browser to view the interactive documentation:
* **Swagger UI**: [http://127.0.0.1:5000/docs](http://127.0.0.1:5000/docs)
* **ReDoc**: [http://127.0.0.1:5000/redoc](http://127.0.0.1:5000/redoc)

---

## Key Endpoints

### 1. Health & Status
* `GET /tts/health`: Validates that the backend service is alive and ready.

### 2. Auditory Synthesis
* `POST /tts/synthesize`: Generates high-quality synthesized Filipino speech (`fil-PH-BlessicaNeural` or `fil-PH-AngeloNeural`) via SSML/Edge-TTS.

### 3. Over-The-Air (OTA) Updates (Chapter 3 Specification)
* `GET /api/v1/ota/manifest`: Returns model versioning, SHA-256 integrity hash, and download URL for the quantized ST-GCN mobile package.
* `GET /api/v1/ota/vocabulary`: Asynchronously synchronizes validated FSL transactional phrases directly into the mobile SQLite database without disrupting offline translation.

### 4. Alpha Camera Tracking Stream
* `GET /video_feed`: Streams webcam frames with real-time MediaPipe skeletal landmark overlays for alpha testing.

---

## Configuration (Environment Variables)

All deployment settings are read from the environment; a local `.env` file next to
`server.py` is loaded automatically by `python-dotenv`. Nothing here is required to boot
the API, but the defaults are for single-machine development only.

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `TTS_API_TOKEN` | *(unset)* | Bearer token for `POST /tts/synthesize`. **Required for any non-local client** - native mobile apps send no `Origin` header, so without this token every remote app request is rejected with 401 and the launcher appears to hang on "speaking". |
| `TTS_ALLOWED_ORIGINS` | *(empty)* | Comma-separated browser origins allowed to call TTS when no token is configured. Applies to browsers only. |
| `APP_ALLOWED_ORIGINS` | *(empty)* | Comma-separated origins added to the API's CORS allow-list. localhost is always permitted; a hosted frontend **must** be listed here or its preflight requests are blocked. |
| `ADMIN_API_TOKEN` | *(unset)* | Bearer token for `POST /api/v1/dmca/takedown` and `/api/v1/dmca/ban_user`. When unset those endpoints answer 503 rather than accepting anonymous content removal. |
| `OTA_MODEL_URL` | this repo's `releases/latest/download/fsl_model.tflite` | Where installed apps download a newer model. |
| `OTA_MODEL_SHA256` | hash of the bundled `fsl_model.tflite` | Integrity check the app verifies before installing. Must be regenerated (`sha256sum`) whenever the model changes. |
| `OTA_MODEL_VERSION` | `1.0.1` | Only offer an update when this is newer than the version stored on the device. |
| `AZURE_SPEECH_KEY` / `AZURE_SPEECH_REGION` | *(unset)* | Enables the Azure Cognitive Services fallback; without both, Edge-TTS is used. |
| `APP_BASE_URL` / `PHYSICAL_POSTAL_ADDRESS` | `https://tinigsenyas.org` | CAN-SPAM footer values in `email_service.py`. |

Note that `video_feed` and `predict_frame` open `cv2.VideoCapture(0)` **on the machine
running the API**. Hosting this on a serverless or container platform gives you no camera
device, so those endpoints only work on the demonstration laptop itself.

---

## How to Run Locally

### Option A: Via the Web Launcher
From the repository root, start the FastAPI backend and the Flutter application:
```powershell
powershell -ExecutionPolicy Bypass -File .\frontend\run_web.ps1
```
This currently targets Chrome, and the web build does not compile (`tflite_flutter` and
`sherpa_onnx` need `dart:ffi`). Run the app on an Android device or emulator instead.

### Option B: Directly with Uvicorn
From the `backend` folder:
```powershell
.\.venv\Scripts\activate
uvicorn server:app --host 0.0.0.0 --port 5000 --reload
```

---

## Running Automated Tests
Requires a Python 3.10-3.12 environment with `requirements.txt` installed. Runs on the standard library, so no extra package is needed.
```powershell
.\.venv\Scripts\python.exe -m unittest discover -s . -p "test_*.py"
```
