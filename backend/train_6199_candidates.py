"""Train local model candidates from the complete 6,199-video dataset.

The phrase and medical heads use the connected 75-landmark ST-GCN. The
alphabet head retains the app's 63-value, single-hand input contract. Outputs
are kept in backend/models/6199_candidate and are not wired into OTA or app
assets by this script.
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import subprocess
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import tensorflow as tf
from sklearn.model_selection import train_test_split
from sklearn.utils.class_weight import compute_class_weight
from tensorflow.keras import callbacks, layers, models


REPO_ROOT = Path(__file__).resolve().parents[1]
BACKEND_ROOT = REPO_ROOT / "backend"
TRAINING_ROOT = REPO_ROOT / "tinigsenyas_training"
PROCESSING_ROOT = BACKEND_ROOT / "processed_6199"
TRAINING_SETS = PROCESSING_ROOT / "training_sets"
OUTPUT_ROOT = BACKEND_ROOT / "models" / "6199_candidate"
SEED = 42
SEQUENCE_SHAPE = (60, 75, 3)
ALPHABET_SHAPE = (63,)

sys.path.insert(0, str(BACKEND_ROOT))
import train_connected_stgcn_candidate as connected  # noqa: E402


def read_lines(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def load_folder_data(root: Path, labels: list[str], expected_shape: tuple[int, ...]):
    index_path = root / "features.csv"
    if index_path.is_file():
        with index_path.open(encoding="utf-8-sig", newline="") as stream:
            indexed_rows = list(csv.DictReader(stream))
        files_by_label = {
            label: sorted(
                (Path(row["feature_path"]) for row in indexed_rows if row["label"] == label),
                key=str,
            )
            for label in labels
        }
    else:
        files_by_label = None

    samples: list[np.ndarray] = []
    targets: list[int] = []
    counts: Counter[str] = Counter()
    for index, label in enumerate(labels):
        folder = root / label
        if files_by_label is None and not folder.is_dir():
            raise FileNotFoundError(f"Missing class folder: {folder}")
        feature_paths = files_by_label[label] if files_by_label is not None else sorted(folder.glob("*.npy"))
        for path in feature_paths:
            sample = np.load(path, allow_pickle=False)
            if sample.shape != expected_shape or not np.isfinite(sample).all():
                raise ValueError(f"Invalid feature {path}: shape={sample.shape}")
            samples.append(sample.astype(np.float32, copy=False))
            targets.append(index)
            counts[label] += 1
    if not samples:
        raise ValueError(f"No valid samples found under {root}.")
    too_small = {label: count for label, count in counts.items() if count < 2}
    if too_small:
        raise ValueError(f"Every class needs at least two samples: {too_small}")
    return np.stack(samples).astype(np.float32), np.asarray(targets, dtype=np.int64), counts


def _class_weights(y: np.ndarray) -> dict[int, float]:
    classes = np.unique(y)
    weights = compute_class_weight(class_weight="balanced", classes=classes, y=y)
    return {int(index): float(weight) for index, weight in zip(classes, weights)}


def _eval_static_tflite(model_path: Path, x: np.ndarray, y: np.ndarray, labels: list[str]):
    from ai_edge_litert.interpreter import Interpreter

    interpreter = Interpreter(model_path=str(model_path), num_threads=2)
    interpreter.allocate_tensors()
    input_detail = interpreter.get_input_details()[0]
    output_detail = interpreter.get_output_details()[0]
    if input_detail["shape"].tolist() != [1, 63]:
        raise ValueError(f"Unexpected alphabet input shape: {input_detail['shape']}.")
    if output_detail["shape"].tolist() != [1, len(labels)]:
        raise ValueError(f"Unexpected alphabet output shape: {output_detail['shape']}.")

    predictions: list[int] = []
    confidences: list[float] = []
    for sample in x:
        interpreter.set_tensor(input_detail["index"], sample[None].astype(input_detail["dtype"]))
        interpreter.invoke()
        probabilities = interpreter.get_tensor(output_detail["index"])[0]
        predictions.append(int(np.argmax(probabilities)))
        confidences.append(float(np.max(probabilities)))
    predicted = np.asarray(predictions, dtype=np.int64)
    per_class = {
        label: float(np.mean(predicted[y == index] == index))
        for index, label in enumerate(labels)
        if np.any(y == index)
    }
    return {
        "samples": int(len(y)),
        "top1_accuracy": float(np.mean(predicted == y)),
        "mean_confidence": float(np.mean(confidences)),
        "median_class_recall": float(np.median(list(per_class.values()))),
        "minimum_class_recall": float(min(per_class.values())),
        "per_class_recall": per_class,
    }


def _eval_medical_baseline(model_path: Path, old_labels: list[str], x: np.ndarray, y: np.ndarray, new_labels: list[str]):
    from ai_edge_litert.interpreter import Interpreter

    true_indices = [index for index, target in enumerate(y) if new_labels[int(target)] in old_labels]
    if not true_indices:
        return {"samples": 0, "top1_accuracy_on_shared_labels": None}

    interpreter = Interpreter(model_path=str(model_path), num_threads=2)
    interpreter.allocate_tensors()
    input_detail = interpreter.get_input_details()[0]
    output_detail = interpreter.get_output_details()[0]
    if input_detail["shape"].tolist() != [1, 60, 75, 3]:
        raise ValueError(f"Unexpected medical baseline input shape: {input_detail['shape']}.")
    if output_detail["shape"].tolist() != [1, len(old_labels)]:
        raise ValueError(f"Medical baseline output has {output_detail['shape']}, expected {len(old_labels)} labels.")

    correct = 0
    for sample_index in true_indices:
        sample = x[sample_index]
        target_label = new_labels[int(y[sample_index])]
        interpreter.set_tensor(input_detail["index"], sample[None].astype(input_detail["dtype"]))
        interpreter.invoke()
        predicted = old_labels[int(np.argmax(interpreter.get_tensor(output_detail["index"])[0]))]
        correct += predicted == target_label
    return {
        "samples": len(true_indices),
        "shared_labels": sorted(set(old_labels) & set(new_labels)),
        "top1_accuracy_on_shared_labels": float(correct / len(true_indices)),
    }


def train_medical(output_dir: Path, epochs: int, batch_size: int) -> dict[str, object]:
    output_dir.mkdir(parents=True, exist_ok=True)
    labels = json.loads((TRAINING_SETS / "dataset_counts.json").read_text(encoding="utf-8"))["medical"]["label_order"]
    x, y, counts = load_folder_data(TRAINING_SETS / "medical", labels, SEQUENCE_SHAPE)
    validation_count = max(int(np.ceil(0.20 * len(y))), len(labels))
    x_train, x_val, y_train, y_val = train_test_split(
        x, y, test_size=validation_count, random_state=SEED, stratify=y
    )
    x_train, y_train = connected.augment_training_data(x_train, y_train)

    model = connected.build_model(len(labels))
    checkpoint_path = TRAINING_ROOT / "best_fsl_model.keras"
    source = connected.load_compatible_checkpoint(checkpoint_path)
    source_weights = source.get_weights()
    candidate_weights = model.get_weights()
    if len(source_weights) != len(candidate_weights) or any(
        old.shape != new.shape for old, new in zip(source_weights[:-2], candidate_weights[:-2])
    ):
        raise ValueError("The ST-GCN backbone checkpoint does not match the medical candidate architecture.")
    candidate_weights[:-2] = [weight.copy() for weight in source_weights[:-2]]
    model.set_weights(candidate_weights)
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=5e-5),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    checkpoint = output_dir / "best_medical_stgcn.keras"
    model.fit(
        x_train,
        y_train,
        validation_data=(x_val, y_val),
        epochs=epochs,
        batch_size=batch_size,
        class_weight=_class_weights(y_train),
        callbacks=[
            tf.keras.callbacks.ModelCheckpoint(checkpoint, monitor="val_loss", save_best_only=True, verbose=1),
            tf.keras.callbacks.EarlyStopping(monitor="val_loss", patience=8, restore_best_weights=True, verbose=1),
            tf.keras.callbacks.ReduceLROnPlateau(monitor="val_loss", factor=0.5, patience=3, min_lr=1e-6, verbose=1),
        ],
        verbose=2,
    )
    model.save(output_dir / "medical_stgcn_runtime_order.keras")
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    candidate_path = output_dir / "fsl_medical_35_candidate.tflite"
    candidate_path.write_bytes(converter.convert())

    metrics = connected.eval_tflite(candidate_path, x_val, y_val, labels)
    baseline_labels = read_lines(REPO_ROOT / "frontend" / "assets" / "model" / "medical_labels.txt")
    metrics["baseline_current_app_shared_labels"] = _eval_medical_baseline(
        BACKEND_ROOT / "models" / "fsl_medical.tflite", baseline_labels, x_val, y_val, labels
    )
    metrics["training_samples"] = int(len(y))
    metrics["validation_samples"] = int(len(y_val))
    metrics["class_counts"] = dict(counts)
    metrics["initialization"] = "Connected ST-GCN backbone transferred from the existing 103-class Keras checkpoint; 35-class head initialized for this dataset."
    (output_dir / "medical_metrics.json").write_text(json.dumps(metrics, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output_dir / "medical_labels.txt").write_text("\n".join(labels) + "\n", encoding="utf-8")
    return {"metrics": metrics, "model": str(candidate_path)}


def augment_alphabet(x: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(SEED)
    augmented_x = [x]
    augmented_y = [y]
    points = x.reshape((-1, 21, 3))
    jittered = points + rng.normal(0.0, 0.006, size=points.shape).astype(np.float32)
    jittered[:, 0, :] = 0.0
    angles = rng.uniform(-0.08, 0.08, size=(len(points), 1, 1)).astype(np.float32)
    cosines = np.cos(angles)
    sines = np.sin(angles)
    rotated = points.copy()
    rotated[:, :, 0] = cosines[:, 0, 0, None] * points[:, :, 0] - sines[:, 0, 0, None] * points[:, :, 1]
    rotated[:, :, 1] = sines[:, 0, 0, None] * points[:, :, 0] + cosines[:, 0, 0, None] * points[:, :, 1]
    rotated += rng.normal(0.0, 0.004, size=rotated.shape).astype(np.float32)
    rotated[:, 0, :] = 0.0
    augmented_x.append(jittered.reshape((-1, 63)).astype(np.float32))
    augmented_x.append(rotated.reshape((-1, 63)).astype(np.float32))
    augmented_y.extend((y, y))
    return np.concatenate(augmented_x, axis=0), np.concatenate(augmented_y, axis=0)


def train_alphabet(output_dir: Path, epochs: int, batch_size: int) -> dict[str, object]:
    output_dir.mkdir(parents=True, exist_ok=True)
    labels = read_lines(REPO_ROOT / "frontend" / "assets" / "model" / "alphabet_labels.txt")
    x, y, counts = load_folder_data(TRAINING_SETS / "alphabet", labels, ALPHABET_SHAPE)
    validation_count = max(int(np.ceil(0.20 * len(y))), len(labels))
    x_train, x_val, y_train, y_val = train_test_split(
        x, y, test_size=validation_count, random_state=SEED, stratify=y
    )
    x_train, y_train = augment_alphabet(x_train, y_train)

    inputs = layers.Input(shape=ALPHABET_SHAPE)
    x_model = layers.BatchNormalization()(inputs)
    x_model = layers.Dense(192, activation="relu")(x_model)
    x_model = layers.Dropout(0.35)(x_model)
    x_model = layers.Dense(96, activation="relu")(x_model)
    x_model = layers.Dropout(0.25)(x_model)
    outputs = layers.Dense(len(labels), activation="softmax")(x_model)
    model = models.Model(inputs, outputs, name="fsl_alphabet_landmark_classifier")
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-3),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    checkpoint = output_dir / "best_alphabet.keras"
    model.fit(
        x_train,
        y_train,
        validation_data=(x_val, y_val),
        epochs=epochs,
        batch_size=batch_size,
        class_weight=_class_weights(y_train),
        callbacks=[
            tf.keras.callbacks.ModelCheckpoint(checkpoint, monitor="val_loss", save_best_only=True, verbose=1),
            tf.keras.callbacks.EarlyStopping(monitor="val_loss", patience=12, restore_best_weights=True, verbose=1),
            tf.keras.callbacks.ReduceLROnPlateau(monitor="val_loss", factor=0.5, patience=4, min_lr=1e-6, verbose=1),
        ],
        verbose=2,
    )
    model.save(output_dir / "alphabet_runtime_order.keras")
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    candidate_path = output_dir / "fsl_alphabet_candidate.tflite"
    candidate_path.write_bytes(converter.convert())

    candidate_metrics = _eval_static_tflite(candidate_path, x_val, y_val, labels)
    baseline_metrics = _eval_static_tflite(
        BACKEND_ROOT / "models" / "fsl_alphabet.tflite", x_val, y_val, labels
    )
    metrics = {
        "validation_protocol": "stratified sample-level split, random_state=42; signer identities are not present in the source manifest.",
        "training_samples": int(len(y)),
        "validation_samples": int(len(y_val)),
        "class_counts": dict(counts),
        "baseline_current_app": baseline_metrics,
        "alphabet_candidate": candidate_metrics,
        "initialization": "Trained from the supplied landmark videos; no Keras training checkpoint for the shipped alphabet TFLite model is present.",
    }
    (output_dir / "alphabet_metrics.json").write_text(json.dumps(metrics, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output_dir / "alphabet_labels.txt").write_text("\n".join(labels) + "\n", encoding="utf-8")
    return {"metrics": metrics, "model": str(candidate_path)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs-phrase", type=int, default=20)
    parser.add_argument("--epochs-medical", type=int, default=35)
    parser.add_argument("--epochs-alphabet", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--skip-phrase", action="store_true", help="Use a previously exported phrase candidate.")
    parser.add_argument("--phrase-candidate", type=Path, help="Previously exported phrase TFLite candidate.")
    parser.add_argument(
        "--resume-phrase-from",
        type=Path,
        help="Resume phrase fine-tuning from a saved ST-GCN candidate checkpoint.",
    )
    args = parser.parse_args()

    counts_path = TRAINING_SETS / "dataset_counts.json"
    manifest_path = PROCESSING_ROOT / "manifest.csv"
    if not counts_path.is_file() or not manifest_path.is_file():
        raise FileNotFoundError("Run prepare_6199_dataset.py --process and build_6199_training_sets.py first.")
    counts = json.loads(counts_path.read_text(encoding="utf-8"))
    if counts["source_archive_entries"] != 6199:
        raise ValueError(f"Expected 6,199 source archive entries; found {counts['source_archive_entries']}.")
    with manifest_path.open(encoding="utf-8-sig", newline="") as stream:
        records = list(csv.DictReader(stream))
    excluded_unusable = [
        row for row in records
        if row["head"] == "alphabet"
        and row["status"] == "failed_alphabet"
        and "No usable hand landmarks" in row["detail"]
    ]
    failures = [
        row for row in records
        if (row["status"].startswith("failed") or row["status"] == "pending")
        and row not in excluded_unusable
    ]
    if failures:
        raise ValueError(f"Refusing to train with {len(failures)} unprocessed or failed source entries.")
    if len(excluded_unusable) != counts["alphabet"].get("unusable_source_rows_excluded", 0):
        raise ValueError("Dataset index does not account for every unusable alphabet source clip.")
    phrase_output_name = "conversation"
    phrase_candidate_path: Path | None = None
    init_checkpoint = TRAINING_ROOT / "best_fsl_model.keras"
    if args.skip_phrase:
        if args.resume_phrase_from:
            raise ValueError("--skip-phrase and --resume-phrase-from cannot be used together.")
        if args.phrase_candidate:
            phrase_candidate_path = args.phrase_candidate.resolve()
        else:
            candidates = sorted(
                OUTPUT_ROOT.glob("conversation*/fsl_model_connected_candidate.tflite"),
                key=lambda path: path.stat().st_mtime,
            ) if OUTPUT_ROOT.exists() else []
            phrase_candidate_path = candidates[-1] if candidates else None
        if phrase_candidate_path is None or not phrase_candidate_path.is_file():
            raise FileNotFoundError("--skip-phrase requires an existing exported phrase candidate.")
        existing = list(OUTPUT_ROOT.iterdir()) if OUTPUT_ROOT.exists() else []
        allowed = {"medical", "alphabet", "training_summary.json"}
        unexpected = [path.name for path in existing if not path.name.startswith("conversation") and path.name not in allowed]
        if unexpected:
            raise FileExistsError(f"Unexpected candidate outputs prevent safe continuation: {unexpected}")
        for stage in ("medical", "alphabet"):
            path = OUTPUT_ROOT / stage
            if path.exists() and any(path.iterdir()):
                raise FileExistsError(f"Refusing to overwrite partial {stage} outputs: {path}")
        phrase_output_name = phrase_candidate_path.parent.name
    elif args.resume_phrase_from:
        init_checkpoint = args.resume_phrase_from.resolve()
        if not init_checkpoint.is_file():
            raise FileNotFoundError(f"Phrase resume checkpoint not found: {init_checkpoint}")
        existing = list(OUTPUT_ROOT.iterdir()) if OUTPUT_ROOT.exists() else []
        unexpected = [path.name for path in existing if not path.name.startswith("conversation")]
        if unexpected:
            raise FileExistsError(
                f"Cannot resume phrase training after other candidate stages have started: {unexpected}"
            )
        resume_number = 1
        while (OUTPUT_ROOT / f"conversation_resume_{resume_number}").exists():
            resume_number += 1
        phrase_output_name = f"conversation_resume_{resume_number}"
    elif OUTPUT_ROOT.exists() and any(OUTPUT_ROOT.iterdir()):
        raise FileExistsError(f"Refusing to overwrite existing candidate outputs: {OUTPUT_ROOT}")
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    random.seed(SEED)
    np.random.seed(SEED)
    tf.keras.utils.set_random_seed(SEED)

    phrase_command = [
        sys.executable,
        str(BACKEND_ROOT / "train_connected_stgcn_candidate.py"),
        "--dataset-dir",
        str(TRAINING_SETS / "conversation"),
        "--baseline-model",
        str(REPO_ROOT / "frontend" / "assets" / "model" / "fsl_model.tflite"),
        "--baseline-labels",
        str(REPO_ROOT / "frontend" / "assets" / "model" / "labels.txt"),
        "--output-dir",
        str(OUTPUT_ROOT / phrase_output_name),
        "--init-checkpoint",
        str(init_checkpoint),
        "--epochs",
        str(args.epochs_phrase),
        "--batch-size",
        str(max(16, args.batch_size)),
    ]
    if args.resume_phrase_from:
        phrase_command.extend(("--init-labels", str(TRAINING_SETS / "conversation" / "labels.txt")))
    if args.skip_phrase:
        print(f"Using completed phrase candidate: {phrase_candidate_path}", flush=True)
    else:
        print("Training 103-class conversation ST-GCN candidate...", flush=True)
        subprocess.run(phrase_command, cwd=REPO_ROOT, check=True)
        phrase_candidate_path = OUTPUT_ROOT / phrase_output_name / "fsl_model_connected_candidate.tflite"
    print("Training 35-class medical ST-GCN candidate...", flush=True)
    medical = train_medical(OUTPUT_ROOT / "medical", args.epochs_medical, args.batch_size)
    print("Training 28-class alphabet candidate...", flush=True)
    alphabet = train_alphabet(OUTPUT_ROOT / "alphabet", args.epochs_alphabet, args.batch_size)

    result = {
        "source_archive_entries": 6199,
        "unusable_alphabet_source_rows_excluded": len(excluded_unusable),
        "conversation_candidate": str(phrase_candidate_path),
        "medical_candidate": medical["model"],
        "alphabet_candidate": alphabet["model"],
        "ota_published": False,
        "signer_independent_validation": False,
    }
    (OUTPUT_ROOT / "training_summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
