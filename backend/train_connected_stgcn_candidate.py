"""Train and compare a fully connected 75-landmark ST-GCN candidate.

The validation split is sample-level because the current dataset does not store
signer identities. It is useful for a controlled model comparison, but it is not
a signer-independent estimate of real-world accuracy.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
import tempfile
import zipfile
from pathlib import Path

import numpy as np
import tensorflow as tf
from sklearn.model_selection import train_test_split
from sklearn.utils.class_weight import compute_class_weight
from tensorflow.keras import layers, models, regularizers
from tensorflow.keras.callbacks import EarlyStopping, ModelCheckpoint, ReduceLROnPlateau


SEQUENCE_LENGTH = 60
TOTAL_JOINTS = 75
COORDINATES = 3
INPUT_SHAPE = (SEQUENCE_LENGTH, TOTAL_JOINTS, COORDINATES)
SEED = 42
MIN_SHOULDER_WIDTH = 0.05


def load_compatible_checkpoint(checkpoint_path: Path) -> tf.keras.Model:
    """Load a Keras archive after dropping removed, disabled BatchNorm options."""
    with zipfile.ZipFile(checkpoint_path) as archive:
        names = archive.namelist()
        if "config.json" not in names:
            raise ValueError(f"Keras checkpoint has no config.json: {checkpoint_path}")
        config = json.loads(archive.read("config.json"))

        def strip_unsupported_checkpoint_metadata(value):
            if isinstance(value, dict):
                layer_config = value.get("config")
                if isinstance(layer_config, dict) and layer_config.get("quantization_config") is None:
                    layer_config.pop("quantization_config", None)
                if value.get("class_name") == "BatchNormalization" and isinstance(value.get("config"), dict):
                    for option in ("renorm", "renorm_clipping", "renorm_momentum"):
                        value["config"].pop(option, None)
                if value.get("class_name") == "GlorotUniform" and isinstance(value.get("config"), dict):
                    # Newer Keras records these axes; they do not affect a model
                    # after the saved weights are restored.
                    value["config"].pop("input_axes", None)
                    value["config"].pop("output_axes", None)
                for nested in value.values():
                    strip_unsupported_checkpoint_metadata(nested)
            elif isinstance(value, list):
                for nested in value:
                    strip_unsupported_checkpoint_metadata(nested)

        strip_unsupported_checkpoint_metadata(config)
        with tempfile.TemporaryDirectory(prefix="tinigsenyas_keras_") as temp_dir:
            compatible_path = Path(temp_dir) / checkpoint_path.name
            with zipfile.ZipFile(compatible_path, "w", compression=zipfile.ZIP_DEFLATED) as output:
                for name in names:
                    contents = (
                        json.dumps(config, ensure_ascii=False).encode("utf-8")
                        if name == "config.json"
                        else archive.read(name)
                    )
                    output.writestr(name, contents)
            return tf.keras.models.load_model(
                compatible_path,
                custom_objects={"TFLiteGraphConv": TFLiteGraphConv},
                compile=False,
            )


def build_connected_adjacency() -> np.ndarray:
    """Build a connected graph for pose, arms, wrists, and both hands."""
    adjacency = np.eye(TOTAL_JOINTS, dtype=np.float32)

    # MediaPipe Pose's face landmarks are joined to the shoulder line through
    # the ears, representing the neck connection needed for one body graph.
    pose_edges = [
        (0, 1), (1, 2), (2, 3), (3, 7),
        (0, 4), (4, 5), (5, 6), (6, 8),
        (0, 9), (9, 10),
        (7, 11), (8, 12),
        (11, 12),
        (11, 13), (13, 15), (15, 17), (15, 19), (15, 21), (17, 19),
        (12, 14), (14, 16), (16, 18), (16, 20), (16, 22), (18, 20),
        (11, 23), (12, 24), (23, 24),
        (23, 25), (25, 27), (27, 29), (29, 31), (27, 31),
        (24, 26), (26, 28), (28, 30), (30, 32), (28, 32),
    ]
    hand_edges = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (5, 9), (9, 10), (10, 11), (11, 12),
        (9, 13), (13, 14), (14, 15), (15, 16),
        (13, 17), (17, 18), (18, 19), (19, 20), (0, 17),
    ]

    for first, second in pose_edges:
        adjacency[first, second] = adjacency[second, first] = 1.0
    for first, second in hand_edges:
        for offset in (33, 54):
            left, right = offset + first, offset + second
            adjacency[left, right] = adjacency[right, left] = 1.0

    # Join each hand wrist to its corresponding MediaPipe body wrist.
    adjacency[15, 33] = adjacency[33, 15] = 1.0
    adjacency[16, 54] = adjacency[54, 16] = 1.0

    degrees = adjacency.sum(axis=1)
    inv_sqrt = np.power(degrees, -0.5, where=degrees > 0)
    inv_sqrt[degrees == 0] = 0.0
    normalized = inv_sqrt[:, None] * adjacency * inv_sqrt[None, :]

    # Fail early if an index or edge change accidentally leaves joints isolated.
    if np.any((adjacency.sum(axis=1) - np.eye(TOTAL_JOINTS).sum(axis=1)) <= 0):
        raise ValueError("Every landmark must have at least one anatomical edge.")
    return normalized.astype(np.float32)


@tf.keras.utils.register_keras_serializable()
class GraphConv(layers.Layer):
    def __init__(self, output_channels: int, adjacency: np.ndarray, **kwargs):
        super().__init__(**kwargs)
        self.output_channels = int(output_channels)
        self.adjacency = np.asarray(adjacency, dtype=np.float32)
        self.projection = layers.Dense(self.output_channels, use_bias=False)

    def call(self, inputs):
        projected = self.projection(inputs)
        shape = tf.shape(projected)
        flattened = tf.reshape(projected, [-1, TOTAL_JOINTS, self.output_channels])
        mixed = tf.matmul(tf.constant(self.adjacency), flattened)
        return tf.reshape(
            mixed,
            [shape[0], shape[1], TOTAL_JOINTS, self.output_channels],
        )

    def get_config(self):
        config = super().get_config()
        config.update(
            {
                "output_channels": self.output_channels,
                "adjacency": self.adjacency.tolist(),
            }
        )
        return config


@tf.keras.utils.register_keras_serializable()
class TFLiteGraphConv(layers.Layer):
    """Checkpoint-compatible graph layer from the original Keras model."""

    def __init__(self, out_channels: int, adj_matrix: np.ndarray, **kwargs):
        super().__init__(**kwargs)
        self.out_channels = int(out_channels)
        self.adj_matrix = np.asarray(adj_matrix, dtype=np.float32)
        self.A = tf.constant(self.adj_matrix, dtype=tf.float32)

    def build(self, input_shape):
        self.dense = layers.Dense(self.out_channels, use_bias=False)
        super().build(input_shape)

    def call(self, inputs):
        projected = self.dense(inputs)
        shape = tf.shape(inputs)
        flattened = tf.reshape(
            projected,
            [-1, TOTAL_JOINTS, self.out_channels],
        )
        mixed = tf.matmul(self.A, flattened)
        return tf.reshape(
            mixed,
            [shape[0], shape[1], TOTAL_JOINTS, self.out_channels],
        )

    def get_config(self):
        config = super().get_config()
        config.update(
            {
                "out_channels": self.out_channels,
                "adj_matrix": self.adj_matrix.tolist(),
            }
        )
        return config


def mirror_sample_hands(sample: np.ndarray) -> np.ndarray:
    mirrored = sample.copy()
    mirrored[:, :33, 0] *= -1.0
    right = sample[:, 54:75, :].copy()
    left = sample[:, 33:54, :].copy()
    has_right = np.any(np.abs(right) > 1e-6)
    has_left = np.any(np.abs(left) > 1e-6)

    if has_right and not has_left:
        wrist_x = right[:, 0:1, 0:1]
        right[:, :, 0] = 2.0 * wrist_x[:, :, 0] - right[:, :, 0]
        mirrored[:, 33:54, :] = right
        mirrored[:, 54:75, :] = 0.0
    elif has_left and not has_right:
        wrist_x = left[:, 0:1, 0:1]
        left[:, :, 0] = 2.0 * wrist_x[:, :, 0] - left[:, :, 0]
        mirrored[:, 54:75, :] = left
        mirrored[:, 33:54, :] = 0.0
    else:
        mirrored[:, 33:54, 0] *= -1.0
        mirrored[:, 54:75, 0] *= -1.0
        mirrored[:, 33:54, :], mirrored[:, 54:75, :] = (
            mirrored[:, 54:75, :].copy(),
            mirrored[:, 33:54, :].copy(),
        )
    return mirrored.astype(np.float32)


def augment_training_data(x: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(SEED)
    augmented_x = [sample for sample in x]
    augmented_y = list(y)
    for sample, label in zip(x, y):
        scaled = sample * np.float32(rng.uniform(0.90, 1.10))
        valid = np.any(np.abs(scaled) > 1e-8, axis=2, keepdims=True)
        noise = rng.normal(0.0, 0.002, size=scaled.shape).astype(np.float32)
        augmented_x.append((scaled + noise * valid).astype(np.float32))
        augmented_y.append(label)
        augmented_x.append(mirror_sample_hands(sample))
        augmented_y.append(label)
    return np.stack(augmented_x), np.asarray(augmented_y, dtype=np.int64)


def load_dataset(dataset_dir: Path):
    feature_index = dataset_dir / "features.csv"
    if feature_index.is_file():
        with feature_index.open(encoding="utf-8-sig", newline="") as stream:
            indexed_rows = list(csv.DictReader(stream))
        labels = sorted({row["label"] for row in indexed_rows})
        files_by_label = {
            label: sorted(
                (Path(row["feature_path"]) for row in indexed_rows if row["label"] == label),
                key=str,
            )
            for label in labels
        }
    else:
        class_dirs = sorted(path for path in dataset_dir.iterdir() if path.is_dir())
        labels = [folder.name for folder in class_dirs]
        files_by_label = {folder.name: sorted(folder.glob("*.npy")) for folder in class_dirs}

    samples: list[np.ndarray] = []
    targets: list[int] = []
    skipped = 0

    ordered_labels: list[str] = []
    for label in labels:
        class_samples = []
        for file in files_by_label[label]:
            try:
                sample = np.load(file, allow_pickle=False)
            except Exception:
                skipped += 1
                continue
            if sample.shape != INPUT_SHAPE or not np.isfinite(sample).all():
                skipped += 1
                continue
            class_samples.append(sample.astype(np.float32))
        if class_samples:
            label_index = len(ordered_labels)
            ordered_labels.append(label)
            samples.extend(class_samples)
            targets.extend([label_index] * len(class_samples))

    if len(ordered_labels) != 103:
        raise ValueError(f"Expected 103 classes; found {len(ordered_labels)}.")
    x = np.stack(samples).astype(np.float32)
    y = np.asarray(targets, dtype=np.int64)
    if any(np.count_nonzero(y == index) < 2 for index in range(len(labels))):
        raise ValueError("Every class needs at least two valid samples.")
    return x, y, ordered_labels, skipped


def build_model(num_classes: int) -> tf.keras.Model:
    adjacency = build_connected_adjacency()
    inputs = layers.Input(shape=INPUT_SHAPE)
    x = layers.BatchNormalization()(inputs)
    x = GraphConv(32, adjacency)(x)
    x = layers.Conv2D(32, (9, 1), padding="same", activation="relu")(x)
    x = layers.BatchNormalization()(x)
    x = layers.Dropout(0.45)(x)

    x = GraphConv(64, adjacency)(x)
    x = layers.Conv2D(64, (9, 1), padding="same", activation="relu")(x)
    x = layers.BatchNormalization()(x)
    x = layers.Dropout(0.45)(x)

    x = layers.AveragePooling2D(pool_size=(1, TOTAL_JOINTS))(x)
    x = layers.Reshape((SEQUENCE_LENGTH, 64))(x)
    x = layers.Conv1D(128, 5, padding="same", activation="relu")(x)
    x = layers.BatchNormalization()(x)
    x = layers.Dropout(0.3)(x)
    pooled = layers.Concatenate()(
        [layers.GlobalAveragePooling1D()(x), layers.GlobalMaxPooling1D()(x)]
    )
    x = layers.Dense(
        128,
        activation="relu",
        kernel_regularizer=regularizers.l2(0.005),
    )(pooled)
    x = layers.Dropout(0.4)(x)
    outputs = layers.Dense(num_classes, activation="softmax")(x)
    return models.Model(inputs, outputs)


def eval_tflite(model_path: Path, x: np.ndarray, y: np.ndarray, labels: list[str]):
    from ai_edge_litert.interpreter import Interpreter

    interpreter = Interpreter(model_path=str(model_path), num_threads=4)
    interpreter.allocate_tensors()
    input_detail = interpreter.get_input_details()[0]
    output_detail = interpreter.get_output_details()[0]
    if input_detail["shape"].tolist() != [1, 60, 75, 3]:
        raise ValueError(f"Unexpected model input shape: {input_detail['shape']}.")
    if output_detail["shape"].tolist() != [1, len(labels)]:
        raise ValueError(f"Unexpected model output shape: {output_detail['shape']}.")

    label_to_index = {label: index for index, label in enumerate(labels)}
    predictions = []
    scores = []
    margins = []
    for sample in x:
        interpreter.set_tensor(
            input_detail["index"],
            sample[None].astype(input_detail["dtype"]),
        )
        interpreter.invoke()
        probabilities = interpreter.get_tensor(output_detail["index"])[0]
        top = np.argsort(probabilities)[-2:]
        predictions.append(label_to_index[labels[int(top[-1])]])
        scores.append(float(probabilities[top[-1]]))
        margins.append(float(probabilities[top[-1]] - probabilities[top[-2]]))

    predictions = np.asarray(predictions)
    scores = np.asarray(scores)
    margins = np.asarray(margins)
    accepted = (scores >= 0.75) | ((scores >= 0.60) & (margins >= 0.12))
    class_recalls = {
        label: float(np.mean(predictions[y == index] == y[y == index]))
        for index, label in enumerate(labels)
        if np.any(y == index)
    }
    return {
        "top1_accuracy": float(np.mean(predictions == y)),
        "gate_coverage": float(np.mean(accepted)),
        "accepted_accuracy": (
            float(np.mean(predictions[accepted] == y[accepted]))
            if np.any(accepted)
            else 0.0
        ),
        "median_class_recall": float(np.median(list(class_recalls.values()))),
        "minimum_class_recall": float(min(class_recalls.values())),
        "zero_recall_classes": [
            label for label, recall in class_recalls.items() if recall == 0.0
        ],
        "per_class_recall": class_recalls,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dataset-dir",
        type=Path,
        default=Path("tinigsenyas_training/datasets"),
    )
    parser.add_argument(
        "--baseline-model",
        type=Path,
        default=Path("frontend/assets/model/fsl_model.tflite"),
    )
    parser.add_argument(
        "--baseline-labels",
        type=Path,
        default=Path("frontend/assets/model/labels.txt"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("backend/models/connected_stgcn_ota_candidate"),
    )
    parser.add_argument(
        "--init-checkpoint",
        type=Path,
        default=Path("tinigsenyas_training/best_fsl_model.keras"),
    )
    parser.add_argument("--init-labels", type=Path, help="Label order used by --init-checkpoint.")
    parser.add_argument("--epochs", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=64)
    args = parser.parse_args()

    if args.output_dir.exists() and any(args.output_dir.iterdir()):
        raise FileExistsError(
            f"Refusing to overwrite non-empty candidate directory: {args.output_dir}"
        )
    args.output_dir.mkdir(parents=True, exist_ok=True)

    random.seed(SEED)
    np.random.seed(SEED)
    tf.keras.utils.set_random_seed(SEED)

    x, y, labels, skipped = load_dataset(args.dataset_dir)
    validation_count = max(math.ceil(0.20 * len(y)), len(labels))
    x_train, x_val, y_train, y_val = train_test_split(
        x,
        y,
        test_size=validation_count,
        random_state=SEED,
        stratify=y,
    )

    # Compare the current shipped model and new candidate on exactly the same
    # untouched samples, matching each model's output indices by label text.
    baseline_labels = [
        label.strip()
        for label in args.baseline_labels.read_text(encoding="utf-8").splitlines()
        if label.strip()
    ]
    # The baseline output order differs from the dataset folder order. Evaluate
    # it with the shipped labels and translate targets by label name.
    baseline_y = np.asarray([baseline_labels.index(labels[i]) for i in y_val])
    baseline_order_metrics = eval_tflite(
        args.baseline_model,
        x_val,
        baseline_y,
        baseline_labels,
    )

    x_train, y_train = augment_training_data(x_train, y_train)
    classes = np.unique(y_train)
    weights = compute_class_weight(class_weight="balanced", classes=classes, y=y_train)
    class_weights = {int(key): float(value) for key, value in zip(classes, weights)}

    model = build_model(len(labels))
    if args.init_checkpoint.exists():
        source_model = load_compatible_checkpoint(args.init_checkpoint)
        source_weights = source_model.get_weights()
        candidate_weights = [weight.copy() for weight in source_weights]
        model_weights = model.get_weights()
        if len(source_weights) != len(model_weights) or any(
            old.shape != new.shape
            for old, new in zip(source_weights, model_weights)
        ):
            raise ValueError(
                "The existing checkpoint architecture does not match this candidate."
            )

        # Reorder the classifier head from the existing model's labels to the
        # sorted dataset labels used by this candidate.
        init_labels_path = args.init_labels or args.baseline_labels
        source_labels = [
            label.strip()
            for label in init_labels_path.read_text(encoding="utf-8").splitlines()
            if label.strip()
        ]
        source_index = {label: index for index, label in enumerate(source_labels)}
        if len(source_index) != len(labels) or set(source_index) != set(labels):
            raise ValueError(f"Init checkpoint label file does not match the training classes: {init_labels_path}")
        permutation = np.asarray([source_index[label] for label in labels])
        candidate_weights[-2] = source_weights[-2][:, permutation]
        candidate_weights[-1] = source_weights[-1][permutation]
        model.set_weights(candidate_weights)
        print(
            f"Initialized connected graph from existing checkpoint: "
            f"{args.init_checkpoint}",
            flush=True,
        )

    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-4),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    checkpoint = args.output_dir / "best_connected_stgcn.keras"
    callbacks = [
        ModelCheckpoint(
            checkpoint,
            monitor="val_loss",
            save_best_only=True,
            verbose=1,
        ),
        EarlyStopping(
            monitor="val_loss",
            patience=12,
            restore_best_weights=True,
            verbose=1,
        ),
        ReduceLROnPlateau(
            monitor="val_loss",
            factor=0.5,
            patience=4,
            min_lr=1e-6,
            verbose=1,
        ),
    ]
    model.fit(
        x_train,
        y_train,
        validation_data=(x_val, y_val),
        epochs=args.epochs,
        batch_size=args.batch_size,
        class_weight=class_weights,
        callbacks=callbacks,
        verbose=2,
    )

    # Training uses alphabetically sorted dataset folders. The app's deployed
    # model uses the existing labels.txt order, so reorder the final Dense head
    # before export to preserve that runtime contract without changing labels.
    output_order = np.asarray([labels.index(label) for label in baseline_labels])
    export_weights = model.get_weights()
    export_weights[-2] = export_weights[-2][:, output_order].copy()
    export_weights[-1] = export_weights[-1][output_order].copy()
    model.set_weights(export_weights)
    model.save(args.output_dir / "connected_stgcn_runtime_order.keras")

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    candidate_path = args.output_dir / "fsl_model_connected_candidate.tflite"
    candidate_path.write_bytes(converter.convert())
    labels_path = args.output_dir / "labels_connected_candidate.txt"
    labels_path.write_text("\n".join(baseline_labels) + "\n", encoding="utf-8")

    candidate_metrics = eval_tflite(
        candidate_path,
        x_val,
        baseline_y,
        baseline_labels,
    )
    report = {
        "validation_protocol": "sample-level stratified split, random_state=42",
        "signer_independent": False,
        "dataset_classes": len(labels),
        "dataset_samples": int(len(y)),
        "validation_samples": int(len(y_val)),
        "skipped_samples": skipped,
        "baseline_current_app": baseline_order_metrics,
        "connected_graph_candidate": candidate_metrics,
    }
    (args.output_dir / "validation_metrics.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({key: report[key] for key in (
        "validation_protocol",
        "signer_independent",
        "dataset_classes",
        "dataset_samples",
        "validation_samples",
        "baseline_current_app",
        "connected_graph_candidate",
    )}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
