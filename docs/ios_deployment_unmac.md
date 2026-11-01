# iOS Deployment Guide (Unmac / Zero-Cost Cloud Mac Pipeline)

This guide documents how **TinigSenyas** is built and deployed to iOS devices without needing a physical Mac, an Apple Developer account ($99/year), or local Xcode installation.

Based on the [unmac guide](https://devdailydrops.pages.dev/unmac) by `@hayderdotdev`.

---

## Architecture Overview

```
Flutter Code (TinigSenyas/frontend)
         │
         ▼
GitHub Actions (macos-latest cloud runner)
         ├── 1. flutter pub get
         ├── 2. flutter build ios --release --no-codesign
         ├── 3. Package app.ipa
         ├── 4. flutter build ios --simulator --debug -> app-simulator.zip
         └── 5. Publish to GitHub Releases + AltStore source.json
         │
         ├───► Option A: Physical iPhone (Sideloadly / AltStore / SideStore)
         └───► Option B: Browser Testing (Appetize.io)
```

---

## 1. How to Trigger an iOS Build

### Method A: By pushing a Git Tag (Recommended)
Every time you tag your code with `v*` (e.g., `v1.0.0`), GitHub Actions will automatically start a macOS runner, build the `.ipa`, and upload it to GitHub Releases.

1. In `frontend/pubspec.yaml`, make sure your version is incremented (e.g. `version: 1.0.0+1`).
2. Run in terminal (from the repo root `TinigSenyas`):
   ```bash
   git add -A
   git commit -m "iOS build release v1.0.0"
   git push origin main
   git tag v1.0.0
   git push origin v1.0.0
   ```
3. Open your repository on GitHub:
   - **Watch build progress:** Go to **Actions** tab (`https://github.com/Sundaylechaim/TinigSenyas/actions`).
   - **Download files:** Go to **Releases** tab (`https://github.com/Sundaylechaim/TinigSenyas/releases/tag/v1.0.0`).

### Method B: Manual Run via GitHub Actions Web UI
1. Go to `https://github.com/Sundaylechaim/TinigSenyas/actions`.
2. Click **iOS free release** under Actions on the left.
3. Click the **Run workflow** button on the right and click the green **Run workflow**.
4. Once completed (~5 minutes), download `ios-build` from the **Artifacts** section at the bottom of the run page.

---

## 2. Output Files

Once the workflow finishes, you get:
- **`app.ipa`**: The real iOS app package for physical iPhones.
- **`app-simulator.zip`**: The simulator build for testing in web browsers.
- **`source.json`**: AltStore / SideStore repository manifest for direct in-app updating.

---

## 3. How to Install on an iPhone (Free Apple ID)

You don't need a paid Apple Developer account. You can use any free Apple ID using **Sideloadly**:

1. **Install Prerequisites (Windows PC):**
   - Install standard **iTunes** and **iCloud** directly from Apple's website (not Microsoft Store):
     - [iTunes for Windows (apple.com)](https://www.apple.com/itunes/)
     - [iCloud for Windows (apple.com)](https://support.apple.com/en-us/103232)
   - Download and install **Sideloadly** from [sideloadly.io](https://sideloadly.io).
2. **Connect your iPhone:**
   - Plug your iPhone into your PC using a USB cable.
   - On the iPhone screen, tap **Trust** when prompted and enter your passcode.
3. **Sideload the App:**
   - Open Sideloadly on your PC.
   - Drag and drop the downloaded **`app.ipa`** into the Sideloadly window.
   - Enter your Apple ID email address.
   - Click **Start** (enter your Apple ID password and 2FA code when prompted).
4. **Trust the Certificate on iPhone:**
   - Go to iPhone **Settings** > **General** > **VPN & Device Management**.
   - Tap your Apple ID email under *Developer App*.
   - Tap **Trust "[Your Email]"** and confirm.
5. **Enable Developer Mode (iOS 16+):**
   - Go to iPhone **Settings** > **Privacy & Security** > **Developer Mode**.
   - Toggle **Developer Mode** ON, then restart your iPhone.

> **Note on Free Apple IDs:** Free Apple developer certificates are valid for 7 days. After 7 days, simply re-drag `app.ipa` into Sideloadly and click Start to renew it for another week.

---

## 4. How to Test in Browser (No iPhone Needed)

If you don't have an iPhone or want to preview the app instantly:
1. Download **`app-simulator.zip`** from the GitHub Release / Artifacts.
2. Go to [appetize.io](https://appetize.io) (free tier allows interactive browser streaming).
3. Upload `app-simulator.zip`.
4. Run and interact with the iOS app directly in your browser.

