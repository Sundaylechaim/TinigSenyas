import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

/// On-device Filipino transcription using the multilingual Whisper Tiny model.
/// The verified model is downloaded once; audio is processed locally afterward.
class OfflineFilipinoAsrService {
  static const modelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'asr-models/sherpa-onnx-whisper-tiny.tar.bz2';
  static const modelArchiveSize = 116204861;
  static const modelArchiveSha256 =
      'c46116994e539aa165266d96b325252728429c12535eb9d8b6a2b10f129e66b1';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 30),
    ),
  );

  OfflineRecognizer? _recognizer;
  String? _loadedDirectory;

  Future<bool> isInstalled() async =>
      _hasRequiredFiles(await _modelDirectory());

  Future<void> install({
    required void Function(int received, int total) onProgress,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Offline Filipino transcription is mobile only.');
    }
    if (await isInstalled()) return;

    final supportDirectory = await getApplicationSupportDirectory();
    final archivePath = p.join(
      supportDirectory.path,
      'whisper-tiny.tar.bz2.part',
    );
    final stagingPath = p.join(supportDirectory.path, 'whisper-fil-staging');
    final targetPath = await _modelDirectory();
    final archiveFile = File(archivePath);
    final stagingDirectory = Directory(stagingPath);

    try {
      await _dio.download(
        modelUrl,
        archivePath,
        onReceiveProgress: onProgress,
        deleteOnError: true,
      );
      if (await archiveFile.length() != modelArchiveSize) {
        throw StateError('The downloaded speech model has an invalid size.');
      }
      final digest = await sha256.bind(archiveFile.openRead()).first;
      if (digest.toString() != modelArchiveSha256) {
        throw StateError('The downloaded speech model failed verification.');
      }

      if (await stagingDirectory.exists()) {
        await stagingDirectory.delete(recursive: true);
      }
      await stagingDirectory.create(recursive: true);
      await Isolate.run(() => _extractModel(archivePath, stagingPath));
      if (!await _hasRequiredFiles(stagingPath)) {
        throw StateError('The speech model is incomplete after extraction.');
      }

      _recognizer?.free();
      _recognizer = null;
      _loadedDirectory = null;
      final existingDirectory = Directory(targetPath);
      if (await existingDirectory.exists()) {
        await existingDirectory.delete(recursive: true);
      }
      await stagingDirectory.rename(targetPath);
    } finally {
      if (await archiveFile.exists()) await archiveFile.delete();
      if (await stagingDirectory.exists()) {
        await stagingDirectory.delete(recursive: true);
      }
    }
  }

  Future<String> transcribe(Uint8List pcm16) async {
    if (pcm16.lengthInBytes < 3200) return '';
    await initialize();

    final sampleCount = pcm16.length ~/ 2;
    final samples = Float32List(sampleCount);
    final data = ByteData.sublistView(pcm16);
    for (var i = 0; i < sampleCount; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }

    final recognizer = _recognizer!;
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }

  Future<void> initialize() async {
    final directory = await _modelDirectory();
    if (!await _hasRequiredFiles(directory)) {
      throw StateError('Download the offline Filipino speech model first.');
    }
    if (_recognizer != null && _loadedDirectory == directory) return;

    _recognizer?.free();
    await initBindingsAsync();
    _recognizer = OfflineRecognizer(
      OfflineRecognizerConfig(
        model: OfflineModelConfig(
          whisper: OfflineWhisperModelConfig(
            encoder: p.join(directory, 'tiny-encoder.int8.onnx'),
            decoder: p.join(directory, 'tiny-decoder.int8.onnx'),
            language: 'tl',
            task: 'transcribe',
          ),
          tokens: p.join(directory, 'tiny-tokens.txt'),
          numThreads: 2,
          debug: false,
          modelType: 'whisper',
        ),
      ),
    );
    _loadedDirectory = directory;
  }

  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _loadedDirectory = null;
  }

  Future<String> _modelDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return p.join(supportDirectory.path, 'sherpa-whisper-tiny-fil');
  }

  static Future<bool> _hasRequiredFiles(String directory) async {
    const requiredFiles = {
      'tiny-encoder.int8.onnx': 10000000,
      'tiny-decoder.int8.onnx': 80000000,
      'tiny-tokens.txt': 500000,
    };
    for (final entry in requiredFiles.entries) {
      final file = File(p.join(directory, entry.key));
      if (!await file.exists() || await file.length() < entry.value) {
        return false;
      }
    }
    return true;
  }
}

void _extractModel(String archivePath, String destinationPath) {
  final archiveInput = InputFileStream(archivePath);
  try {
    final tarInput = BZip2Decoder().decodeLazy(archiveInput, verify: true);
    TarDecoder().decodeStream(
      tarInput,
      verify: true,
      storeData: true,
      keepEntries: false,
      callback: (entry) {
        if (entry.isSymbolicLink) {
          throw const FormatException(
            'Symbolic links are not allowed in ASR models.',
          );
        }
        final relativePath = _modelPackRelativePath(entry.name);
        if (relativePath == null) return;
        final outputPath = p.joinAll([
          destinationPath,
          ...p.posix.split(relativePath),
        ]);
        if (entry.isDirectory) {
          Directory(outputPath).createSync(recursive: true);
          return;
        }
        Directory(p.dirname(outputPath)).createSync(recursive: true);
        final output = OutputFileStream(outputPath);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
      },
    );
  } finally {
    archiveInput.closeSync();
  }
}

String? _modelPackRelativePath(String archivePath) {
  final normalized = p.posix.normalize(archivePath);
  if (normalized.startsWith('/') || normalized == '..') {
    throw const FormatException('Invalid path in Whisper model archive.');
  }
  final segments = p.posix
      .split(normalized)
      .where((segment) => segment.isNotEmpty && segment != '.')
      .toList();
  if (segments.isEmpty || segments.contains('..')) {
    throw const FormatException('Invalid path in Whisper model archive.');
  }
  if (segments.first == 'sherpa-onnx-whisper-tiny') segments.removeAt(0);
  if (segments.isEmpty) return null;
  final relativePath = p.posix.joinAll(segments);
  return const {
        'tiny-encoder.int8.onnx',
        'tiny-decoder.int8.onnx',
        'tiny-tokens.txt',
      }.contains(relativePath)
      ? relativePath
      : null;
}
