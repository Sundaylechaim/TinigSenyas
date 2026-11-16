import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinigsenyas/services/model_updater.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('accepts valid HTTPS manifest with SHA-256 and compatible app version', () async {
    SharedPreferences.setMockInitialValues({'model_version': '1.2.0'});
    final dio = Dio()
      ..httpClientAdapter = _ManifestAdapter({
        'version': '1.2.1',
        'min_app_version': '1.2.0',
        'models': [
          {
            'name': 'fsl_model.tflite',
            'url': 'https://example.com/fsl_model.tflite',
            'sha256': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          },
        ],
      });

    final updater = ModelUpdater(
      dio: dio,
      remoteManifestUrl: 'https://example.com/manifest.json',
    );
    final info = await updater.checkForUpdates();

    expect(info.status, UpdateStatus.updateAvailable);
    expect(info.version, '1.2.1');
  });

  test('rejects manifest missing SHA-256 or using insecure non-loopback HTTP', () async {
    SharedPreferences.setMockInitialValues({'model_version': '1.2.0'});
    final dio = Dio()
      ..httpClientAdapter = _ManifestAdapter({
        'version': '1.2.5',
        'min_app_version': '1.0.0',
        'models': [
          {
            'name': 'fsl_model.tflite',
            'url': 'http://example.com/fsl_model.tflite',
            'sha256': '',
          },
        ],
      });

    final updater = ModelUpdater(
      dio: dio,
      remoteManifestUrl: 'https://example.com/manifest.json',
    );
    final info = await updater.checkForUpdates();

    expect(info.status, UpdateStatus.upToDate);
  });

  test('rejects model update requiring a newer app version', () async {
    SharedPreferences.setMockInitialValues({'model_version': '1.2.0'});
    final dio = Dio()
      ..httpClientAdapter = _ManifestAdapter({
        'version': '2.0.0',
        'min_app_version': '9.9.0',
        'models': [
          {
            'name': 'fsl_model.tflite',
            'url': 'https://example.com/fsl_model.tflite',
            'sha256': 'abc123',
          },
        ],
      });

    final updater = ModelUpdater(
      dio: dio,
      remoteManifestUrl: 'https://example.com/manifest.json',
    );
    final info = await updater.checkForUpdates();

    expect(info.status, UpdateStatus.upToDate);
  });
}

class _ManifestAdapter implements HttpClientAdapter {
  _ManifestAdapter(this.payload);
  final Map<String, Object?> payload;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

