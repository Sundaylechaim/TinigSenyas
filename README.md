# TinigSenyas: Filipino Sign Language (FSL) Translation & E-Learning Module

TinigSenyas is an interactive capstone project designed to bridge communication gaps for the Filipino deaf and hard-of-hearing community using real-time AI computer vision, Spatial-Temporal Graph Convolutional Networks (ST-GCN), and bidirectional speech translation.

Developed for the Capstone Project at Eulogio "Amang" Rodriguez Institute of Science and Technology (EARIST) in collaboration with **KAINAKAP Inclusive and Opportunity Inc.**

## Authors & Project Team
- **Ambuyo, Joycce Bernadeth** — Thesis Leader, AI/Data Engineer, Mobile App Developeer
- **Lagapa, John Laurence** — AI / Data Engineer
- **Nadonga, Sunday Le'chaim L.** — Mobile App Developer, AI/Data Engineer
- **Suarilla, Ynewson** — UI/UX Designer

---

## Key Features
- **Sign-to-Text (ST-GCN):** Real-time spatial-temporal skeletal graph classification recognizing **127 Filipino Sign Language (FSL) classes** (letters A–Z, numbers, and transactional phrases).
- **Dual-Hypothesis & Hand Mirroring:** Canonical hand mirroring across the wrist X-axis, enabling seamless recognition for both left-handed and right-handed signers.
- **Dynamic Gated Buffering:** Ultra-fast 0.7-second windowing for static alphabet/number fingerspelling alongside 2.0-second motion gesture recognition.
- **Speech-to-Text:** Live voice transcription rendered into interactive accessible chat dialogues.
- **Auditory Synthesis (TTS):** High-fidelity Tagalog voice synthesis (`fil-PH-BlessicaNeural` / `fil-PH-AngeloNeural`).
- **Over-The-Air (OTA) Model Sync:** Asynchronous model and vocabulary updates with SHA-256 integrity verification.
- **Local Database:** SQLite integration for offline storage of translated dialogues.
- **Accessibility:** Built-in dark mode and adjustable typography scaling.

---

## Tech Stack & Dependencies

### Machine Learning & Vision Architecture
- **Model Framework**: TensorFlow 2 / Keras (`best_fsl_model.keras`)
- **Neural Architecture**: Spatial-Temporal Graph Convolutional Network (ST-GCN)
- **Edge Inference**: TensorFlow Lite / LiteRT (`fsl_model.tflite` - 183 KB)
- **Landmark Extractors**: Google MediaPipe Tasks (Pose Landmarker Lite + Hand Landmarker, 75 skeletal joints)
- **Input Tensor**: `(1, 60, 75, 3)` — 60 frames, 75 anatomical joints, normalized $(x, y, z)$ coordinates

### Backend (Python / FastAPI)
Managed via `pip`:
- **FastAPI & Uvicorn** (Asynchronous ASGI Web Framework)
- **OpenCV-Python** (`opencv-python` - Video capture, processing, and HUD generation)
- **MediaPipe** (`mediapipe` - Landmark detection)
- **Edge-TTS / Azure Speech** (High-quality natural Filipino voice generation)
- **Pydantic v2** (Strict schema validation)

### Frontend (Flutter / Dart)
Configured in `pubspec.yaml`:
- **`flutter`** (SDK Framework for Web, Android, iOS, Windows)
- **`camera`** (Live hardware camera feed)
- **`sqflite`** (Local SQLite database storage)
- **`speech_to_text`** (Browser-native & mobile speech transcription)
- **`dio`** (Asynchronous REST API client)

---

## How to Clone and Run

### Prerequisites
Make sure you have the following installed on your machine:
- [Git](https://git-scm.com/)
- [Python 3.10+](https://www.python.org/)
- [Flutter SDK](https://flutter.dev/)

### 1. Clone the Repository
```bash
git clone https://github.com/Sundaylechaim/TinigSenyas.git
cd TinigSenyas/TinigSenyas
```

### 2. Run the Backend API
```powershell
cd backend
.\.venv\Scripts\activate
uvicorn server:app --host 0.0.0.0 --port 5000 --reload
```
API documentation will be available at [http://127.0.0.1:5000/docs](http://127.0.0.1:5000/docs).

### 3. Run the Frontend App
```powershell
cd ../frontend
flutter pub get
flutter run -d chrome
```
Or launch both simultaneously using the automated launcher:
```powershell
powershell -ExecutionPolicy Bypass -File .\frontend\run_web.ps1
```

---

## Free Deployment, Offline & OTA Guide (No App Store Fees)

For community testing and sharing with KAINAKAP members:
- See the complete step-by-step guide: [docs/FREE_DEPLOYMENT_AND_OTA_GUIDE.md](docs/FREE_DEPLOYMENT_AND_OTA_GUIDE.md)
- Complete Chapter 3 ML technical specifications: [docs/CHAPTER3_MODEL_SPECIFICATIONS.md](docs/CHAPTER3_MODEL_SPECIFICATIONS.md)
- **One-Click Android Build**: Run `frontend/build_android_apk.ps1` to compile the release APK and automatically prepare the file for Google Drive distribution.
- **iOS Free Installation**: Run as a PWA via Safari ("Add to Home Screen") or sideload via Sideloadly with a free Apple ID.
