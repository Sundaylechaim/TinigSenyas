import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinigsenyas/services/offline_english_tts_service.dart';
import 'package:tinigsenyas/services/tts_service.dart';
import 'package:tinigsenyas/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ttsChannel = MethodChannel('flutter_tts');
  const audioGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');
  const audioPlayerChannel = MethodChannel('xyz.luan/audioplayers');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('TtsService voice matching', () {
    setUpAll(() {
      messenger.setMockMethodCallHandler(
        audioGlobalChannel,
        (call) async => null,
      );
      messenger.setMockMethodCallHandler(
        audioPlayerChannel,
        (call) async => null,
      );
    });

    tearDownAll(() {
      messenger.setMockMethodCallHandler(audioGlobalChannel, null);
      messenger.setMockMethodCallHandler(audioPlayerChannel, null);
    });

    test('recognizes Filipino and Tagalog voice locales', () {
      expect(
        TtsService.voiceSupportsLanguage({
          'name': 'Filipino voice',
          'locale': 'fil-PH',
        }, 'fil-PH'),
        isTrue,
      );
      expect(
        TtsService.voiceSupportsLanguage({
          'name': 'Tagalog voice',
          'locale': 'tl_PH',
        }, 'fil-PH'),
        isTrue,
      );
      expect(
        TtsService.voiceSupportsLanguage({
          'name': 'English voice',
          'locale': 'en-PH',
        }, 'fil-PH'),
        isFalse,
      );
    });

    test('only labels female voices when the platform identifies one', () {
      expect(
        TtsService.isFemaleVoice({'gender': 'female', 'name': 'Voice A'}),
        isTrue,
      );
      expect(TtsService.isFemaleVoice({'name': 'Voice Female'}), isTrue);
      expect(TtsService.isFemaleVoice({'name': 'Google Filipino'}), isFalse);
    });

    test('maps the bundled Kokoro speakers to female English voices', () {
      expect(
        OfflineEnglishTtsService.voices.values.map((voice) => voice.speakerId),
        [0, 1, 2],
      );
      expect(
        OfflineEnglishTtsService.voices.values.every(
          (voice) => voice.label.contains('Female'),
        ),
        isTrue,
      );
    });

    test(
      'requires English when the offline English voice is selected',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService();
        await settings.init();
        await settings.setTtsSource('offline_english');

        await expectLater(
          TtsService(settings).speak('Hello'),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'requires the English US locale for the offline English voice',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService();
        await settings.init();
        await settings.setTtsLanguage('en-GB');
        await settings.setTtsSource('offline_english');

        await expectLater(
          TtsService(settings).speak('Hello'),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'does not silently switch to a device voice when online Filipino TTS fails',
      () async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
        final settings = SettingsService();
        await settings.init();
        await settings.setTtsSource('automatic');
        await settings.setTtsServer(
          url: 'https://speech.example.com',
          token: 'test-token',
        );
        final ttsCalls = <String>[];
        messenger.setMockMethodCallHandler(ttsChannel, (call) async {
          ttsCalls.add(call.method);
          return 1;
        });
        final adapter = _FailingTtsAdapter();
        final service = TtsService(
          settings,
          dio: Dio()..httpClientAdapter = adapter,
        );

        try {
          await expectLater(
            service.speak('Kumusta'),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                contains('Online Filipino speech failed'),
              ),
            ),
          );
          expect(ttsCalls, isEmpty);
          expect(adapter.authorizationHeaders, ['Bearer test-token']);
        } finally {
          await service.dispose();
          messenger.setMockMethodCallHandler(ttsChannel, null);
        }
      },
    );

    test(
      'explains how to restore the local speech service connection',
      () async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
        final settings = SettingsService();
        await settings.init();
        await settings.setTtsServer(url: 'http://127.0.0.1:5000', token: '');
        messenger.setMockMethodCallHandler(ttsChannel, (call) async => null);
        final service = TtsService(
          settings,
          dio: Dio()..httpClientAdapter = _UnavailableTtsAdapter(),
        );

        try {
          await expectLater(
            service.speak('Kumusta'),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                contains('backend is running'),
              ),
            ),
          );
        } finally {
          await service.dispose();
          messenger.setMockMethodCallHandler(ttsChannel, null);
        }
      },
    );

    test(
      'explains how to fix missing Filipino device voice in automatic mode',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService();
        await settings.init();
        messenger.setMockMethodCallHandler(ttsChannel, (call) async {
          if (call.method == 'getVoices') {
            return [
              {'name': 'English voice', 'locale': 'en-US'},
            ];
          }
          return 1;
        });
        final service = TtsService(settings);

        try {
          await expectLater(
            service.speak('Kumusta'),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('No Filipino voice is available'),
                  contains('online Filipino TTS server'),
                ),
              ),
            ),
          );
        } finally {
          await service.dispose();
          messenger.setMockMethodCallHandler(ttsChannel, null);
        }
      },
    );

    test(
      'saves selected language when no matching device voice is installed',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService();
        await settings.init();
        await settings.setTtsVoice(const {
          'name': 'English voice',
          'locale': 'en-US',
        });
        final calls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ttsChannel, (call) async {
              calls.add(call.method);
              if (call.method == 'getVoices') {
                return [
                  {'name': 'English voice', 'locale': 'en-US'},
                ];
              }
              return 1;
            });

        try {
          await TtsService(settings).setLanguage('fil-PH');

          expect(settings.ttsLanguage, 'fil-PH');
          expect(settings.ttsVoice, isNull);
          expect(calls, contains('stop'));
          expect(calls, isNot(contains('setLanguage')));
        } finally {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(ttsChannel, null);
        }
      },
    );
  });
}

class _FailingTtsAdapter implements HttpClientAdapter {
  final authorizationHeaders = <String?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authorizationHeaders.add(options.headers['Authorization']?.toString());
    return ResponseBody.fromString(
      '{"error":"TTS test failure"}',
      503,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _UnavailableTtsAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
    );
  }

  @override
  void close({bool force = false}) {}
}
