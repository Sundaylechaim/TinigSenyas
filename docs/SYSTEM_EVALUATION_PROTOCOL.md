# TinigSenyas System Evaluation Protocol

## Status

This document prepares the technical and usability evaluation. It is not a
report of completed participant testing. Final performance and SUS results must
be collected on the supported Android phones with Deaf FSL users and hearing
community participants before the system is described as validated.

## Scope and known boundaries

- The mobile camera pipeline runs MediaPipe landmark tracking and TFLite
  inference on the phone. The phrase and medical models classify one isolated
  sign per recognition window; they do not translate unrestricted continuous
  FSL sentences.
- The model validation scores in `backend/TRAINING_6199.md` use sample-level
  partitions because the source archives do not identify signer IDs. They are
  exploratory and cannot substitute for signer-independent or user testing.
- Mobile speech recognition requests the OS on-device Filipino/Tagalog locale.
  It works offline only when the device exposes a compatible downloaded speech
  pack. The app does not package its own Filipino ASR weights.
- Filipino TTS uses an installed device voice or the configured online service.
  The optional downloaded Sherpa-ONNX voice is English-only.

## A. Technical quality: selected ISO/IEC 25010 characteristics

Record app version, model version, phone model, Android version, test date,
network state, lighting, camera distance, and whether the Filipino speech pack
was installed. Keep identifiable video/audio out of the evaluation dataset
unless separate informed consent and approved storage are in place.

| Characteristic | Procedure | Evidence to report |
| --- | --- | --- |
| Functional suitability | Complete each supported flow: camera sign recognition in phrase, medical, and alphabet modes; manual correction; speech transcription; speech output; history; offline startup; model update; vocabulary sync. Include permission denial, missing language pack, corrupt manifest, checksum mismatch, and server-unavailable cases. | Task completion, wrong/missing outputs, rejected predictions, model/label load status, update rollback behavior. |
| Performance efficiency | On each target phone, record cold start, landmark time, inference time, end-to-end time from sign completion to displayed label, sustained camera frame rate, peak memory, and battery/thermal behavior during a fixed session. Report median and p95, with the measurement method. | Raw device-level measurements and median/p95 summaries; do not infer mobile latency from desktop tests. |
| Security | Verify admin requests fail without a token and with a wrong token; verify a valid request publishes only a schema-valid bounded dataset; confirm production traffic uses HTTPS, the admin token is absent from the APK, model files are hash-checked before install, and transcription in mobile on-device mode does not use the backend. | HTTP status/results, deployment TLS configuration, package secret scan, manifest/hash results, and privacy-path checks. |

Set acceptance thresholds before running the study and preserve failed runs in
the report. Existing automated tests demonstrate software contracts; they do
not establish target-device performance or recognition quality.

## B. Human-centered usability: System Usability Scale

1. Recruit and report participant roles separately (Deaf FSL signer, hearing
   user, or other role); obtain informed consent and provide the app in the
   participant's preferred accessible language.
2. Ask each participant to complete the same short tasks: start a sign session,
   communicate a supported isolated sign, correct or clear an output, send a
   spoken message, hear a translated message, and recover from an unavailable
   speech pack or network connection.
3. Immediately after the tasks, administer the standard 10-item SUS instrument
   using its established wording and response scale. Use a validated Filipino
   translation where available; document the language and do not change item
   order or scoring.
4. For each response on the 1–5 scale, score odd-numbered items as response
   minus 1 and even-numbered items as 5 minus response. Sum the ten adjusted
   values and multiply by 2.5 for a SUS score from 0 to 100.
5. Report participant count, roles, language, individual scores without names,
   mean, standard deviation, score distribution, task failures, and qualitative
   accessibility feedback. A SUS score is not a percentage of users satisfied.

## Results record

Leave these values blank until measurements have actually been collected:

| Measure | Result | Dataset/device/sample notes |
| --- | --- | --- |
| Signer-independent top-1 accuracy and per-class recall | Pending | Requires signer-disjoint test videos |
| Deaf-user phrase/task success | Pending | Requires participant study |
| Camera/inference latency (median and p95) | Pending | Requires target Android devices |
| Functional suitability failure count | Pending | Complete the test matrix above |
| Security checks | Pending | Run against the deployed HTTPS backend |
| SUS mean, SD, and participant count | Pending | Requires SUS questionnaires |

Do not mark Objective 5 complete until these records and the study method have
been reviewed and attached to the project evaluation report.
