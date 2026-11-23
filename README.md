# TinigSenyas: Filipino Sign Language (FSL) Translation & E-Learning Module

TinigSenyas is an interactive capstone project designed to bridge communication gaps for the Filipino deaf and hard-of-hearing community using real-time AI computer vision, Spatial-Temporal Graph Convolutional Networks (ST-GCN), and bidirectional speech translation.

The v1.0.0 application baseline is built as `1.0.0+2019`. Its recognition bundle
has a separate version (`1.3.0`) because model data and application code have
different release and OTA lifecycles.

Developed for the Capstone Project at Eulogio "Amang" Rodriguez Institute of Science and Technology (EARIST) in collaboration with **KAINAKAP Inclusive and Opportunity Inc.**

## Authors & Project Team
- **Ambuyo, Joyce Bernadeth** — Thesis Leader, AI/Data Engineer, Mobile App Developer
- **Lagapa, John Laurence** — AI / Data Engineer, Communication Leader
- **Nadonga, Sunday Le'chaim L.** — Mobile App Developer, AI/Data Engineer
- **Suarilla, Ynewson** — UI/UX Designer

---

## Key Features
- **Sign-to-Text (ST-GCN):** On-device TFLite models classify **103 conversational FSL classes**, **35 medical signs**, and **28 fingerspelling classes** (A–Z, Ng, Ñ). Phrase and medical modes recognize one isolated sign per window; they do not translate unrestricted continuous sentences.
- **Dual-Hypothesis & Hand Mirroring:** Canonical hand mirroring across the wrist X-axis, enabling seamless recognition for both left-handed and right-handed signers.
- **Dynamic Gated Buffering:** Ultra-fast 0.7-second windowing for static alphabet/number fingerspelling alongside 2.0-second motion gesture recognition.
- **Speech-to-Text:** Mobile transcription requests the Filipino/Tagalog on-device recognizer and keeps audio on the phone; a compatible offline speech pack must be installed. Browser recognition may require internet.
- **Auditory Synthesis (TTS):** Filipino speech uses an installed device voice or the configured online service. An optional downloadable Sherpa-ONNX pack provides offline English speech.
- **Over-The-Air (OTA) Model Sync:** Six model/label files update as one SHA-256-verified bundle; administrator-published vocabulary sync is cached in SQLite and augments offline spelling suggestions.
- **Local Database:** SQLite stores conversation history and the last valid vocabulary cache, so signing and suggestions remain available offline.
- **Accessibility:** Built-in dark mode and adjustable typography scaling.

---

## Tech Stack & Dependencies

### Machine Learning & Vision Architecture
- **Training Framework**: TensorFlow 2 / Keras — `best_fsl_model.keras` and `fsl_model.keras` are training checkpoints kept for reproducibility; **no runtime code loads them**.
- **Neural Architecture**: Spatial-Temporal Graph Convolutional Network (ST-GCN)
- **Edge Inference**: LiteRT on `fsl_model.tflite` → `(1, 60, 75, 3)` in, `(1, 103)` out; `fsl_medical.tflite` → `(1, 60, 75, 3)` in, `(1, 35)` out; and `fsl_alphabet.tflite` → `(1, 63)` in, `(1, 28)` out. TensorFlow itself is not a runtime dependency.
- **Landmark Extractors**: Google MediaPipe Tasks (Pose Landmarker Lite + Hand Landmarker, 75 skeletal joints)
- **Input Tensor**: `(1, 60, 75, 3)` — 60 frames, 75 anatomical joints, normalized $(x, y, z)$ coordinates

### Backend (Python / FastAPI)
Managed via the exact direct pins in `backend/requirements.txt` (the Flutter package graph is locked in `frontend/pubspec.lock`):
- **FastAPI & Uvicorn** (Asynchronous ASGI Web Framework)
- **OpenCV-Python** (`opencv-python` - Video capture, processing, and HUD generation)
- **MediaPipe** (`mediapipe` - Landmark detection)
- **Edge-TTS / Azure Speech** (High-quality natural Filipino voice generation)
- **Pydantic v2** (Strict schema validation)

### Frontend (Flutter / Dart)
Configured in `pubspec.yaml`:
- **`flutter`** (SDK Framework for Android, iOS, Windows - the web target does not compile; see Known Limitations)
- **`camera`** (Live hardware camera feed)
- **`sqflite`** (Local SQLite database storage)
- **`speech_to_text`** (mobile on-device recognition when a Filipino speech pack is installed; browser speech for demos)
- **`dio`** (Asynchronous REST API client)

---

## How to Clone and Run

### Prerequisites
Make sure you have the following installed on your machine:
- [Git](https://git-scm.com/)
- [Python 3.10 - 3.12](https://www.python.org/) — 3.13 and newer do not work; the pinned MediaPipe release has no `cp313` wheel and later releases drop the legacy `mp.solutions` API that `hand_tracker.py` uses.
- [Flutter SDK](https://flutter.dev/)
- A webcam, if you intend to use the backend `/video_feed` stream (it captures the camera attached to the machine hosting the API).

### 1. Clone the Repository
```bash
git clone https://github.com/Sundaylechaim/TinigSenyas.git
cd TinigSenyas
```

### 2. Run the Backend API
```powershell
cd backend
py -3.12 -m venv .venv        # any 3.10-3.12 interpreter
.\.venv\Scripts\activate
pip install -r requirements.txt
uvicorn server:app --host 0.0.0.0 --port 5000 --reload
```
API documentation will be available at [http://127.0.0.1:5000/docs](http://127.0.0.1:5000/docs).

Backend behaviour is configured entirely through environment variables - see
[backend/README.md](backend/README.md). At minimum set `TTS_API_TOKEN` before exposing
the API to anyone, and `APP_ALLOWED_ORIGINS` if a hosted frontend will call it.

## Core Module Map

See [docs/ARCHITECTURE_V1.0.0.md](docs/ARCHITECTURE_V1.0.0.md) for the app/API/data
flow, version policy, and authentication boundaries. The Flutter application
keeps camera recognition, text-to-sign previews, conversation history, and
fallback suggestions local. Mobile offline speech requires a compatible
Filipino/Tagalog speech pack on the device; Filipino TTS depends on an installed
device voice unless online TTS is configured.

See [docs/SYSTEM_EVALUATION_PROTOCOL.md](docs/SYSTEM_EVALUATION_PROTOCOL.md) for
the ISO/IEC 25010 technical test matrix and SUS procedure. It records which
results still require target phones and Deaf FSL participants.

### 3. Run the Frontend App
```powershell
cd ../frontend
flutter pub get
flutter devices                # pick an Android device or emulator
flutter run -d <device-id>
```
The web target does **not** build: `tflite_flutter` and `sherpa_onnx` require `dart:ffi`,
which is unavailable on the web, so `flutter build web` and `flutter run -d chrome` fail at
compile time. `frontend/run_web.ps1` therefore only works if it is pointed at a mobile
device; there is currently no browser deployment for TinigSenyas.

---

## Free Deployment, Offline & OTA Guide (No App Store Fees)

For community testing and sharing with KAINAKAP members:
- See the complete step-by-step guide: [docs/FREE_DEPLOYMENT_AND_OTA_GUIDE.md](docs/FREE_DEPLOYMENT_AND_OTA_GUIDE.md)
- **One-APK Android release**: the tagged GitHub release publishes one signed, Shorebird-enabled ARM64 APK. Run `frontend/build_android_apk.ps1` only when creating a new Shorebird release; it leaves the single APK at `frontend/build/app/outputs/flutter-apk/app-release.apk`.
- **OTA channels**: model and label updates use the six-file verified bundle; Dart code updates use Shorebird after users install the v1.0.0+2019 baseline once.
- **iOS Free Installation**: Sideload the release `.ipa` via Sideloadly with a free Apple ID. The PWA route is unavailable because the web target does not build.

---

## Known Limitations

Recorded here so they are not mistaken for working features during evaluation:

- **No web deployment.** `flutter build web` fails: `tflite_flutter` and `sherpa_onnx` depend on `dart:ffi`. Making the browser target viable requires isolating those services behind conditional imports.
- **The backend is a laptop service, not a cloud service.** `/video_feed` and `/predict_frame` capture `cv2.VideoCapture(0)` on whichever machine runs the API, and recognition state is held in process globals, so there is no camera and no horizontal scale on container hosts.
- **Training code is a submodule.** Fresh clones need `git submodule update --init --recursive` to fetch `tinigsenyas_training/`; the application itself does not require the training files at runtime.
- **`fsl_recognition.py` and `validate_hand_tracking.py` are orphaned.** Nothing imports them; `sign_classifier.py` is the live inference path.
- **iOS releases are unsigned.** CI packages `Runner.app` into an `.ipa` with `--no-codesign`, which only becomes installable after Sideloadly re-signs it with a personal Apple ID (7-day certificate).
