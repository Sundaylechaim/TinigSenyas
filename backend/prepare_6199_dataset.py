"""Audit and convert the four supplied TinigSenyas video archives.

The source archives are kept where the user placed them. Videos are streamed
one at a time to a temporary file, so the complete multi-gigabyte archives do
not need to be extracted to disk. Every archive member gets a row in the CSV
manifest; byte-identical duplicates share one feature file.
"""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import sys
import tempfile
import time
import zipfile
import zlib
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path, PurePosixPath

import cv2
import numpy as np


REPO_ROOT = Path(__file__).resolve().parents[1]
TRAINING_ROOT = REPO_ROOT / "tinigsenyas_training"
sys.path.insert(0, str(TRAINING_ROOT))
import convert_parallel as converter  # noqa: E402


EXPECTED_TOTAL = 6199
VIDEO_EXTENSIONS = {".mov", ".mp4", ".avi", ".mkv", ".webm"}
INPUT_SHAPE = (60, 75, 3)
ARCHIVES = (
    ("months", "Months,Days,Numbers", "conversation", 3037, 66),
    ("medical", "Medical", "medical", 888, 35),
    ("alphabet", "Alphabets", "alphabet", 1281, 28),
    ("food", "Food and Drinks", "conversation", 993, 17),
)
LABEL_ALIASES = {
    "Kulay Rosas": "Rosas",
    "Nauunawaan": "Naiintindihan",
    "Sampo": "Sampu",
    "Serbesa": "Beer",
    "\ufffd": "Ñ",
}
MANIFEST_FIELDS = (
    "archive",
    "member",
    "head",
    "source_label",
    "label",
    "source_id",
    "crc32",
    "bytes",
    "duplicate_of",
    "status",
    "feature_path",
    "detail",
)


def resolve_archives(archives_dir: Path, explicit: list[Path] | None) -> list[tuple[str, Path]]:
    candidates = [Path(p).resolve() for p in explicit] if explicit else list(archives_dir.glob("*.zip"))
    selected: list[tuple[str, Path]] = []
    for key, token, _, _, _ in ARCHIVES:
        matches = [path for path in candidates if token.casefold() in path.name.casefold()]
        if len(matches) != 1:
            raise FileNotFoundError(
                f"Expected one ZIP matching '{token}' in {archives_dir}; found {len(matches)}."
            )
        selected.append((key, matches[0]))
    return selected


def canonical_label(label: str) -> str:
    return LABEL_ALIASES.get(label, label)


def _archive_records(archives: list[tuple[str, Path]]) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for (key, token, head, expected_videos, expected_classes), (archive_key, path) in zip(
        ARCHIVES, archives
    ):
        if key != archive_key:
            raise ValueError(f"Archive order mismatch for {path.name}.")
        counts: Counter[str] = Counter()
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                member_path = PurePosixPath(info.filename)
                if info.is_dir() or member_path.suffix.casefold() not in VIDEO_EXTENSIONS:
                    continue
                if len(member_path.parts) < 2:
                    raise ValueError(f"Video has no class directory: {info.filename}")
                source_label = member_path.parent.name
                label = canonical_label(source_label)
                counts[source_label] += 1
                crc = f"{info.CRC:08x}"
                source_id = f"{crc}-{info.file_size}"
                records.append(
                    {
                        "archive": path.name,
                        "archive_path": str(path),
                        "member": info.filename,
                        "head": head,
                        "source_label": source_label,
                        "label": label,
                        "source_id": source_id,
                        "crc32": crc,
                        "bytes": info.file_size,
                        "zip_key": (info.CRC, info.file_size),
                        "status": "pending",
                        "feature_path": "",
                        "duplicate_of": "",
                        "detail": "",
                    }
                )
        if sum(counts.values()) != expected_videos or len(counts) != expected_classes:
            raise ValueError(
                f"{path.name}: expected {expected_videos} videos / {expected_classes} classes; "
                f"found {sum(counts.values())} / {len(counts)}."
            )
    if len(records) != EXPECTED_TOTAL:
        raise ValueError(f"Expected {EXPECTED_TOTAL} video entries; found {len(records)}.")
    return records


def _is_valid_feature(path: Path, shape: tuple[int, ...]) -> bool:
    try:
        data = np.load(path, mmap_mode="r", allow_pickle=False)
        return data.shape == shape and bool(np.isfinite(data).all())
    except Exception:
        return False


def _existing_phrase_features(raw_dir: Path, dataset_dir: Path):
    """Map original video bytes to already converted, class-aligned features."""
    found: dict[tuple[int, int], list[tuple[str, Path]]] = defaultdict(list)
    video_count = 0
    for video in sorted(raw_dir.rglob("*")):
        if not video.is_file() or video.suffix.casefold() not in VIDEO_EXTENSIONS:
            continue
        video_count += 1
        crc = 0
        with video.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                crc = zlib.crc32(block, crc)
        feature = dataset_dir / video.parent.name / f"{video.stem}.npy"
        if _is_valid_feature(feature, INPUT_SHAPE):
            found[(crc & 0xFFFFFFFF, video.stat().st_size)].append(
                (canonical_label(video.parent.name), feature)
            )
    return found, video_count


def _feature_output(output_dir: Path, record: dict[str, object], conflict: bool = False) -> Path:
    source_id = str(record["source_id"])
    if conflict:
        return output_dir / "features" / "quarantine" / f"{source_id}.npy"
    head = str(record["head"])
    label = str(record["label"])
    return output_dir / "features" / head / label / f"{source_id}.npy"


def _relative_path(path: Path, base: Path) -> str:
    return Path(os.path.relpath(path, base)).as_posix()


def build_manifest(
    records: list[dict[str, object]],
    output_dir: Path,
    raw_dir: Path,
    existing_dataset_dir: Path,
) -> tuple[list[dict[str, object]], dict[str, int]]:
    groups: dict[tuple[int, int], list[dict[str, object]]] = defaultdict(list)
    for record in records:
        groups[record["zip_key"]].append(record)

    existing, raw_count = _existing_phrase_features(raw_dir, existing_dataset_dir)
    duplicate_groups = 0
    duplicate_extra = 0
    conflicts = 0
    reused = 0

    for group in groups.values():
        labels = {(r["head"], r["label"]) for r in group}
        is_conflict = len(labels) > 1
        if len(group) > 1:
            duplicate_groups += 1
            duplicate_extra += len(group) - 1

        group.sort(key=lambda row: (str(row["archive"]), str(row["member"])))
        first = group[0]
        output_path = _feature_output(output_dir, first, conflict=is_conflict)
        chosen_existing: Path | None = None

        if is_conflict:
            conflicts += 1
            for row in group:
                row["status"] = "quarantined_label_conflict"
                row["detail"] = "Identical video bytes appear under different labels; excluded from training pending label review."
                row["feature_path"] = _relative_path(output_path, output_dir)
                if row is not first:
                    row["duplicate_of"] = str(first["member"])
            continue

        head, label = next(iter(labels))
        if head == "conversation":
            choices = existing.get(first["zip_key"], [])
            matching = [path for existing_label, path in choices if existing_label == label]
            other_labels = {existing_label for existing_label, _ in choices}
            if len(other_labels) > 1:
                for row in group:
                    row["status"] = "quarantined_local_label_conflict"
                    row["detail"] = f"Existing raw video hash is assigned to multiple labels: {sorted(other_labels)}."
                    row["feature_path"] = _relative_path(output_path, output_dir)
                continue
            if matching:
                chosen_existing = sorted(matching, key=lambda p: str(p))[0]

        if chosen_existing is not None:
            first["status"] = "reused_existing"
            first["feature_path"] = _relative_path(chosen_existing, output_dir)
            first["detail"] = "Reused the shape-checked prepared feature for identical source video bytes."
            reused += 1
        else:
            first["feature_path"] = _relative_path(output_path, output_dir)
            if output_path.exists() and _is_valid_feature(
                output_path, (63,) if head == "alphabet" else INPUT_SHAPE
            ):
                first["status"] = "already_converted"
            else:
                first["status"] = "pending"

        for row in group[1:]:
            row["status"] = "duplicate_source"
            row["feature_path"] = first["feature_path"]
            row["duplicate_of"] = str(first["member"])
            row["detail"] = "Byte-identical duplicate; shares one processed feature."

    stats = {
        "archive_entries": len(records),
        "unique_contents": len(groups),
        "duplicate_groups": duplicate_groups,
        "duplicate_extra_entries": duplicate_extra,
        "cross_label_conflict_groups": conflicts,
        "reused_existing_unique_features": reused,
        "local_raw_video_files": raw_count,
    }
    return records, stats


def _write_manifest(path: Path, records: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="", encoding="utf-8-sig") as stream:
        writer = csv.DictWriter(stream, fieldnames=MANIFEST_FIELDS, extrasaction="ignore")
        writer.writeheader()
        for row in records:
            writer.writerow(row)
    temporary.replace(path)


def _worker_initialize(hand_model: str, pose_model: str) -> None:
    converter.init_worker(hand_model, pose_model)


def _canonical_alphabet_vector(points: np.ndarray) -> np.ndarray | None:
    if points.shape != (21, 3) or not np.isfinite(points).all():
        return None
    centered = points - points[0:1]
    if points[5, 0] < points[17, 0]:
        centered[:, 0] *= -1.0
    max_dist = float(np.max(np.linalg.norm(centered, axis=1)))
    if max_dist < 1e-4:
        return None
    vector = (centered / max_dist).reshape(63).astype(np.float32)
    return vector if np.isfinite(vector).all() else None


def _extract_alphabet_feature(video_path: str, stride: int) -> tuple[np.ndarray | None, str]:
    detector = converter._worker_hand_detector
    capture = cv2.VideoCapture(video_path)
    if not capture.isOpened():
        return None, "Cannot open video."

    best: tuple[float, np.ndarray] | None = None
    frame_index = 0
    checked = 0
    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                break
            frame_index += 1
            if stride > 1 and frame_index % stride:
                continue
            checked += 1
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            image = converter.mp.Image(image_format=converter.mp.ImageFormat.SRGB, data=rgb)
            result = detector.detect(image)
            if not result.hand_landmarks:
                continue
            handedness = result.handedness or []
            for index, landmarks in enumerate(result.hand_landmarks):
                points = np.asarray([[point.x, point.y, point.z] for point in landmarks], dtype=np.float32)
                vector = _canonical_alphabet_vector(points)
                if vector is None:
                    continue
                score = 0.0
                if index < len(handedness) and handedness[index]:
                    score = float(handedness[index][0].score)
                # Prefer the most confident frame, matching the app's static
                # 63-coordinate alphabet input while avoiding low-quality frames.
                if best is None or score > best[0]:
                    best = (score, vector)
    finally:
        capture.release()

    if best is None:
        return None, f"No usable hand landmarks in {checked} sampled frames."
    return best[1], f"Selected highest-confidence hand from {checked} sampled frames (score={best[0]:.3f})."


def _process_member(task: tuple[str, str, str, str, int, str]) -> tuple[str, str, str, str]:
    archive_path, member, output_path, head, stride, source_id = task
    suffix = PurePosixPath(member).suffix or ".mp4"
    descriptor, temporary_video = tempfile.mkstemp(prefix="tinigsenyas_", suffix=suffix)
    os.close(descriptor)
    try:
        with zipfile.ZipFile(archive_path) as archive, archive.open(member) as source, open(temporary_video, "wb") as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)

        if head == "alphabet":
            feature, detail = _extract_alphabet_feature(temporary_video, stride)
            if feature is None:
                return "FAILED_ALPHABET", output_path, detail, source_id
            Path(output_path).parent.mkdir(parents=True, exist_ok=True)
            np.save(output_path, feature)
            return "CONVERTED", output_path, detail, source_id

        status, _, detail = converter.process_single_video(
            (temporary_video, output_path, True, stride)
        )
        if status != "SAVED":
            return status, output_path, str(detail), source_id
        feature = np.load(output_path, allow_pickle=False)
        if feature.shape != INPUT_SHAPE or not np.isfinite(feature).all():
            Path(output_path).unlink(missing_ok=True)
            return "FAILED_INVALID_FEATURE", output_path, f"Bad feature shape or values: {feature.shape}", source_id
        active_hand_frames = int(np.count_nonzero(np.any(np.abs(feature[:, 33:75, :]) > 1e-6, axis=(1, 2))))
        if active_hand_frames < 3:
            Path(output_path).unlink(missing_ok=True)
            return "FAILED_NO_HANDS", output_path, f"Only {active_hand_frames} resampled frames contain hand landmarks.", source_id
        return "CONVERTED", output_path, f"Valid {INPUT_SHAPE}; hand landmarks present in {active_hand_frames}/60 frames.", source_id
    except Exception as exc:
        return "FAILED_EXCEPTION", output_path, f"{type(exc).__name__}: {exc}", source_id
    finally:
        try:
            os.remove(temporary_video)
        except OSError:
            pass


def process_pending(
    records: list[dict[str, object]],
    output_dir: Path,
    workers: int,
    stride: int,
    hand_model: Path,
    pose_model: Path,
    manifest_path: Path,
) -> Counter[str]:
    by_id: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in records:
        if row["status"] in {"pending", "quarantined_label_conflict", "quarantined_local_label_conflict"}:
            by_id[str(row["source_id"])].append(row)

    tasks: list[tuple[str, str, str, str, int, str]] = []
    for group in by_id.values():
        first = group[0]
        relative = str(first["feature_path"])
        output_path = (output_dir / Path(relative)).resolve()
        expected_shape = (63,) if first["head"] == "alphabet" else INPUT_SHAPE
        if output_path.exists() and _is_valid_feature(output_path, expected_shape):
            for row in group:
                row["status"] = "quarantined_label_conflict" if str(row["status"]).startswith("quarantined") else "already_converted"
            continue
        if output_path.exists():
            output_path.unlink()
        tasks.append(
            (
                str(first["archive_path"]),
                str(first["member"]),
                str(output_path),
                str(first["head"]),
                stride,
                str(first["source_id"]),
            )
        )

    if not tasks:
        return Counter()

    statuses: Counter[str] = Counter()
    start = time.time()
    print(f"Converting {len(tasks)} unique videos with {workers} workers; stride={stride}.", flush=True)
    with ProcessPoolExecutor(
        max_workers=workers,
        initializer=_worker_initialize,
        initargs=(str(hand_model), str(pose_model)),
    ) as pool:
        future_to_task = {pool.submit(_process_member, task): task for task in tasks}
        for completed, future in enumerate(as_completed(future_to_task), 1):
            task = future_to_task[future]
            try:
                status, output_path, detail, source_id = future.result()
            except Exception as exc:
                status, output_path, detail, source_id = (
                    "FAILED_WORKER",
                    task[2],
                    f"{type(exc).__name__}: {exc}",
                    task[5],
                )
            statuses[status] += 1
            group = by_id[source_id]
            for row in group:
                row["status"] = (
                    "quarantined_label_conflict"
                    if str(row["status"]).startswith("quarantined")
                    else status.lower()
                )
                row["feature_path"] = _relative_path(Path(output_path), output_dir)
                row["detail"] = detail
            if completed % 50 == 0 or completed == len(tasks):
                _write_manifest(manifest_path, records)
                elapsed = time.time() - start
                print(
                    f"Processed {completed}/{len(tasks)} unique clips; "
                    f"{dict(statuses)}; elapsed={elapsed / 60:.1f} min.",
                    flush=True,
                )
    return statuses


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archives-dir", type=Path, default=Path.home() / "Downloads")
    parser.add_argument("--archives", nargs="+", type=Path)
    parser.add_argument("--output-dir", type=Path, default=REPO_ROOT / "backend" / "processed_6199")
    parser.add_argument("--raw-videos", type=Path, default=REPO_ROOT / "raw_videos")
    parser.add_argument("--existing-datasets", type=Path, default=TRAINING_ROOT / "datasets")
    parser.add_argument("--hand-model", type=Path, default=TRAINING_ROOT / "hand_landmarker.task")
    parser.add_argument("--pose-model", type=Path, default=TRAINING_ROOT / "pose_landmarker_lite.task")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--stride", type=int, default=2)
    parser.add_argument("--process", action="store_true", help="Convert pending unique clips into features.")
    parser.add_argument("--verify-archives", action="store_true", help="Read every ZIP member and verify CRCs before conversion.")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    selected = resolve_archives(args.archives_dir.resolve(), args.archives)
    if args.verify_archives:
        for key, path in selected:
            print(f"Verifying ZIP contents: {path.name}", flush=True)
            with zipfile.ZipFile(path) as archive:
                bad_member = archive.testzip()
            if bad_member:
                raise ValueError(f"ZIP CRC failure in {path.name}: {bad_member}")
            print(f"ZIP CRC verified: {path.name}", flush=True)

    records = _archive_records(selected)
    records, stats = build_manifest(records, output_dir, args.raw_videos.resolve(), args.existing_datasets.resolve())
    manifest_path = output_dir / "manifest.csv"
    _write_manifest(manifest_path, records)

    print("DATASET AUDIT", flush=True)
    for key, value in stats.items():
        print(f"{key}: {value}", flush=True)
    by_head = Counter(str(row["head"]) for row in records)
    by_label = Counter((str(row["head"]), str(row["label"])) for row in records)
    print(f"entries_by_head: {dict(by_head)}", flush=True)
    print(f"unique_classes_by_head: {dict(Counter(head for head, _ in by_label))}", flush=True)
    print(f"manifest: {manifest_path}", flush=True)

    if args.process:
        if not args.hand_model.is_file() or not args.pose_model.is_file():
            raise FileNotFoundError("MediaPipe hand/pose model task files were not found.")
        if args.workers < 1 or args.stride < 1:
            raise ValueError("--workers and --stride must both be positive.")
        statuses = process_pending(
            records,
            output_dir,
            args.workers,
            args.stride,
            args.hand_model.resolve(),
            args.pose_model.resolve(),
            manifest_path,
        )
        _write_manifest(manifest_path, records)
        print(f"conversion_statuses: {dict(statuses)}", flush=True)

    final_statuses = Counter(str(row["status"]) for row in records)
    print(f"manifest_statuses: {dict(final_statuses)}", flush=True)


if __name__ == "__main__":
    main()
