import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:tinigsenyas/models/sign_result.dart';

enum RecognitionMode {
  auto,
  alphabet,
  phrases,
}

abstract class RecognitionService {
  bool get isModelReady;
  RecognitionMode get mode => RecognitionMode.auto;
  set mode(RecognitionMode value) {}
  Future<void> initialize();
  Future<void> start();
  Future<void> stop();
  Future<void> processFrame(
    CameraImage image, {
    int? sensorOrientation,
    bool? isFrontCamera,
  });
  Stream<SignResult> get predictions;
  Stream<bool>? get pauseStatus;
  Stream<List<List<Offset>>>? get landmarkPointsStream;
  bool get isPaused;
  void setPaused(bool value);
  Future<void> reloadModels();
  void dispose();
}
