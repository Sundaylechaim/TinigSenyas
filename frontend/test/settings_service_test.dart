import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinigsenyas/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService TTS voice preference', () {
    late SettingsService settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      settings = SettingsService();
      await settings.init();
    });

    test('stores selected voice details', () async {
      const voice = {
        'name': 'Female voice',
        'locale': 'en-US',
        'identifier': 'en-US-female',
      };

      await settings.setTtsVoice(voice);

      expect(settings.ttsVoice, voice);
    });

    test('clears voice preference to use system default', () async {
      await settings.setTtsVoice(const {
        'name': 'Female voice',
        'locale': 'en-US',
      });

      await settings.setTtsVoice(null);

      expect(settings.ttsVoice, isNull);
    });

    test('defaults to Filipino speech', () {
      expect(settings.ttsLanguage, 'fil-PH');
    });

    test('defaults to light theme', () {
      expect(settings.themeMode, ThemeMode.light);
    });

    test('migrates the previous English default to Filipino', () async {
      SharedPreferences.setMockInitialValues({'tts_language': 'en-PH'});
      settings = SettingsService();
      await settings.init();

      expect(settings.ttsLanguage, 'fil-PH');
    });

    test(
      'preserves an explicitly selected language during migration',
      () async {
        SharedPreferences.setMockInitialValues({'tts_language': 'en-US'});
        settings = SettingsService();
        await settings.init();

        expect(settings.ttsLanguage, 'en-US');
      },
    );

    test('does not rewrite English after the migration has run', () async {
      SharedPreferences.setMockInitialValues({
        'tts_language': 'en-PH',
        'tts_language_migrated': true,
      });
      settings = SettingsService();
      await settings.init();

      expect(settings.ttsLanguage, 'en-PH');
    });

    test('persists TTS source and online server configuration', () async {
      await settings.setTtsSource('online');
      await settings.setTtsServer(
        url: 'https://speech.example.com/',
        token: 'test-access-token',
      );

      expect(settings.ttsSource, 'online');
      expect(settings.ttsServerUrl, 'https://speech.example.com');
      expect(await settings.getTtsServerToken(), 'test-access-token');
    });

    test('does not require an online server for non-web defaults', () {
      expect(settings.ttsServerUrl, isEmpty);
    });

    test('rejects unsupported sources and invalid server URLs', () async {
      await expectLater(settings.setTtsSource('unknown'), throwsArgumentError);
      await expectLater(
        settings.setTtsServer(url: 'not a URL', token: ''),
        throwsArgumentError,
      );
      await expectLater(
        settings.setTtsServer(url: 'http://example.com', token: 'token'),
        throwsArgumentError,
      );
    });

    test('persists online Filipino voice selection', () async {
      await settings.setTtsOnlineVoice('fil-PH-AngeloNeural');

      expect(settings.ttsOnlineVoice, 'fil-PH-AngeloNeural');
    });

    test(
      'persists the offline English voice source and voice choice',
      () async {
        await settings.setTtsSource('offline_english');
        await settings.setTtsOfflineEnglishVoice('af_sol');

        expect(settings.ttsSource, 'offline_english');
        expect(settings.ttsOfflineEnglishVoice, 'af_sol');
      },
    );

    test('rejects unknown offline English voices', () async {
      await expectLater(
        settings.setTtsOfflineEnglishVoice('unknown'),
        throwsArgumentError,
      );
    });

    test('defaults keepScreenAwake to true and persists user preference', () async {
      expect(settings.keepScreenAwake, isTrue);
      await settings.setKeepScreenAwake(false);
      expect(settings.keepScreenAwake, isFalse);
      await settings.setKeepScreenAwake(true);
      expect(settings.keepScreenAwake, isTrue);
    });
  });
}
