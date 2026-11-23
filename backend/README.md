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
* `PUT /api/v1/admin/vocabulary`: Replaces the active vocabulary snapshot after bearer-token authentication and complete payload validation. Writes use one SQLite transaction; failed updates preserve the previous snapshot.
* Recognition model bundle `1.3.0` contains the conversation, alphabet, and medical models with their matching labels. The app release baseline is `1.0.0+2019`; model versions remain independent so existing clients can compare OTA updates safely. These are pilot candidates and still need signer-independent evaluation with Deaf FSL users.
* Runtime inference reads those models and UTF-8 label files from the canonical `frontend/assets/model` bundle. MediaPipe detector task files remain in `backend/models`. When deploying the backend separately from the repository root, set `FSL_MODEL_DIR` to a copy of the same model bundle; otherwise the backend fails clearly when its required assets are missing.

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
| `ADMIN_API_TOKEN` | *(unset)* | Long random bearer token for `PUT /api/v1/admin/vocabulary` and the administrative DMCA endpoints. When unset admin routes answer 503; never place this token in the mobile app. |
| `OTA_VOCABULARY_DB` | `backend/data/ota_vocabulary.sqlite3` | SQLite file for the administrator-published vocabulary snapshot. Mount this path on persistent storage to retain updates across redeployments. |
| `OTA_ASSET_BASE_URL` | this repo's `main/frontend/assets/model` raw-content URL | Base URL for all model and label assets. |
| `OTA_MODEL_URL` | raw-content URL for `fsl_model.tflite` | Where installed apps download the conversation model. |
| `OTA_MODEL_SHA256` | hash of the bundled `fsl_model.tflite` | Integrity check the app verifies before installing. Must be regenerated (`sha256sum`) whenever the model changes. |
| `OTA_MODEL_VERSION` | `1.3.0` | Only offer a model update when this is newer than the installed model version. |
| `OTA_MIN_APP_VERSION` | `1.2.16` | Legacy version floor understood by already-installed app builds. |
| `OTA_MIN_APP_BUILD` | `2019` | Minimum build number for the v1.0.0 app contract. |
| `FSL_MODEL_DIR` | `../frontend/assets/model` | Directory containing the canonical phrase, alphabet, and medical TFLite models and matching UTF-8 labels. |
| `AZURE_SPEECH_KEY` / `AZURE_SPEECH_REGION` | *(unset)* | Enables the Azure Cognitive Services fallback; without both, Edge-TTS is used. |
| `APP_BASE_URL` / `PHYSICAL_POSTAL_ADDRESS` | `https://tinigsenyas.org` | CAN-SPAM footer values in `email_service.py`. |

### Publish a vocabulary snapshot

Send a complete snapshot over HTTPS. Each item requires a unique positive
`fsl_id`, a unique `word`, a `meaning`, and a `gesture_label`; the request may
contain up to 2,000 items. The public mobile endpoint continues serving the
last saved snapshot if the backend restarts, while the app independently keeps
its last valid local SQLite cache when it cannot reach the backend.

```powershell
$headers = @{ Authorization = "Bearer $env:ADMIN_API_TOKEN" }
$payload = @{
  items = @(
    @{ fsl_id = 1; word = 'Salamat'; meaning = 'Pasasalamat'; gesture_label = 'salamat' },
    @{ fsl_id = 2; word = 'Tulong'; meaning = 'Humingi ng tulong'; gesture_label = 'tulong' }
  )
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Method Put `
  -Uri 'https://api.example.com/api/v1/admin/vocabulary' `
  -Headers $headers -ContentType 'application/json' -Body $payload
```

Verify publication with `GET /api/v1/ota/vocabulary`. Admin updates are
server-side only; the bearer token must never be distributed to app users.

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
