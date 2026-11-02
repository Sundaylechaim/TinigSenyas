# TinigSenyas: Free Mobile Deployment, Offline Functionality & OTA Updates Guide

> **Target Audience**: TinigSenyas Project Team (Ambuyo, Lagapa, Nadonga, Suarilla) & Community Testers / KAINAKAP Members.  
> **Goal**: Distribute and maintain the app for Android & iOS **100% free of charge** (without paying $25 Google Play or $99/year Apple Developer fees), ensure seamless **offline-first execution**, and manage **Over-The-Air (OTA) updates**.

---

## Table of Contents
1. [Android Free Distribution (Google Drive)](#1-android-free-distribution-google-drive)
2. [iOS Free Distribution (PWA & Sideloading)](#2-ios-free-distribution-pwa--sideloading)
3. [Offline-First Architecture Guarantee](#3-offline-first-architecture-guarantee)
4. [Over-The-Air (OTA) Updates Workflow](#4-over-the-air-ota-updates-workflow)
5. [Quick Build Scripts](#5-quick-build-scripts)

---

## 1. Android Free Distribution (Google Drive)

Android allows direct installation of APKs ("sideloading") without any store fees.

### Step 1: Build the Release APK
Open PowerShell in `TinigSenyas/frontend` and run:

```powershell
# Option A: Universal APK (runs on all Android phones, ~70MB)
flutter build apk --release

# Option B: Optimized Split APKs (RECOMMENDED, ~35MB each)
flutter build apk --split-per-abi
```

When building split APKs, Flutter creates 3 files in `frontend/build/app/outputs/flutter-apk/`:
- `app-arm64-v8a-release.apk` *(Use this! Covers 90%+ of modern Android phones)*
- `app-armeabi-v7a-release.apk` *(For older 32-bit Android phones)*
- `app-x86_64-release.apk` *(For emulators / Intel Chromebooks)*

### Step 2: Upload to Google Drive
1. Create a dedicated folder in Google Drive (e.g., `TinigSenyas Releases`).
2. Upload `app-release.apk` (or `app-arm64-v8a-release.apk`).
3. Right-click the folder/file $\rightarrow$ **Share** $\rightarrow$ set access to **"Anyone with the link can view/download"**.

### Step 3: Instructions to Send to Members / Testers
Provide these 4 simple steps to your testers:

1. **Download**: Open the Google Drive link on your Android phone and tap **Download**.
2. **Open APK**: Open your phone's *Downloads* or *Files* app and tap the `.apk` file.
3. **Allow Unknown Sources**:
   - If prompted: *"For your security, your phone is not allowed to install unknown apps from this source"*, tap **Settings**.
   - Toggle on **"Allow from this source"**, then press the back button.
4. **Google Play Protect**:
   - If a screen appears saying *"Unrecognized app"* or *"Blocked by Play Protect"*, tap **More details** $\rightarrow$ **Install anyway**.
5. Tap **Install** and open **TinigSenyas**!

---

## 2. iOS Free Distribution (PWA & Sideloading)

Apple does not permit direct `.ipa` downloads through Google Drive without cryptographic developer signing. Here are the two 100% free paths:

### Method A: Progressive Web App / PWA (Zero Install Friction — Recommended)
Since TinigSenyas supports Flutter Web, iPhone users can run it as an installed app icon on their home screen without any Mac or certificate:

1. **Host the Web Version for Free**:
   - Build web: `flutter build web --release`
   - Host the `frontend/build/web` folder on **GitHub Pages**, **Vercel**, or **Firebase Hosting** (all free).
2. **User Installation on iPhone**:
   - Open Safari and navigate to your hosted URL.
   - Tap the **Share icon** (square with an upward arrow at the bottom).
   - Scroll down and tap **"Add to Home Screen"**.
   - Tap **Add** in the top-right corner.
3. **Result**: An app icon appears on their iPhone home screen. When launched, it runs full-screen (without browser URLs or navigation bars) and caches assets offline.

### Method B: Sideloading the Native .IPA via Sideloadly (Free Apple ID)
If testers require the native iOS app:
1. Build the archive on a Mac:
   ```bash
   flutter build ios --release --no-codesign
   ```
2. Create an `.ipa` container:
   - Create a folder named `Payload`.
   - Copy `build/ios/iphoneos/Runner.app` into `Payload/`.
   - Zip `Payload` and rename `Payload.zip` to `TinigSenyas.ipa`.
3. Provide `TinigSenyas.ipa` to the tester.
4. Tester downloads **[Sideloadly](https://sideloadly.io/)** (free for Windows & Mac), plugs in their iPhone, drags the `.ipa` into Sideloadly, and signs in with their standard free Apple ID.
5. On the iPhone: Go to **Settings** $\rightarrow$ **General** $\rightarrow$ **VPN & Device Management** $\rightarrow$ tap the Apple ID $\rightarrow$ tap **Trust**.
*(Note: Free Apple ID certificates remain valid for 7 days).*

---

## 3. Offline-First Architecture Guarantee

TinigSenyas is architected to be **100% usable without internet**:

| Feature | Offline Mechanism | Online Enhancement |
| :--- | :--- | :--- |
| **Sign-to-Text** | On-device machine learning inference runs locally via camera stream. Zero server calls. | Can download new gesture weights over the air. |
| **Speech-to-Text** | On-device speech recognition via OS speech packs. | Cloud-assisted transcription if connected. |
| **Text-to-Speech** | Native device speech engine (`flutter_tts`) and pre-downloaded Sherpa-ONNX offline voice. | High-definition cloud TTS server fallback. |
| **History & Chats** | Local SQLite database (`DatabaseHelper`) stored inside the device's internal storage sandbox. | History CSV export. |
| **Network State** | `ConnectivityService` detects disconnection immediately and prevents any freezing or unhandled network crashes. | `ConnectivityBadge` displays current status. |

---

## 4. Over-The-Air (OTA) Updates Workflow

Because the app is distributed via Google Drive rather than the Play Store, here is how you keep users updated:

### Layer 1: AI Model & Gesture Vocabulary Updates (No Re-installation Required!)
When you retrain the FSL recognition model or add new sign vocabulary:
1. Host the new model file (`fsl_model.tflite` or `.onnx`) and `manifest.json` on a public link (GitHub Releases, raw GitHub, or Google Drive direct link).
2. Format of `manifest.json`:
   ```json
   {
     "version": "1.1.0",
     "url": "https://your-public-storage.com/models/fsl_model_v1.1.0.tflite",
     "sha256": "4b6fbc908d964b3389385212b27cdecf...",
     "min_app_version": "1.0.0",
     "notes": "Added 25 new emergency and healthcare FSL signs."
   }
   ```
3. Inside the app, members go to **Settings** $\rightarrow$ **Model** $\rightarrow$ tap **"Check for Model Updates (OTA)"**.
4. The app streams the download, verifies the SHA-256 checksum, saves it locally, and hot-swaps the model without restarting the app!

### Layer 2: App Code Updates (Version 2.0 APK)
When you add new UI screens or major features:
1. Bump `version: 1.0.1+2` in `frontend/pubspec.yaml`.
2. Build the new release APK:
   ```powershell
   flutter build apk --release
   ```
3. Upload `app-release.apk` to the same Google Drive folder.
4. Tell users to download and tap install.
5. **Data Safety**: Android automatically installs the update over the existing app. **All translation history, user preferences, and local models are preserved safely in SQLite**.

---

## 5. Quick Build Scripts

A helper script has been placed in `frontend/build_android_apk.ps1`.  
Whenever you want to build a local Android release, simply right-click it and select **Run with PowerShell** (or run `.\build_android_apk.ps1` from `frontend`). It will compile the release APK and locate the file.

---

## 6. Unified Cloud CI/CD Release (Android + iOS Together)

Instead of building manually from scratch every time, the project includes a dedicated build script (`frontend/build_android_apk.ps1`).

### How to Build the Release APK:
Run from `frontend`:
```powershell
.\build_android_apk.ps1
```

This runs GitHub Actions runners in parallel:
- **Android Runner**: Compiles `TinigSenyas-Android.apk`.
- **macOS Runner (unmac)**: Compiles `TinigSenyas-iOS.ipa` and `TinigSenyas-iOS-Simulator.zip`.
- **Unified Release Publisher**: Combines both platforms into a single GitHub Release.

### Unified Download Page:
A device-detecting download portal is available at `docs/index.html`. When opened on any smartphone:
- **Android phones:** Automatically detects Android and highlights the APK download.
- **iPhones:** Automatically detects iOS and provides the IPA + Sideloadly / Web Simulator links.
- **Desktop:** Allows testers to toggle between Android and iOS.


