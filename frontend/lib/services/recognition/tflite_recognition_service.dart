import 'dart:async';
import 'package:camera/camera.dart';
import 'package:tinigsenyas/models/sign_result.dart';
import 'recognition_service.dart';

class TfliteRecognitionService implements RecognitionService {
  final _predictionsController = StreamController<SignResult>.broadcast();
  bool _isInitialized = false;
  bool _isRunning = false;

  @override
  bool get isModelReady => _isInitialized;

  @override
  bool get isPaused => false;

  @override
  Stream<bool>? get pauseStatus => null;

  @override
  Future<void> initialize() async {
    _isInitialized = true;
  }

  @override
  Future<void> start() async {
    if (!_isInitialized) {
      throw StateError(
        'Recognition service must be initialized before starting.',
      );
    }
    _isRunning = true;
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
  }

  @override
  Future<void> processFrame(CameraImage image) async {
    if (!_isInitialized) {
      throw StateError(
        'Recognition service must be initialized before processing frames.',
      );
    }
    if (!_isRunning || !isModelReady) return;
  }

  @override
  Stream<SignResult> get predictions => _predictionsController.stream;

  @override
  void dispose() {
    _isRunning = false;
    _isInitialized = false;
    _predictionsController.close();
  }
}
