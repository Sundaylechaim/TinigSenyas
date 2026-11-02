import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum UpdateStatus { upToDate, updateAvailable, error, downloading }

class ModelUpdateInfo {
  final String version;
  final String url;
  final String sha256;
  final String minAppVersion;
  final String notes;
  final UpdateStatus status;
  final double progress;
  final String? errorMessage;

  const ModelUpdateInfo({
    required this.version,
    required this.url,
    required this.sha256,
    required this.minAppVersion,
    this.notes = '',
    this.status = UpdateStatus.upToDate,
    this.progress = 0.0,
    this.errorMessage,
  });

  ModelUpdateInfo copyWith({
    String? version,
    String? url,
    String? sha256,
    String? minAppVersion,
    String? notes,
    UpdateStatus? status,
    double? progress,
    String? errorMessage,
  }) {
    return ModelUpdateInfo(
      version: version ?? this.version,
      url: url ?? this.url,
      sha256: sha256 ?? this.sha256,
      minAppVersion: minAppVersion ?? this.minAppVersion,
      notes: notes ?? this.notes,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class ModelUpdater {
  static const _manifestAsset = 'assets/model/manifest.json';
  static const _versionAsset = 'assets/model/version.txt';
  static const _prefsKey = 'model_version';

  final Dio _dio;
  final String? remoteManifestUrl;

  ModelUpdater({Dio? dio, this.remoteManifestUrl})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(minutes: 5),
              ),
            );

  /// Gets the currently installed model version (from SharedPreferences or bundled asset)
  Future<String> getInstalledVersion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved != null && saved.isNotEmpty) {
        return saved;
      }
      final bundled = await rootBundle.loadString(_versionAsset);
      return bundled.trim();
    } catch (_) {
      return '1.0.0';
    }
  }

  /// Checks for model OTA updates online
  Future<ModelUpdateInfo> checkForUpdates() async {
    final currentVersion = await getInstalledVersion();

    // If a remote URL is specified, query it
    if (remoteManifestUrl != null && remoteManifestUrl!.isNotEmpty) {
      try {
        final response = await _dio.get<dynamic>(remoteManifestUrl!);
        final rawData = response.data;
        final Map<String, dynamic>? data = rawData is String
            ? (jsonDecode(rawData) as Map<String, dynamic>?)
            : (rawData as Map<String, dynamic>?);
        if (data != null) {
          final remoteVer = (data['version'] as String?) ?? currentVersion;
          final downloadUrl = (data['url'] as String?) ?? '';
          final sha256Hash = (data['sha256'] as String?) ?? '';
          final minApp = (data['min_app_version'] as String?) ?? '1.0.0';
          final notes = (data['notes'] as String?) ?? '';

          final hasUpdate = _isVersionNewer(remoteVer, currentVersion) &&
              downloadUrl.isNotEmpty;

          return ModelUpdateInfo(
            version: remoteVer,
            url: downloadUrl,
            sha256: sha256Hash,
            minAppVersion: minApp,
            notes: notes,
            status: hasUpdate
                ? UpdateStatus.updateAvailable
                : UpdateStatus.upToDate,
          );
        }
      } catch (e) {
        debugPrint('ModelUpdater check remote failed: $e');
      }
    }

    // Fallback: check bundled manifest
    try {
      final manifestJson = await rootBundle.loadString(_manifestAsset);
      final Map<String, dynamic> data = jsonDecode(manifestJson);
      final manifestVersion = (data['version'] as String?) ?? currentVersion;
      final url = (data['url'] as String?) ?? '';

      final hasUpdate = _isVersionNewer(manifestVersion, currentVersion) &&
          url.isNotEmpty;

      return ModelUpdateInfo(
        version: hasUpdate ? manifestVersion : currentVersion,
        url: url,
        sha256: (data['sha256'] as String?) ?? '',
        minAppVersion: (data['min_app_version'] as String?) ?? '1.0.0',
        status: hasUpdate
            ? UpdateStatus.updateAvailable
            : UpdateStatus.upToDate,
      );
    } catch (e) {
      return ModelUpdateInfo(
        version: currentVersion,
        url: '',
        sha256: '',
        minAppVersion: '1.0.0',
        status: UpdateStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// Downloads and verifies the new model file
  Stream<ModelUpdateInfo> downloadUpdate(ModelUpdateInfo info) async* {
    if (info.url.isEmpty) {
      yield info.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Download URL is empty.',
      );
      return;
    }

    yield info.copyWith(status: UpdateStatus.downloading, progress: 0.0);

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelsDir = Directory(p.join(appDir.path, 'models'));
      if (!await modelsDir.exists()) {
        await modelsDir.create(recursive: true);
      }

      final tempPath = p.join(modelsDir.path, 'model_temp.bin');
      final finalPath = p.join(modelsDir.path, 'fsl_model.tflite');

      double currentProgress = 0.0;
      final progressController = StreamController<double>();

      unawaited(
        _dio.download(
          info.url,
          tempPath,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              currentProgress = received / total;
              progressController.add(currentProgress);
            }
          },
        ).then((_) => progressController.close()).catchError((err) {
          progressController.addError(err);
        }),
      );

      await for (final prog in progressController.stream) {
        yield info.copyWith(status: UpdateStatus.downloading, progress: prog);
      }

      // Verify SHA256 if provided
      if (info.sha256.isNotEmpty) {
        final downloadedFile = File(tempPath);
        final bytes = await downloadedFile.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        if (digest.toLowerCase() != info.sha256.toLowerCase()) {
          await downloadedFile.delete();
          yield info.copyWith(
            status: UpdateStatus.error,
            errorMessage: 'Model checksum verification failed.',
          );
          return;
        }
      }

      // Move into place
      final finalFile = File(finalPath);
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await File(tempPath).rename(finalPath);

      // Save new version
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, info.version);

      yield info.copyWith(status: UpdateStatus.upToDate, progress: 1.0);
    } catch (e) {
      yield info.copyWith(
        status: UpdateStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  bool _isVersionNewer(String remote, String current) {
    if (remote == current) return false;
    final rParts = remote.replaceAll(RegExp(r'[^0-9.]'), '').split('.');
    final cParts = current.replaceAll(RegExp(r'[^0-9.]'), '').split('.');
    for (int i = 0; i < 3; i++) {
      final rVal = i < rParts.length ? int.tryParse(rParts[i]) ?? 0 : 0;
      final cVal = i < cParts.length ? int.tryParse(cParts[i]) ?? 0 : 0;
      if (rVal > cVal) return true;
      if (rVal < cVal) return false;
    }
    return false;
  }
}
