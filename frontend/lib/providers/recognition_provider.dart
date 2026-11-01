import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import '../models/sign_result.dart';
import '../services/recognition/recognition_service.dart';
import '../services/recognition/tflite_recognition_service.dart';
import '../services/recognition/backend_recognition_service.dart';
import '../services/settings_service.dart';

RecognitionService createRecognitionService({SettingsService? settings}) {
  // On web or desktop, connect to the high-performance ST-GCN backend service
  if (kIsWeb) return BackendRecognitionService(settings: settings);
  return TfliteRecognitionService();
}

class RecognitionProvider extends ChangeNotifier {
  RecognitionProvider({SettingsService? settings})
    : _service = createRecognitionService(settings: settings);

  final RecognitionService _service;
  RecognitionService get service => _service;
  bool get isModelReady => _service.isModelReady;
  bool get isPaused => _service.isPaused;
  Stream<bool>? get pauseStatus => _service.pauseStatus;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  Future<void> initialize() async {
    if (_isInitialized) return;
    await _service.initialize();
    _isInitialized = true;
    notifyListeners();
  }

  Future<void> start() async {
    await _service.start();
  }

  Future<void> stop() async {
    await _service.stop();
  }

  Future<void> processFrame(CameraImage image) async {
    await _service.processFrame(image);
  }

  Stream<SignResult> get predictions => _service.predictions;

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }
}
