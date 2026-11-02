# TinigSenyas: Free Mobile Deployment, Offline Functionality & OTA Updates Guide

> **Target Audience**: TinigSenyas Project Team (Ambuyo, Lagapa, Nadonga, Suarilla) & Community Testers / KAINAKAP Members.  
> **Goal**: Distribute and maintain the app for Android & iOS **100% free of charge** (without paying $25 Google Play or $99/year Apple Developer fees), ensure seamless **offline-first execution**, and manage **Over-The-Air (OTA) updates**.

---

## Table of Contents
1. [Android Free Distribution (Google Drive)](#1-android-free-distribution-google-drive)
2. [iOS Free Distribution (Sideloading)](#2-ios-free-distribution-sideloading)
3. [Offline-First Architecture Guarantee](#3-offline-first-architecture-guarantee)
4. [Over-The-Air (OTA) Updates Workflow](#4-over-the-air-ota-updates-workflow)
5. [Quick Build Scripts](#5-quick-build-scripts)

---

## 1. Android Free Distribution (Google Drive)

Android allows direct installation of APKs ("sideloading") without any store fees.

### Step 1: Build the Release APK
Open PowerShell in `TinigSenyas/frontend` and run:

```powershell
# Option A: Universal APK (runs on all Android phones, but bundles 4 ABIs)
flutter build apk --release

# Option B: Optimized Split APKs (RECOMMENDED)
flutter build apk --split-per-abi
```

Measured from the current build (release mode, no R8 minification):

| Build | Size |
| :--- | :--- |
| Universal `app-release.apk` | **198.4 MB** |
| `app-arm64-v8a-release.apk` | **78.1 MB** |
| `app-armeabi-v7a-release.apk` | **62.4 MB** |
| `app-x86_64-release.apk` | 87.5 MB (emulators / Intel Chromebooks only) |

Always distribute the per-ABI builds - the universal APK is more than twice the size
because it carries `libonnxruntime`, MediaPipe, and LiteRT natives for every architecture.

> **Pick one ABI per tester and stay on it.** Split builds are stamped with a different `versionCode` per architecture (arm64 2001, armv7 1001, x86_64 4001 for a pubspec `1.0.0+1`), because Android encodes the ABI in the version code. A phone that installed the arm64 build refuses the armv7 build as a downgrade, and the same applies to every future release: bump `version: x.y.z+N` in `pubspec.yaml` so each new upload is higher than the last, and tell testers which single file to use.

When building split APKs, Flutter creates the files above in `frontend/build/app/outputs/flutter-apk/`:
- `app-arm64-v8a-release.apk` *(Use this! Covers 90%+ of modern Android phones)*
- `app-armeabi-v7a-release.apk` *(For older 32-bit Android phones)*
- `app-x86_64-release.apk` *(For emulators / Intel Chromebooks)*

> **Signing:** without `frontend/android/key.properties`, release builds are signed with Flutter's debug key. That is fine for tester sideloads, but every tester must uninstall the old build whenever you switch keys, and debug-signed APKs cannot go on Google Play or upgrade in place across releases. Create a keystore and add `key.properties` (already gitignored) for a stable release signature.

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

## 2. iOS Free Distribution (Sideloading)

Apple does not permit direct `.ipa` downloads through Google Drive without cryptographic developer signing.

> **⚠️ The PWA route is not currently available.** This guide previously recommended hosting the Flutter web build so iPhone users could "Add to Home Screen" without a Mac or certificate. That does not work today: `flutter build web` fails to compile because `tflite_flutter` and `sherpa_onnx` require `dart:ffi`, which the web target does not support. There is no browser deployment of TinigSenyas until those dependencies are isolated behind conditional imports or replaced. Sideloading the native build is the only free iPhone path.

### Method A: Sideloading the Native .IPA via Sideloadly (Free Apple ID)
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
| **Text-to-Speech** | Native device speech engine (`flutter_tts`). The Sherpa-ONNX English voice is **not** bundled - the tester downloads a 147 MB model once, on demand, and it then works offline. | High-definition cloud TTS server fallback. |
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

> **The `sha256` must be a real digest of the exact file at `url`.** The app refuses to install a model whose checksum does not match, so a placeholder value silently disables OTA for every tester. Regenerate it after every retrain:
> ```powershell
> # PowerShell
> (Get-FileHash .\fsl_model.tflite -Algorithm SHA256).Hash.ToLower()
> ```
> Then publish the model as a GitHub Release asset named `fsl_model.tflite` and set the backend's `OTA_MODEL_URL`, `OTA_MODEL_SHA256`, and `OTA_MODEL_VERSION` (see `backend/README.md`). `frontend/assets/model/manifest.json` - the fallback used when no server URL is configured - must carry the same values.
> An update is only offered when `version` is strictly greater than the version already stored on the device, so bumping the model file without bumping `version` does nothing.

### Layer 2: App Code Updates (Version 2.0 APK)
When you add new UI screens or major features:
1. Bump `version: 1.0.1+2` in `frontend/pubspec.yaml`.
2. Build the new release APKs:
   ```powershell
   flutter build apk --release --split-per-abi
   ```
3. Upload `app-arm64-v8a-release.apk` (and `app-armeabi-v7a-release.apk` for older phones) to the same Google Drive folder.
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
- **Test Gate**: `flutter analyze`, `flutter test`, and the backend `unittest` suite must pass before any artifact is built.
- **Android Runner**: Compiles `TinigSenyas-Android-arm64.apk` and `TinigSenyas-Android-armv7.apk` (per-ABI, so each stays well under the universal build's size).
- **macOS Runner (unmac)**: Compiles `TinigSenyas-iOS.ipa` and `TinigSenyas-iOS-Simulator.zip`.
- **Unified Release Publisher**: Combines both platforms into a single GitHub Release.

> The CI-built APK is signed with Flutter's **debug key** until you add a real keystore. To produce a Play-ready or upgrade-stable build, create `frontend/android/key.properties` (gitignored) pointing at a `.jks` keystore - `app/build.gradle.kts` picks it up automatically and falls back to debug when it is absent.

### Unified Download Page:
A device-detecting download portal is available at `docs/index.html`. When opened on any smartphone:
- **Android phones:** Automatically detects Android and highlights the APK download.
- **iPhones:** Automatically detects iOS and provides the IPA + Sideloadly / Web Simulator links.
- **Desktop:** Allows testers to toggle between Android and iOS.


