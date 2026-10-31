import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import '../models/sign_result.dart';
import '../services/recognition/recognition_service.dart';
import '../services/recognition/mock_recognition_service.dart';
import '../services/recognition/tflite_recognition_service.dart';
import '../services/recognition/backend_recognition_service.dart';

RecognitionService createRecognitionService({bool useMock = false}) {
  if (useMock) return MockRecognitionService();
  // On web or desktop, connect to the high-performance ST-GCN backend service
  if (kIsWeb) return BackendRecognitionService();
  return TfliteRecognitionService();
}

class RecognitionProvider extends ChangeNotifier {
  RecognitionProvider({bool useMock = false})
    : _service = createRecognitionService(useMock: useMock);

  final RecognitionService _service;
  RecognitionService get service => _service;
  bool get isModelReady => _service.isModelReady;

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
