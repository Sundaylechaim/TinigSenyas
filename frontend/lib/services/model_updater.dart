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

class ModelFileEntry {
  final String name;
  final String url;
  final String sha256;

  const ModelFileEntry({
    required this.name,
    required this.url,
    required this.sha256,
  });

  factory ModelFileEntry.fromJson(Map<String, dynamic> json) {
    return ModelFileEntry(
      name: (json['name'] as String?) ?? (json['filename'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
      sha256: (json['sha256'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'name': name, 'url': url, 'sha256': sha256};
}

class ModelUpdateInfo {
  final String version;
  final String currentVersion;
  final String url;
  final String sha256;
  final String minAppVersion;
  final String notes;
  final List<ModelFileEntry> models;
  final UpdateStatus status;
  final double progress;
  final String? errorMessage;

  const ModelUpdateInfo({
    required this.version,
    this.currentVersion = '1.0.0',
    required this.url,
    required this.sha256,
    required this.minAppVersion,
    this.notes = '',
    this.models = const [],
    this.status = UpdateStatus.upToDate,
    this.progress = 0.0,
    this.errorMessage,
  });

  ModelUpdateInfo copyWith({
    String? version,
    String? currentVersion,
    String? url,
    String? sha256,
    String? minAppVersion,
    String? notes,
    List<ModelFileEntry>? models,
    UpdateStatus? status,
    double? progress,
    String? errorMessage,
  }) {
    return ModelUpdateInfo(
      version: version ?? this.version,
      currentVersion: currentVersion ?? this.currentVersion,
      url: url ?? this.url,
      sha256: sha256 ?? this.sha256,
      minAppVersion: minAppVersion ?? this.minAppVersion,
      notes: notes ?? this.notes,
      models: models ?? this.models,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class ModelUpdater {
  static const currentAppVersion = '1.2.5';
  static const defaultRemoteManifestUrl =
      'https://raw.githubusercontent.com/Sundaylechaim/TinigSenyas/main/frontend/assets/model/manifest.json';
  static const _manifestAsset = 'assets/model/manifest.json';
  static const _versionAsset = 'assets/model/version.txt';
  static const _prefsKey = 'model_version';

  final Dio _dio;
  final String remoteManifestUrl;

  ModelUpdater({Dio? dio, String? remoteManifestUrl})
    : remoteManifestUrl =
          (remoteManifestUrl != null && remoteManifestUrl.trim().isNotEmpty)
          ? remoteManifestUrl.trim()
          : defaultRemoteManifestUrl,
      _dio =
          dio ??
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

  List<ModelFileEntry> _parseModelList(
    Map<String, dynamic> data,
    String fallbackUrl,
    String fallbackSha256,
  ) {
    final list = <ModelFileEntry>[];
    if (data['models'] is List) {
      for (final item in data['models'] as List) {
        if (item is Map<String, dynamic>) {
          final entry = ModelFileEntry.fromJson(item);
          if (entry.url.isNotEmpty && entry.name.isNotEmpty) {
            list.add(entry);
          }
        }
      }
    }
    if (list.isEmpty && fallbackUrl.isNotEmpty) {
      list.add(
        ModelFileEntry(
          name: 'fsl_model.tflite',
          url: fallbackUrl,
          sha256: fallbackSha256,
        ),
      );
    }
    return list;
  }

  bool _isAllowedDownloadUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return false;
    if (uri.scheme.toLowerCase() == 'https') return true;
    final host = uri.host.toLowerCase();
    return uri.scheme.toLowerCase() == 'http' &&
        (host == 'localhost' || host == '127.0.0.1' || host == '10.0.2.2');
  }

  bool _isSafeModelEntry(ModelFileEntry entry) {
    return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(entry.name) &&
        _isAllowedDownloadUrl(entry.url) &&
        RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(entry.sha256.trim());
  }

  /// Checks for model OTA updates online
  Future<ModelUpdateInfo> checkForUpdates() async {
    final currentVersion = await getInstalledVersion();

    // 1. Try remote manifest (require HTTPS unless pointing to local dev loopback)
    if (remoteManifestUrl.isNotEmpty &&
        _isAllowedDownloadUrl(remoteManifestUrl)) {
      try {
        final response = await _dio.get<dynamic>(remoteManifestUrl);
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
          final models = _parseModelList(data, downloadUrl, sha256Hash);
          final appCompatible = !_isVersionNewer(minApp, currentAppVersion);

          final hasUpdate =
              appCompatible &&
              _isVersionNewer(remoteVer, currentVersion) &&
              models.isNotEmpty &&
              models.every(_isSafeModelEntry);

          return ModelUpdateInfo(
            version: remoteVer,
            currentVersion: currentVersion,
            url: downloadUrl,
            sha256: sha256Hash,
            minAppVersion: minApp,
            notes: notes,
            models: models,
            status: hasUpdate
                ? UpdateStatus.updateAvailable
                : UpdateStatus.upToDate,
          );
        }
      } catch (e) {
        debugPrint('ModelUpdater check remote failed: $e');
      }
    }

    // 2. Fallback: check bundled manifest
    try {
      final manifestJson = await rootBundle.loadString(_manifestAsset);
      final Map<String, dynamic> data = jsonDecode(manifestJson);
      final manifestVersion = (data['version'] as String?) ?? currentVersion;
      final url = (data['url'] as String?) ?? '';
      final sha256Hash = (data['sha256'] as String?) ?? '';
      final minApp = (data['min_app_version'] as String?) ?? '1.0.0';
      final notes = (data['notes'] as String?) ?? '';
      final models = _parseModelList(data, url, sha256Hash);

      final hasUpdate =
          !_isVersionNewer(minApp, currentAppVersion) &&
          _isVersionNewer(manifestVersion, currentVersion) &&
          models.isNotEmpty &&
          models.every(_isSafeModelEntry);

      return ModelUpdateInfo(
        version: hasUpdate ? manifestVersion : currentVersion,
        currentVersion: currentVersion,
        url: url,
        sha256: sha256Hash,
        minAppVersion: minApp,
        notes: notes,
        models: models,
        status: hasUpdate
            ? UpdateStatus.updateAvailable
            : UpdateStatus.upToDate,
      );
    } catch (e) {
      return ModelUpdateInfo(
        version: currentVersion,
        currentVersion: currentVersion,
        url: '',
        sha256: '',
        minAppVersion: '1.0.0',
        status: UpdateStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// Downloads and verifies the new model files
  Stream<ModelUpdateInfo> downloadUpdate(ModelUpdateInfo info) async* {
    final targetFiles = info.models.isNotEmpty
        ? info.models
        : (info.url.isNotEmpty
              ? [
                  ModelFileEntry(
                    name: 'fsl_model.tflite',
                    url: info.url,
                    sha256: info.sha256,
                  ),
                ]
              : <ModelFileEntry>[]);

    if (targetFiles.isEmpty ||
        targetFiles.any((entry) => !_isSafeModelEntry(entry)) ||
        targetFiles.map((entry) => entry.name).toSet().length !=
            targetFiles.length) {
      yield info.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'The model update manifest is invalid or incomplete.',
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

      final stagedFiles = <String, File>{};
      final backupFiles = <String, File>{};
      final installedFiles = <String>[];
      final totalFiles = targetFiles.length;

      for (int i = 0; i < totalFiles; i++) {
        final entry = targetFiles[i];
        final tempPath = p.join(modelsDir.path, '.${entry.name}.download');
        final tempFile = File(tempPath);
        if (await tempFile.exists()) await tempFile.delete();

        final progressController = StreamController<double>();

        unawaited(
          _dio
              .download(
                entry.url,
                tempPath,
                onReceiveProgress: (received, total) {
                  if (total > 0) {
                    final fileProg = received / total;
                    final overall = (i + fileProg) / totalFiles;
                    progressController.add(overall.clamp(0.0, 0.99));
                  }
                },
              )
              .then((_) => progressController.close())
              .catchError((err) {
                progressController.addError(err);
              }),
        );

        await for (final prog in progressController.stream) {
          yield info.copyWith(status: UpdateStatus.downloading, progress: prog);
        }

        // Verify file exists
        if (!await tempFile.exists()) {
          yield info.copyWith(
            status: UpdateStatus.error,
            errorMessage: 'Download incomplete for ${entry.name}.',
          );
          return;
        }

        // Always verify SHA-256 checksum before installing over existing model
        final digest = (await sha256.bind(tempFile.openRead()).first)
            .toString();
        if (digest.toLowerCase() != entry.sha256.trim().toLowerCase()) {
          await tempFile.delete();
          yield info.copyWith(
            status: UpdateStatus.error,
            errorMessage: 'Checksum verification failed for ${entry.name}.',
          );
          return;
        }

        stagedFiles[entry.name] = tempFile;
      }

      // Verify the complete model set before replacing any installed model.
      try {
        for (final entry in targetFiles) {
          final finalFile = File(p.join(modelsDir.path, entry.name));
          if (await finalFile.exists()) {
            final backup = File(
              p.join(modelsDir.path, '.${entry.name}.backup'),
            );
            if (await backup.exists()) await backup.delete();
            await finalFile.rename(backup.path);
            backupFiles[entry.name] = backup;
          }
          await stagedFiles[entry.name]!.rename(finalFile.path);
          installedFiles.add(entry.name);
        }
      } catch (_) {
        for (final name in installedFiles.reversed) {
          final installed = File(p.join(modelsDir.path, name));
          if (await installed.exists()) await installed.delete();
        }
        for (final entry in backupFiles.entries) {
          if (await entry.value.exists()) {
            await entry.value.rename(p.join(modelsDir.path, entry.key));
          }
        }
        rethrow;
      }

      for (final backup in backupFiles.values) {
        if (await backup.exists()) await backup.delete();
      }

      // Save new version
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, info.version);

      yield info.copyWith(status: UpdateStatus.upToDate, progress: 1.0);
    } catch (e) {
      debugPrint('[ModelUpdater] Download exception: $e');
      yield info.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Update failed: $e',
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
