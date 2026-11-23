import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinigsenyas/config/app_version.dart';
import 'package:tinigsenyas/services/model_updater.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uses the v1.0.0 app identity and monotonic build number', () {
    expect(AppVersion.name, '1.0.0');
    expect(AppVersion.buildNumber, 2019);
    expect(ModelUpdater.currentAppVersion, AppVersion.name);
    expect(ModelUpdater.currentAppBuild, AppVersion.buildNumber);
  });

  test(
    'accepts a complete HTTPS model and label set with compatible app version',
    () async {
      SharedPreferences.setMockInitialValues({'model_version': '1.3.0'});
      final dio = Dio()
        ..httpClientAdapter = _ManifestAdapter({
          'version': '1.3.1',
          'min_app_version': '1.2.16',
          'min_app_build': 2019,
          'models': _validModelEntries(),
        });

      final updater = ModelUpdater(
        dio: dio,
        remoteManifestUrl: 'https://example.com/manifest.json',
      );
      final info = await updater.checkForUpdates();

      expect(info.status, UpdateStatus.updateAvailable);
      expect(info.version, '1.3.1');
      expect(info.models, hasLength(6));
    },
  );

  test('rejects a newer manifest that omits model or label files', () async {
    SharedPreferences.setMockInitialValues({'model_version': '1.3.0'});
    final dio = Dio()
      ..httpClientAdapter = _ManifestAdapter({
        'version': '1.3.1',
        'min_app_version': '1.2.16',
        'min_app_build': 2019,
        'models': [
          {
            'name': 'fsl_model.tflite',
            'url': 'https://example.com/fsl_model.tflite',
            'sha256': _validSha256,
          },
        ],
      });

    final updater = ModelUpdater(
      dio: dio,
      remoteManifestUrl: 'https://example.com/manifest.json',
    );
    final info = await updater.checkForUpdates();

    expect(info.status, UpdateStatus.error);
    expect(info.errorMessage, contains('all six model and label files'));
  });

  test(
    'rejects a newer manifest with a missing checksum or insecure URL',
    () async {
      SharedPreferences.setMockInitialValues({'model_version': '1.3.0'});
      final models = _validModelEntries();
      models[0] = {
        ...models[0],
        'url': 'http://example.com/fsl_model.tflite',
        'sha256': '',
      };
      final dio = Dio()
        ..httpClientAdapter = _ManifestAdapter({
          'version': '1.3.1',
          'min_app_version': '1.2.16',
          'min_app_build': 2019,
          'models': models,
        });

      final updater = ModelUpdater(
        dio: dio,
        remoteManifestUrl: 'https://example.com/manifest.json',
      );
      final info = await updater.checkForUpdates();

      expect(info.status, UpdateStatus.error);
    },
  );

  test('rejects model update requiring a newer app version', () async {
    SharedPreferences.setMockInitialValues({'model_version': '1.3.0'});
    final dio = Dio()
      ..httpClientAdapter = _ManifestAdapter({
        'version': '2.0.0',
        'min_app_version': '9.9.0',
        'models': _validModelEntries(),
      });

    final updater = ModelUpdater(
      dio: dio,
      remoteManifestUrl: 'https://example.com/manifest.json',
    );
    final info = await updater.checkForUpdates();

    expect(info.status, UpdateStatus.upToDate);
  });

  test('rejects model update requiring a newer app build', () async {
    SharedPreferences.setMockInitialValues({'model_version': '1.3.0'});
    final dio = Dio()
      ..httpClientAdapter = _ManifestAdapter({
        'version': '2.0.0',
        'min_app_version': '1.0.0',
        'min_app_build': 2020,
        'models': _validModelEntries(),
      });

    final updater = ModelUpdater(
      dio: dio,
      remoteManifestUrl: 'https://example.com/manifest.json',
    );
    final info = await updater.checkForUpdates();

    expect(info.status, UpdateStatus.upToDate);
  });

  test(
    'reports the newer bundled version without rewriting cached OTA state',
    () async {
      SharedPreferences.setMockInitialValues({'model_version': '1.2.2'});
      final dio = Dio()
        ..httpClientAdapter = _ManifestAdapter({
          'version': '1.2.2',
          'min_app_version': '1.0.0',
          'models': _validModelEntries(),
        });

      final updater = ModelUpdater(
        dio: dio,
        remoteManifestUrl: 'https://example.com/manifest.json',
      );
      final info = await updater.checkForUpdates();
      final preferences = await SharedPreferences.getInstance();

      expect(info.currentVersion, '1.3.0');
      expect(info.status, UpdateStatus.upToDate);
      expect(preferences.getString('model_version'), '1.2.2');
    },
  );
}

const _validSha256 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

List<Map<String, Object?>> _validModelEntries() => [
  for (final name in const [
    'fsl_model.tflite',
    'fsl_alphabet.tflite',
    'fsl_medical.tflite',
    'labels.txt',
    'medical_labels.txt',
    'alphabet_labels.txt',
  ])
    {'name': name, 'url': 'https://example.com/$name', 'sha256': _validSha256},
];

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
