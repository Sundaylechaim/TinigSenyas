import 'package:flutter/material.dart';

class RecognitionScore {
  const RecognitionScore(this.label, this.probability);

  final String label;
  final double probability;
}

/// Camera-space landmarks and the corresponding model-normalized graph frame.
/// A window contains up to 60 of these frames in the deployed ST-GCN contract.
class RecognitionGraphFrame {
  const RecognitionGraphFrame({
    required this.capturedAt,
    required this.pose,
    required this.hands,
    required this.normalizedJoints,
    required this.sequenceLength,
    this.modelName,
    this.inferenceLatencyMs,
    this.scores = const [],
  });

  final DateTime capturedAt;
  final List<Offset> pose;
  final List<List<Offset>> hands;
  final List<List<double>> normalizedJoints;
  final int sequenceLength;
  final String? modelName;
  final int? inferenceLatencyMs;
  final List<RecognitionScore> scores;

  RecognitionGraphFrame withInference({
    required String modelName,
    required int latencyMs,
    required List<RecognitionScore> scores,
  }) => RecognitionGraphFrame(
    capturedAt: capturedAt,
    pose: pose,
    hands: hands,
    normalizedJoints: normalizedJoints,
    sequenceLength: sequenceLength,
    modelName: modelName,
    inferenceLatencyMs: latencyMs,
    scores: scores,
  );
}
