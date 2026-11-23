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

Android allows direct APK installation without store fees. The official release
contains **one signed ARM64 APK** named `TinigSenyas-Android.apk` on the GitHub
release page. It uses app version `1.0.0`, build `2019`, and includes the
Shorebird runtime required for future Dart-code patches.

The CI release builds and verifies this APK when a version tag is published.
For a local Shorebird release, open PowerShell in `TinigSenyas/frontend` and run:

```powershell
.\build_android_apk.ps1
```

This command publishes the Shorebird baseline for the version in `pubspec.yaml`
and keeps one local APK at
`frontend/build/app/outputs/flutter-apk/app-release.apk`. The Android release
keystore and Shorebird CLI authentication must be configured first. Keep the
same signing key for every binary release so Android can install updates over
the existing app.

The previous GitHub APK was built without Shorebird. Users on that build must
install this v1.0.0+2019 baseline once; later Dart-only changes can arrive as
Shorebird patches. Model updates remain separately available through the
in-app OTA model updater.

### Step 2: Upload to Google Drive
1. Create a dedicated folder in Google Drive (e.g., `TinigSenyas Releases`).
2. Upload the single `TinigSenyas-Android.apk` from the GitHub release, or the
   local `app-release.apk` if you built it yourself.
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

The app has two separate OTA paths:

### Layer 1: Model and vocabulary updates

The current model bundle is `1.3.0` and contains three TFLite models plus three
matching UTF-8 label files. The API and bundled fallback manifest list SHA-256
checksums for every file. Before publishing a retrained bundle:

1. Update all model and label files under `frontend/assets/model/`.
2. Regenerate `manifest.json` hashes from the exact files and increase the model
   version in both `manifest.json` and `version.txt`.
3. Run the backend tests. They compare API checksums with both the local
   manifest and the actual file bytes.
4. Push the verified files to `main` and deploy the backend that serves
   `/api/v1/ota/manifest`.
5. In the app, open **Settings → Check for Model Updates (OTA)**.

The current app baseline checks `min_app_build=2019`. Older app builds may not
accept this bundle; users should install the v1.0.0+2019 APK before testing this
model set. Vocabulary sync is optional and keeps a last-known SQLite cache when
the backend is unavailable.

### Layer 2: Dart app-code updates

The v1.0.0+2019 Android release is a Shorebird baseline. After users install it,
Dart-only code changes can be published using the **Shorebird OTA Patch** GitHub
workflow on the `stable` track, targeting release `1.0.0+2019`. The workflow
requires `SHOREBIRD_TOKEN` and the Android release-signing secrets.

The previous v1.2.15 APK was built with plain Flutter and cannot receive
Shorebird patches. Install the new baseline APK once to enable code patches.
Native plugin/configuration changes and changes to bundled sign-animation
assets require a new APK; model weights and labels continue to use Layer 1.
Increase the app build number for every new binary release and preserve the
release signing key so Android can upgrade in place.

---

## 5. Quick Build Scripts

`frontend/build_android_apk.ps1` runs a Shorebird release for the version in
`pubspec.yaml` and leaves one signed ARM64 APK at
`frontend/build/app/outputs/flutter-apk/app-release.apk`. It requires an
authenticated Shorebird CLI and the configured Android release keystore.

---

## 6. Unified Cloud CI/CD Release (Android + iOS Together)

Pushing a new version tag (for example, `v1.0.0+2019`) starts the GitHub
release workflow. It runs Flutter analysis/tests and backend tests before
building. Android output is one Shorebird-enabled, signed ARM64 APK named
`TinigSenyas-Android.apk`; the six-file recognition bundle and checksummed
manifest are attached to the same release. The workflow also prepares an
unsigned iOS IPA for sideloading.

GitHub Actions needs the repository secrets `SHOREBIRD_TOKEN`,
`ANDROID_RELEASE_KEYSTORE_BASE64`, `ANDROID_RELEASE_STORE_PASSWORD`,
`ANDROID_RELEASE_KEY_ALIAS`, and `ANDROID_RELEASE_KEY_PASSWORD`. The workflow
checks the APK signature against the project's release certificate before
publishing the release.

### Unified Download Page:
A device-detecting download portal is available at `docs/index.html`. When opened on any smartphone:
- **Android phones:** Automatically detects Android and highlights the APK download.
- **iPhones:** Automatically detects iOS and provides the IPA + Sideloadly / Web Simulator links.
- **Desktop:** Allows testers to toggle between Android and iOS.


