import 'dart:async';
import 'package:camera/camera.dart';
import 'package:tinigsenyas/models/sign_result.dart';

abstract class RecognitionService {
  bool get isModelReady;
  Future<void> initialize();
  Future<void> start();
  Future<void> stop();
  Future<void> processFrame(CameraImage image);
  Stream<SignResult> get predictions;
  Stream<bool>? get pauseStatus;
  bool get isPaused;
  void dispose();
}
