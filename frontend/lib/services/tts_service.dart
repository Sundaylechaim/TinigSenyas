import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' show GeneratedAudio;
import 'settings_service.dart';
import 'offline_english_tts_service.dart';

class TtsService {
  static const _nativeChannel = MethodChannel('tinigsenyas/tts');

  final SettingsService _settings;
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final OfflineEnglishTtsService _offlineEnglishTts =
      OfflineEnglishTtsService();
  final Dio _dio;
  bool _isInitialized = false;

  TtsService(this._settings, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 45),
              sendTimeout: const Duration(seconds: 10),
            ),
          );

  Future<void> initialize() async {
    if (_isInitialized) return;
    final voices = await getAvailableVoices();
    final matchingVoices = _voicesForLanguage(voices, _settings.ttsLanguage);
    if (matchingVoices.isEmpty) {
      throw StateError(
        'No ${_languageName(_settings.ttsLanguage)} speech voice is installed. '
        'Install speech data for this language in your device or browser settings.',
      );
    }

    final savedVoice = _settings.ttsVoice;
    final voice =
        savedVoice != null &&
            matchingVoices.any(
              (candidate) => _voiceKey(candidate) == _voiceKey(savedVoice),
            )
        ? matchingVoices.firstWhere(
            (candidate) => _voiceKey(candidate) == _voiceKey(savedVoice),
          )
        : _preferredVoice(matchingVoices);

    await _applyVoice(_settings.ttsLanguage, voice);
    await _settings.setTtsVoice(voice);
  }

  Future<List<Map<String, String>>> getAvailableVoices() async {
    dynamic voices;
    for (var attempt = 0; attempt < 5; attempt++) {
      voices = await _tts.getVoices;
      if (voices is List && voices.isNotEmpty) break;
      if (attempt < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    if (voices is! List) {
      throw StateError('The device returned an invalid voice list.');
    }
    return voices.map((voice) {
      if (voice is! Map) {
        throw StateError('The device returned an invalid voice entry.');
      }
      return voice.map<String, String>(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }).toList();
  }

  Future<void> setVoice(Map<String, String>? voice) async {
    final matchingVoices = _voicesForLanguage(
      await getAvailableVoices(),
      _settings.ttsLanguage,
    );
    if (matchingVoices.isEmpty) {
      throw StateError(
        'No ${_languageName(_settings.ttsLanguage)} speech voice is installed. '
        'Install speech data for this language in your device or browser settings.',
      );
    }
    final selectedVoice = voice == null
        ? _preferredVoice(matchingVoices)
        : matchingVoices.firstWhere(
            (candidate) => _voiceKey(candidate) == _voiceKey(voice),
            orElse: () => throw ArgumentError(
              'The selected voice does not support ${_languageName(_settings.ttsLanguage)}.',
            ),
          );
    await _applyVoice(_settings.ttsLanguage, selectedVoice);
    await _settings.setTtsVoice(selectedVoice);
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (_settings.ttsSource == 'offline_english') {
      if (_settings.ttsLanguage.toLowerCase() != 'en-us') {
        throw StateError(
          'Select English (US) to use the offline English female voice.',
        );
      }
      await _speakOfflineEnglish(text);
      return;
    }
    final useOnline =
        _settings.ttsSource == 'online' ||
        (_settings.ttsSource == 'automatic' &&
            _settings.ttsServerUrl.isNotEmpty);
    if (useOnline) {
      try {
        await _speakOnline(text);
        return;
      } catch (error) {
        if (_settings.ttsSource == 'online') rethrow;
        if (_isFilipinoLanguage(_settings.ttsLanguage)) {
          throw StateError(
            'Online Filipino speech failed ($error). Check the online TTS '
            'server in Settings, or choose Offline to use the device voice.',
          );
        }
        try {
          await _speakDevice(text);
          return;
        } catch (offlineError) {
          throw StateError(
            'Online TTS failed ($error), and offline playback is unavailable '
            '($offlineError).',
          );
        }
      }
    }
    try {
      await _speakDevice(text);
    } catch (error) {
      if (_settings.ttsSource == 'automatic' &&
          _isFilipinoLanguage(_settings.ttsLanguage)) {
        throw StateError(
          'No Filipino voice is available from the device. Configure the '
          'online Filipino TTS server in Settings, or install Filipino speech '
          'data in the device/browser. Details: $error',
        );
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    await _audioPlayer.stop();
    await _tts.stop();
  }

  Future<bool> isOfflineEnglishVoiceInstalled() =>
      _offlineEnglishTts.isInstalled();

  Future<void> installOfflineEnglishVoice({
    required void Function(int received, int total) onProgress,
  }) => _offlineEnglishTts.install(onProgress: onProgress);

  Future<void> openOfflineVoiceSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError(
        'Android voice-data installation is only available in the Android app.',
      );
    }
    await _nativeChannel.invokeMethod<void>('installVoiceData');
  }

  Future<void> setLanguage(String language) async {
    await _settings.setTtsLanguage(language);
    final matchingVoices = _voicesForLanguage(
      await getAvailableVoices(),
      language,
    );
    if (matchingVoices.isEmpty) {
      await _tts.stop();
      await _settings.setTtsVoice(null);
      _isInitialized = false;
      return;
    }
    final currentVoice = _settings.ttsVoice;
    final selectedVoice =
        currentVoice != null &&
            matchingVoices.any(
              (candidate) => _voiceKey(candidate) == _voiceKey(currentVoice),
            )
        ? matchingVoices.firstWhere(
            (candidate) => _voiceKey(candidate) == _voiceKey(currentVoice),
          )
        : _preferredVoice(matchingVoices);
    await _applyVoice(language, selectedVoice);
    await _settings.setTtsVoice(selectedVoice);
  }

  Future<void> setRate(double rate) async {
    await _settings.setTtsRate(rate);
    if (_isInitialized) await _tts.setSpeechRate(rate);
  }

  Future<void> dispose() async {
    _offlineEnglishTts.dispose();
    await _audioPlayer.dispose();
    await _tts.stop();
  }

  Future<void> _speakDevice(String text) async {
    if (!_isInitialized) await initialize();
    await _tts.speak(text);
  }

  Future<void> _speakOnline(String text) async {
    final serverUrl = _settings.ttsServerUrl;
    final token = await _settings.getTtsServerToken();
    if (serverUrl.isEmpty) {
      throw StateError(
        'The online speech service is unavailable. Check the server setup.',
      );
    }
    if (!_settings.ttsLanguage.toLowerCase().startsWith('fil')) {
      throw StateError(
        'Online neural TTS currently supports Filipino only. Select Filipino '
        'or choose automatic/offline voice mode.',
      );
    }

    late final Response<List<int>> response;
    try {
      response = await _dio.post<List<int>>(
        '$serverUrl/tts/synthesize',
        data: {
          'text': text,
          'voice': _settings.ttsOnlineVoice,
          'rate': ((_settings.ttsRate - 0.5) * 100).round(),
        },
        options: Options(
          responseType: ResponseType.bytes,
          headers: {if (token.isNotEmpty) 'Authorization': 'Bearer $token'},
        ),
      );
    } on DioException catch (error) {
      final responseBody = error.response?.data;
      final body = responseBody is List<int>
          ? utf8.decode(responseBody, allowMalformed: true)
          : responseBody?.toString();
      String? message;
      if (body != null) {
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map && decoded['error'] is String) {
            message = decoded['error'] as String;
          }
        } on FormatException {
          message = null;
        }
      }
      final statusCode = error.response?.statusCode;
      if (statusCode == null && _isLoopbackUrl(serverUrl)) {
        throw StateError(
          'Cannot reach the local Filipino speech service. Check that the '
          'backend is running and the configured address is reachable.',
        );
      }
      throw StateError(
        message ??
            'Online speech request failed${statusCode == null ? '' : ' (HTTP $statusCode)'}.',
      );
    }
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw StateError('The online TTS server returned empty audio.');
    }
    final playbackComplete = _audioPlayer.onPlayerComplete.first;
    await _audioPlayer.play(
      BytesSource(Uint8List.fromList(bytes), mimeType: 'audio/mpeg'),
    );
    await playbackComplete;
  }

  Future<void> _speakOfflineEnglish(String text) async {
    await _offlineEnglishTts.initialize();
    final audio = _offlineEnglishTts.generate(
      text: text,
      voice: _settings.ttsOfflineEnglishVoice,
      speed: 1.0 + _settings.ttsRate - 0.5,
    );
    if (audio.samples.isEmpty || audio.sampleRate <= 0) {
      throw StateError('The offline English voice returned empty audio.');
    }
    final playbackComplete = _audioPlayer.onPlayerComplete.first;
    await _audioPlayer.play(
      BytesSource(_encodeWave(audio), mimeType: 'audio/wav'),
    );
    await playbackComplete;
  }

  static Uint8List _encodeWave(GeneratedAudio audio) {
    const bytesPerSample = 2;
    final dataLength = audio.samples.length * bytesPerSample;
    final bytes = ByteData(44 + dataLength);
    bytes
      ..setUint32(0, 0x46464952, Endian.little)
      ..setUint32(4, 36 + dataLength, Endian.little)
      ..setUint32(8, 0x45564157, Endian.little)
      ..setUint32(12, 0x20746d66, Endian.little)
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, audio.sampleRate, Endian.little)
      ..setUint32(28, audio.sampleRate * bytesPerSample, Endian.little)
      ..setUint16(32, bytesPerSample, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(36, 0x61746164, Endian.little)
      ..setUint32(40, dataLength, Endian.little);
    for (var index = 0; index < audio.samples.length; index++) {
      final sample = (audio.samples[index].clamp(-1.0, 1.0) * 32767).round();
      bytes.setInt16(44 + index * bytesPerSample, sample, Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  Future<void> _applyVoice(String language, Map<String, String> voice) async {
    await _tts.setLanguage(language);
    await _tts.setVoice(voice);
    await _tts.setSpeechRate(_settings.ttsRate);
    await _tts.awaitSpeakCompletion(true);
    _isInitialized = true;
  }

  static bool isFemaleVoice(Map<String, String> voice) {
    final gender = voice['gender']?.toLowerCase();
    final identifiers = '${voice['name'] ?? ''} ${voice['identifier'] ?? ''}'
        .toLowerCase();
    return gender == 'female' ||
        RegExp(r'\b(female|woman|feminine)\b').hasMatch(identifiers);
  }

  static bool voiceSupportsLanguage(
    Map<String, String> voice,
    String language,
  ) {
    final voiceLocale = (voice['locale'] ?? '').toLowerCase().replaceAll(
      '_',
      '-',
    );
    final languageCode = language.split('-').first.toLowerCase();
    final aliases = languageCode == 'fil' ? {'fil', 'tl'} : {languageCode};
    return aliases.any(
      (code) => voiceLocale == code || voiceLocale.startsWith('$code-'),
    );
  }

  static List<Map<String, String>> _voicesForLanguage(
    List<Map<String, String>> voices,
    String language,
  ) {
    return voices
        .where((voice) => voiceSupportsLanguage(voice, language))
        .toList();
  }

  static Map<String, String> _preferredVoice(List<Map<String, String>> voices) {
    return voices.firstWhere(isFemaleVoice, orElse: () => voices.first);
  }

  static String _voiceKey(Map<String, String> voice) =>
      '${voice['locale'] ?? ''}|${voice['name'] ?? ''}|${voice['identifier'] ?? ''}';

  static String _languageName(String language) =>
      language.toLowerCase().startsWith('fil') ||
          language.toLowerCase().startsWith('tl')
      ? 'Filipino'
      : language;

  static bool _isFilipinoLanguage(String language) =>
      language.toLowerCase().startsWith('fil') ||
      language.toLowerCase().startsWith('tl');

  static bool _isLoopbackUrl(String url) =>
      const {'localhost', '127.0.0.1', '::1'}.contains(Uri.tryParse(url)?.host);
}
