# TinigSenyas v1.0.0 architecture

## Release identities

- App release: `1.0.0+2019` (`frontend/pubspec.yaml`, mirrored by
  `frontend/lib/config/app_version.dart`). Increase the build number on every
  Android/iOS binary release.
- Recognition bundle: `1.3.0` (`frontend/assets/model/version.txt`). This is a
  separate version stream because model weights and app code can ship at
  different times.
- Legacy OTA compatibility: `min_app_version=1.2.16` remains for previously
  installed clients. New clients also check `min_app_build=2019`; this avoids
  treating an older `1.2.x` binary as compatible merely because its version
  name compares higher than `1.0.0`.
- API contract: FastAPI advertises `1.0.0`; it is the API's version, not the
  mobile app or model version.
- Shorebird baseline: Android release `1.0.0+2019` embeds the Shorebird runtime.
  Existing plain-Flutter installs need this APK once before receiving Dart-only
  code patches; model/label updates continue through the separate model updater.

## Runtime flow

```text
Flutter screens
  ├─ Sign to Text ─ RecognitionProvider ─ TFLite phrase / medical / alphabet models
  │                  ├─ DatabaseHelper: conversation history (SQLite)
  │                  └─ WordPredictionService: bundled lexicon + SQLite vocabulary cache
  │                       └─ VocabularySyncService ─ GET /api/v1/ota/vocabulary
  ├─ Text to Sign ─ bundled label list + sign animation catalog ─ TTS service
  ├─ Speech to Text ─ device speech recognizer ─ conversation history / TTS
  └─ Settings ─ SettingsService ─ app/model status, backend URL, TTS preferences

ModelUpdater ─ HTTPS manifest ─ checks version, app compatibility, file names,
                and SHA-256 for all three models and all three label files
             ─ stages downloads, verifies hashes, then installs the complete set

FastAPI (optional)
  ├─ /api/v1/ota/manifest and /api/v1/ota/vocabulary
  ├─ /api/v1/predict/* -> SignClassifier -> canonical app model bundle + labels
  │                                  └─ MediaPipe detector tasks in backend/models
  ├─ /api/v1/hands/* for configured backend hand tracking
  ├─ /tts/* for remote speech synthesis
  └─ /api/v1/dmca/* for token-protected administration
```

## Storage and authentication boundaries

- SQLite is local to each device. Schema v1 conversation rows are preserved by
  the v1-to-v2 migration; the new `vocabulary` table is an offline cache.
- Vocabulary sync is optional. It uses the configured backend URL, runs
  asynchronously when Sign to Text opens, and never blocks camera recognition.
  Invalid or unavailable responses leave the existing cache intact.
- The app has no end-user account system. This is intentional for the offline
  pilot. Remote TTS requires the configured bearer token; DMCA administration
  requires `ADMIN_API_TOKEN`. Keep the optional camera/prediction backend on a
  trusted network because those endpoints are not user-account authenticated.
- Core sign recognition and text-to-sign previews use bundled/local assets; a
  missing backend does not disable them.
- The optional backend classifier reads the same model and label files as the
  app. `FSL_MODEL_DIR` can point to that bundle when the backend is deployed
  separately; duplicate `.npy` training artifacts in `backend/models` are not
  used by live inference.

## Validation boundary

The model bundle is a local pilot candidate. Sample-level validation results
do not establish signer-independent or Deaf-user phrase accuracy. Treat model
quality as a separate validation gate from app/API version compatibility.
