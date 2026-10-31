import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinigsenyas/services/recognition/backend_recognition_service.dart';
import 'package:tinigsenyas/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('publishes live hand-detection and frame-collection status', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    final settings = SettingsService();
    await settings.init();
    await settings.setTtsServer(url: 'http://127.0.0.1:5000', token: '');
    final dio = Dio()..httpClientAdapter = _RecognitionAdapter();
    final service = BackendRecognitionService(settings: settings, dio: dio);

    await service.initialize();
    await service.start();
    final progressFuture = service.progress.first;
    await service.processJpegFrame(Uint8List.fromList([1, 2, 3]));
    final progress = await progressFuture;

    expect(progress.status, 'collecting');
    expect(progress.framesCollected, 17);
    expect(progress.sequenceLength, 60);
    expect(progress.handLandmarks, hasLength(1));
    expect(progress.handLandmarks.single, hasLength(21));
    expect(progress.frameWidth, 640);
    expect(progress.frameHeight, 480);

    await service.stop();
    service.dispose();
  });
}

class _RecognitionAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      return _jsonResponse(options, {
        'ready': true,
        'sequence_length': 60,
        'class_count': 127,
      });
    }
    if (options.method == 'POST') {
      return _jsonResponse(options, {
        'status': 'collecting',
        'frames_collected': 17,
        'label': null,
        'confidence': null,
        'hand_landmarks': [
          List.generate(21, (index) => [index / 20, index / 20]),
        ],
        'frame_width': 640,
        'frame_height': 480,
      });
    }
    return ResponseBody.fromString('', 204);
  }

  ResponseBody _jsonResponse(
    RequestOptions options,
    Map<String, Object?> data,
  ) {
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
