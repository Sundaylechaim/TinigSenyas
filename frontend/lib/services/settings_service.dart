import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static const _secureStorage = FlutterSecureStorage();
  static const _themeModeKey = 'theme_mode';
  static const _textScaleKey = 'text_scale';
  static const _modelVersionKey = 'model_version';
  static const _autoUpdateKey = 'auto_update';
  static const _ttsLanguageKey = 'tts_language';
  static const _ttsRateKey = 'tts_rate';
  static const _ttsVoiceNameKey = 'tts_voice_name';
  static const _ttsVoiceLocaleKey = 'tts_voice_locale';
  static const _ttsVoiceIdentifierKey = 'tts_voice_identifier';
  static const _ttsLanguageMigrationKey = 'tts_language_migrated';
  static const _ttsSourceKey = 'tts_source';
  static const _ttsServerUrlKey = 'tts_server_url';
  static const _ttsServerTokenKey = 'tts_server_token';
  static const _ttsOnlineVoiceKey = 'tts_online_voice';
  static const _ttsOfflineEnglishVoiceKey = 'tts_offline_english_voice';
  static const _ageVerificationKey = 'age_verification_status';
  static const _cipaRecordingConsentKey = 'cipa_recording_consent';
  static const _saveHistoryEnabledKey = 'save_history_enabled';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    if (!(_prefs!.getBool(_ttsLanguageMigrationKey) ?? false)) {
      if (_prefs!.getString(_ttsLanguageKey) == 'en-PH') {
        await _prefs!.setString(_ttsLanguageKey, 'fil-PH');
      }
      await _prefs!.setBool(_ttsLanguageMigrationKey, true);
    }
  }

  // Theme
  ThemeMode get themeMode {
    final index = _prefs?.getInt(_themeModeKey) ?? ThemeMode.light.index;
    return ThemeMode.values[index];
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs?.setInt(_themeModeKey, mode.index);
  }

  // Text Scale
  double get textScaleFactor {
    return _prefs?.getDouble(_textScaleKey) ?? 1.0;
  }

  Future<void> setTextScaleFactor(double scale) async {
    final boundedScale = scale.clamp(0.8, 1.4);
    await _prefs?.setDouble(_textScaleKey, boundedScale);
    notifyListeners();
  }

  // Model Version
  String get modelVersion {
    final savedVersion = _prefs?.getString(_modelVersionKey);
    return (savedVersion == null || savedVersion.isEmpty)
        ? 'Not installed'
        : savedVersion;
  }

  Future<void> setModelVersion(String version) async {
    await _prefs?.setString(_modelVersionKey, version);
  }

  // Auto Update
  bool get autoUpdateEnabled {
    return _prefs?.getBool(_autoUpdateKey) ?? true;
  }

  Future<void> setAutoUpdateEnabled(bool enabled) async {
    await _prefs?.setBool(_autoUpdateKey, enabled);
  }

  // TTS Settings
  String get ttsLanguage {
    return _prefs?.getString(_ttsLanguageKey) ?? 'fil-PH';
  }

  Future<void> setTtsLanguage(String language) async {
    await _prefs?.setString(_ttsLanguageKey, language);
  }

  String get ttsSource => _prefs?.getString(_ttsSourceKey) ?? 'automatic';

  Future<void> setTtsSource(String source) async {
    if (!const {
      'automatic',
      'offline',
      'online',
      'offline_english',
    }.contains(source)) {
      throw ArgumentError.value(source, 'source', 'Unsupported TTS source.');
    }
    await _prefs?.setString(_ttsSourceKey, source);
  }

  String get ttsServerUrl {
    final savedUrl = _prefs?.getString(_ttsServerUrlKey);
    if (savedUrl != null && savedUrl.isNotEmpty) return savedUrl;
    if (!kIsWeb) return '';

    final uri = Uri.base;
    if (const {'localhost', '127.0.0.1', '::1'}.contains(uri.host)) {
      return 'http://127.0.0.1:5000';
    }
    return uri.origin;
  }

  Future<String> getTtsServerToken() async =>
      await _secureStorage.read(key: _ttsServerTokenKey) ?? '';

  Future<void> setTtsServer({
    required String url,
    required String token,
  }) async {
    final normalizedUrl = url.trim().replaceFirst(RegExp(r'/+$'), '');
    if (normalizedUrl.isNotEmpty) {
      final parsedUrl = Uri.tryParse(normalizedUrl);
      if (parsedUrl == null ||
          !parsedUrl.hasScheme ||
          parsedUrl.host.isEmpty ||
          parsedUrl.userInfo.isNotEmpty ||
          parsedUrl.hasQuery ||
          parsedUrl.hasFragment ||
          !const {'http', 'https'}.contains(parsedUrl.scheme)) {
        throw ArgumentError.value(
          url,
          'url',
          'Enter a valid HTTP(S) server URL.',
        );
      }
    }
    await _prefs?.setString(_ttsServerUrlKey, normalizedUrl);
    final normalizedToken = token.trim();
    if (normalizedToken.isEmpty) {
      await _secureStorage.delete(key: _ttsServerTokenKey);
    } else {
      await _secureStorage.write(
        key: _ttsServerTokenKey,
        value: normalizedToken,
      );
    }
  }

  String get ttsOnlineVoice =>
      _prefs?.getString(_ttsOnlineVoiceKey) ?? 'fil-PH-BlessicaNeural';

  Future<void> setTtsOnlineVoice(String voice) async {
    if (!const {
      'fil-PH-BlessicaNeural',
      'fil-PH-AngeloNeural',
    }.contains(voice)) {
      throw ArgumentError.value(
        voice,
        'voice',
        'Unsupported online TTS voice.',
      );
    }
    await _prefs?.setString(_ttsOnlineVoiceKey, voice);
  }

  String get ttsOfflineEnglishVoice =>
      _prefs?.getString(_ttsOfflineEnglishVoiceKey) ?? 'af_maple';

  Future<void> setTtsOfflineEnglishVoice(String voice) async {
    if (!const {'af_maple', 'af_sol', 'bf_vale'}.contains(voice)) {
      throw ArgumentError.value(
        voice,
        'voice',
        'Unsupported offline English voice.',
      );
    }
    await _prefs?.setString(_ttsOfflineEnglishVoiceKey, voice);
  }

  double get ttsRate {
    return _prefs?.getDouble(_ttsRateKey) ?? 0.5;
  }

  Future<void> setTtsRate(double rate) async {
    await _prefs?.setDouble(_ttsRateKey, rate.clamp(0.3, 0.8));
  }

  Map<String, String>? get ttsVoice {
    final name = _prefs?.getString(_ttsVoiceNameKey);
    final locale = _prefs?.getString(_ttsVoiceLocaleKey);
    if (name == null || locale == null) return null;
    return {
      'name': name,
      'locale': locale,
      if (_prefs?.getString(_ttsVoiceIdentifierKey)
          case final String identifier)
        'identifier': identifier,
    };
  }

  Future<void> setTtsVoice(Map<String, String>? voice) async {
    if (voice == null) {
      await _prefs?.remove(_ttsVoiceNameKey);
      await _prefs?.remove(_ttsVoiceLocaleKey);
      await _prefs?.remove(_ttsVoiceIdentifierKey);
      return;
    }
    final name = voice['name'];
    final locale = voice['locale'];
    if (name == null || locale == null) {
      throw ArgumentError('A voice must include its name and locale.');
    }
    await _prefs?.setString(_ttsVoiceNameKey, name);
    await _prefs?.setString(_ttsVoiceLocaleKey, locale);
    final identifier = voice['identifier'];
    if (identifier == null) {
      await _prefs?.remove(_ttsVoiceIdentifierKey);
    } else {
      await _prefs?.setString(_ttsVoiceIdentifierKey, identifier);
    }
  }

  // COPPA Compliance: Age verification (null = not answered, true = 13+, false = under 13)
  bool? get isOver13 => _prefs?.getBool(_ageVerificationKey);

  Future<void> setAgeStatus(bool isOver13) async {
    await _prefs?.setBool(_ageVerificationKey, isOver13);
    notifyListeners();
  }

  // CIPA Compliance: Affirmative audio/visual recording consent
  bool get hasRecordingConsent =>
      _prefs?.getBool(_cipaRecordingConsentKey) ?? false;

  Future<void> setRecordingConsent(bool consent) async {
    await _prefs?.setBool(_cipaRecordingConsentKey, consent);
    notifyListeners();
  }

  // Privacy: Toggle local conversation persistence in SQLite
  bool get saveHistoryEnabled =>
      _prefs?.getBool(_saveHistoryEnabledKey) ?? true;

  Future<void> setSaveHistoryEnabled(bool enabled) async {
    await _prefs?.setBool(_saveHistoryEnabledKey, enabled);
    notifyListeners();
  }
}

