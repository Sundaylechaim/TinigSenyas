# Training with the 6,199-video source set

The four user-supplied archives contain exactly 6,199 video entries:

| Source | Entries | Classes | Model head |
| --- | ---: | ---: | --- |
| Months, days, numbers | 3,037 | 66 | Conversation (103 classes) |
| Medical | 888 | 35 | Medical (candidate expands from 25 to 35 classes) |
| Alphabets | 1,281 | 28 | Alphabet (28 classes) |
| Food and drinks | 993 | 17 | Conversation (103 classes) |

The archive audit found 6,182 unique byte contents and 17 duplicate entries
(15 same-label copies and two cross-label conflict groups). Four archive rows
in those conflict groups, plus two rows that match local videos assigned to
multiple labels, remain quarantined and are excluded from training. The
processing step reuses 1,322 shape-checked local features and processes the
remaining 4,860 unique clips. One alphabet clip has no visible hands in any
of its 19 frames, even at stride 1, so it is recorded as unusable and excluded
instead of receiving a fabricated feature. Thus every one of the 6,199 archive
rows is accounted for; 6,198 map to usable or quarantined features, and one is
explicitly marked unusable.

## Commands

Run these from the repository root after the four ZIP files are in Downloads:

```powershell
.\backend\.venv\Scripts\python.exe .\backend\prepare_6199_dataset.py `
  --archives-dir "$env:USERPROFILE\Downloads" `
  --output-dir .\backend\processed_6199 `
  --verify-archives --process --workers 4 --stride 2

.\backend\.venv\Scripts\python.exe .\backend\build_6199_training_sets.py

.\backend\.training-venv\Scripts\python.exe .\backend\train_6199_candidates.py
```

`backend/processed_6199/manifest.csv` contains one row for every source video,
including duplicate, reused, converted, quarantined, and unusable statuses.
The training-set builder writes small `features.csv` indexes that point to the
validated `.npy` features; it does not copy the arrays again. The derived
features and model candidates are ignored by Git because they are local
training artifacts.

## Candidate model scope

- The 103-class conversation candidate fine-tunes the connected ST-GCN from
  `tinigsenyas_training/best_fsl_model.keras`, using the existing 103-class
  examples plus the new month/day/number and food samples.
- The 35-class medical candidate transfers the connected ST-GCN backbone from
  that checkpoint and initializes a 35-class output head. The existing app
  now expects 35 medical labels in the local pilot build, with the matching
  model and labels bundled together.
- The alphabet candidate uses the existing app's 63-coordinate hand input and
  28-label order. No Keras checkpoint for the shipped alphabet model is in the
  repository, so it is trained from the supplied videos.

Training outputs go to `backend/models/6199_candidate/`. These are local
candidates only; the scripts do not replace app assets or publish OTA updates.
The current source archives do not identify signer IDs, so validation splits
are sample-level and must not be treated as signer-independent Deaf-user
accuracy.

## Run results

The completed local candidates use these held-out sample-level measurements:

| Head | Training samples / classes | Validation samples | Candidate top-1 | Current app baseline |
| --- | ---: | ---: | ---: | ---: |
| Conversation ST-GCN | 4,782 / 103 | 957 | 86.3% | 45.7% |
| Medical ST-GCN | 888 / 35 | 178 | 96.6% | 14.5% on 83 shared-label samples |
| Alphabet landmarks | 1,267 / 28 | 254 | 82.3% | 78.7% |

These measurements come from a sample-level split and can be optimistic when
the same signer appears in both partitions. They do not establish continuous
phrase translation quality or readiness for Deaf-user testing. The medical
baseline figures refer to the prior 25-class app model and its 83 shared-label
samples; the pilot bundle uses the 35-class candidate instead.

## Local pilot integration

The candidate TFLite files and their matching label files are bundled under
`frontend/assets/model/`. The app's medical output contract is set to 35
classes. The bundled model version is `1.3.0`; the Android app version is
`1.0.0+2019`. The local manifest lists all six model/label files and their
SHA-256 checksums, so a later OTA can update the models and label orders as one
verified set.

No OTA files have been published. The remote GitHub manifest must be updated
with these exact files and hashes at the same time as a future authorized OTA
release. Validate recognition with Deaf FSL users before treating these
candidates as production-ready.
