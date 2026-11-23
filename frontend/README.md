# TinigSenyas Flutter App

The mobile client provides offline FSL recognition from the model bundle in
`assets/model`, speech-to-text, text-to-speech, history, settings, and sign
animation assets. The supported runtime is Android. The web build is not
supported because the on-device inference packages require `dart:ffi`.

## Run on Android

From this directory:

```powershell
flutter pub get
flutter devices
flutter run -d DEVICE_ID
```

Replace `DEVICE_ID` with an Android device or emulator ID returned by `flutter devices`.
The release builder writes the single Android APK to
`build/app/outputs/flutter-apk/app-release.apk`.

The FastAPI backend is optional for offline sign recognition. To run backend
features, follow [the backend setup guide](../backend/README.md) and configure
its environment using `../backend/.env.example`. Keep real tokens in the
backend environment; never put them in the mobile app or commit them.
