import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/fsl_vocabulary_item.dart';

class VocabularySyncService {
  VocabularySyncService({required this.store, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 10),
            ),
          );

  final FslVocabularyStore store;
  final Dio _dio;

  /// Fetches and atomically caches server vocabulary; offline failures preserve
  /// the last good cache and never block sign recognition.
  Future<int> syncFrom(String serverUrl) async {
    final baseUrl = serverUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) return 0;

    try {
      final uri = Uri.tryParse('$baseUrl/api/v1/ota/vocabulary');
      if (uri == null ||
          !uri.hasAuthority ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
          (uri.scheme.toLowerCase() == 'http' &&
              !const {
                'localhost',
                '127.0.0.1',
                '::1',
                '10.0.2.2',
              }.contains(uri.host.toLowerCase()))) {
        throw const FormatException('The configured API URL is invalid.');
      }

      final response = await _dio.get<dynamic>(uri.toString());
      final payload = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (payload is! List || payload.isEmpty) {
        throw const FormatException(
          'The vocabulary response is empty or malformed.',
        );
      }

      final entries = payload.map(FslVocabularyItem.fromJson).toList();
      if (entries.map((entry) => entry.id).toSet().length != entries.length) {
        throw const FormatException(
          'The vocabulary response contains duplicate IDs.',
        );
      }
      await store.replaceVocabulary(entries);
      return entries.length;
    } catch (error) {
      debugPrint(
        '[VocabularySync] Keeping cached vocabulary after sync failure: $error',
      );
      return 0;
    }
  }
}
