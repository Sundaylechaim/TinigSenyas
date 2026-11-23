"""Create model-specific feature indexes from the 6,199-entry manifest."""

from __future__ import annotations

import argparse
import csv
import json
import zlib
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PROCESSING_DIR = REPO_ROOT / "backend" / "processed_6199"
TRAINING_ROOT = REPO_ROOT / "tinigsenyas_training"
EXPECTED_ARCHIVE_ENTRIES = 6199
VIDEO_EXTENSIONS = {".mov", ".mp4", ".avi", ".mkv", ".webm"}
SEQUENCE_SHAPE = (60, 75, 3)
ALPHABET_SHAPE = (63,)
ALLOWED_FEATURE_STATUSES = {"reused_existing", "converted", "already_converted"}


def _is_no_hand_alphabet_clip(row: dict[str, str]) -> bool:
    """Permit an explicitly unusable alphabet recording to be reported and excluded."""
    return (
        row.get("head") == "alphabet"
        and row.get("status") == "failed_alphabet"
        and "No usable hand landmarks" in row.get("detail", "")
    )


def _load_labels(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _valid_feature(path: Path, shape: tuple[int, ...]) -> bool:
    try:
        feature = np.load(path, mmap_mode="r", allow_pickle=False)
        return feature.shape == shape and bool(np.isfinite(feature).all())
    except Exception:
        return False


def _feature_path(processing_dir: Path, relative_path: str) -> Path:
    return (processing_dir / Path(relative_path)).resolve()


def _crc_key(path: Path) -> tuple[int, int]:
    crc = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            crc = zlib.crc32(block, crc)
    return crc & 0xFFFFFFFF, path.stat().st_size


def _write_model_data(
    model_name: str,
    records: list[dict[str, str]],
    labels: list[str],
    output_root: Path,
    processing_dir: Path,
    feature_shape: tuple[int, ...],
) -> dict[str, object]:
    label_set = set(labels)
    class_counts: Counter[str] = Counter()
    seen_ids: set[str] = set()
    data_root = output_root / model_name
    data_root.mkdir(parents=True, exist_ok=True)
    feature_references: list[dict[str, str]] = []

    if model_name == "conversation":
        # Start from the complete existing 103-class feature set, but collapse
        # byte-identical videos and quarantine any local duplicate assigned to
        # more than one sign label.
        local_groups: dict[tuple[int, int], list[tuple[str, Path, str]]] = defaultdict(list)
        for video in sorted((REPO_ROOT / "raw_videos").rglob("*")):
            if not video.is_file() or video.suffix.casefold() not in VIDEO_EXTENSIONS:
                continue
            label = video.parent.name
            feature = TRAINING_ROOT / "datasets" / label / f"{video.stem}.npy"
            if not _valid_feature(feature, feature_shape):
                continue
            local_groups[_crc_key(video)].append((label, feature, video.name))

        local_conflict_groups = 0
        legacy_features = 0
        for (crc, size), items in local_groups.items():
            item_labels = {item[0] for item in items}
            if len(item_labels) > 1:
                local_conflict_groups += 1
                continue
            label, feature, _ = sorted(items, key=lambda item: str(item[1]))[0]
            if label not in label_set:
                raise ValueError(f"Existing class is absent from app labels: {label}")
            source_id = f"{crc:08x}-{size}"
            feature_references.append({
                "label": label,
                "source_id": source_id,
                "feature_path": str(feature.resolve()),
            })
            class_counts[label] += 1
            seen_ids.add(source_id)
            legacy_features += 1
    else:
        local_conflict_groups = 0
        legacy_features = 0

    included = 0
    skipped_conflicts = 0
    skipped_unusable = 0
    for row in records:
        if row["head"] != model_name:
            continue
        if row["status"] not in ALLOWED_FEATURE_STATUSES:
            if _is_no_hand_alphabet_clip(row):
                skipped_unusable += 1
                continue
            if row["status"].startswith("quarantined"):
                skipped_conflicts += 1
                continue
            if row["status"] == "duplicate_source":
                continue
            raise ValueError(
                f"Unprocessed source entry remains: {row['archive']} :: {row['member']} ({row['status']})"
            )

        label = row["label"]
        if label not in label_set:
            raise ValueError(f"Source label '{label}' is not in the {model_name} app labels.")
        if row["source_id"] in seen_ids:
            continue

        source = _feature_path(processing_dir, row["feature_path"])
        if not _valid_feature(source, feature_shape):
            raise ValueError(f"Missing or invalid feature for {row['archive']} :: {row['member']}: {source}")
        feature_references.append({
            "label": label,
            "source_id": row["source_id"],
            "feature_path": str(source),
        })
        seen_ids.add(row["source_id"])
        class_counts[label] += 1
        included += 1

    missing = sorted(label_set - set(class_counts))
    if missing:
        raise ValueError(f"{model_name} model has classes with no training samples: {missing}")
    small = {label: count for label, count in class_counts.items() if count < 2}
    if small:
        raise ValueError(f"{model_name} classes need at least 2 samples: {small}")

    index_path = data_root / "features.csv"
    with index_path.open("w", newline="", encoding="utf-8-sig") as stream:
        writer = csv.DictWriter(stream, fieldnames=("label", "source_id", "feature_path"))
        writer.writeheader()
        writer.writerows(feature_references)
    (data_root / "labels.txt").write_text("\n".join(labels) + "\n", encoding="utf-8")

    return {
        "classes": len(labels),
        "samples": int(sum(class_counts.values())),
        "legacy_features": legacy_features,
        "new_archive_features": included,
        "quarantined_source_rows": skipped_conflicts,
        "unusable_source_rows_excluded": skipped_unusable,
        "local_conflict_groups_excluded": local_conflict_groups,
        "feature_index": str(index_path),
        "per_class": dict(sorted(class_counts.items())),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--processing-dir", type=Path, default=DEFAULT_PROCESSING_DIR)
    parser.add_argument("--output-root", type=Path)
    args = parser.parse_args()

    processing_dir = args.processing_dir.resolve()
    output_root = (args.output_root or processing_dir / "training_sets").resolve()
    manifest_path = processing_dir / "manifest.csv"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"Dataset manifest not found: {manifest_path}")
    with manifest_path.open(encoding="utf-8-sig", newline="") as stream:
        records = list(csv.DictReader(stream))
    if len(records) != EXPECTED_ARCHIVE_ENTRIES:
        raise ValueError(f"Expected {EXPECTED_ARCHIVE_ENTRIES} manifest rows; found {len(records)}.")
    for row in records:
        status = row["status"]
        if status == "pending" or (status.startswith("failed") and not _is_no_hand_alphabet_clip(row)):
            raise ValueError(f"Source video is not fully processed: {row['archive']} :: {row['member']} ({status})")
        if not row["feature_path"]:
            raise ValueError(f"Source video has no processed feature mapping: {row['archive']} :: {row['member']}")
        if _is_no_hand_alphabet_clip(row):
            continue
        shape = ALPHABET_SHAPE if row["head"] == "alphabet" else SEQUENCE_SHAPE
        mapped_feature = _feature_path(processing_dir, row["feature_path"])
        if not _valid_feature(mapped_feature, shape):
            raise ValueError(f"Mapped source feature is missing or invalid: {row['archive']} :: {row['member']} -> {mapped_feature}")

    conversation_labels = _load_labels(REPO_ROOT / "frontend" / "assets" / "model" / "labels.txt")
    old_medical_labels = _load_labels(REPO_ROOT / "frontend" / "assets" / "model" / "medical_labels.txt")
    alphabet_labels = _load_labels(REPO_ROOT / "frontend" / "assets" / "model" / "alphabet_labels.txt")
    if (len(conversation_labels), len(old_medical_labels), len(alphabet_labels)) != (103, 25, 28):
        raise ValueError("Current app label counts changed; re-audit the model heads before building data.")
    medical_source_labels = sorted({row["label"] for row in records if row["head"] == "medical"})
    medical_source_set = set(medical_source_labels)
    # Keep the established model order for labels that still exist, then append
    # the new source vocabulary in a stable alphabetical order. Placeholder
    # labels from the old 25-class model are deliberately dropped.
    medical_labels = [label for label in old_medical_labels if label in medical_source_set]
    medical_labels.extend(label for label in medical_source_labels if label not in set(medical_labels))
    if len(medical_labels) != 35:
        raise ValueError(f"Expected 35 medical source classes; found {len(medical_labels)}.")

    output_root.mkdir(parents=True, exist_ok=True)
    report = {
        "source_archive_entries": len(records),
        "source_unique_contents": len({row["source_id"] for row in records}),
        "source_statuses": dict(Counter(row["status"] for row in records)),
        "conversation": _write_model_data(
            "conversation", records, conversation_labels, output_root, processing_dir, SEQUENCE_SHAPE
        ),
        "medical": _write_model_data(
            "medical", records, medical_labels, output_root, processing_dir, SEQUENCE_SHAPE
        ),
        "alphabet": _write_model_data(
            "alphabet", records, alphabet_labels, output_root, processing_dir, ALPHABET_SHAPE
        ),
    }
    report["medical"]["label_order"] = medical_labels
    report_path = output_root / "dataset_counts.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "source_archive_entries": report["source_archive_entries"],
        "source_unique_contents": report["source_unique_contents"],
        "source_statuses": report["source_statuses"],
        "conversation": {k: report["conversation"][k] for k in ("classes", "samples", "legacy_features", "new_archive_features", "local_conflict_groups_excluded")},
        "medical": {k: report["medical"][k] for k in ("classes", "samples", "new_archive_features")},
        "alphabet": {k: report["alphabet"][k] for k in ("classes", "samples", "new_archive_features", "unusable_source_rows_excluded")},
        "report": str(report_path),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
