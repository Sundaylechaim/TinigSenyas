import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinigsenyas/models/fsl_vocabulary_item.dart';
import 'package:tinigsenyas/services/vocabulary_sync_service.dart';

void main() {
  test(
    'valid vocabulary is stored after the complete payload validates',
    () async {
      final store = _MemoryVocabularyStore();
      final adapter = _VocabularyAdapter([
        {
          'fsl_id': 1,
          'word': '  Salamat ',
          'meaning': 'Pasasalamat',
          'gesture_label': 'salamat',
        },
        {
          'fsl_id': 2,
          'word': 'Tulong',
          'meaning': 'Humingi ng tulong',
          'gesture_label': 'tulong',
        },
      ]);

      final service = VocabularySyncService(
        store: store,
        dio: Dio()..httpClientAdapter = adapter,
      );
      final count = await service.syncFrom('https://api.example.com/');

      expect(count, 2);
      expect(adapter.requestCount, 1);
      expect(adapter.lastPath, '/api/v1/ota/vocabulary');
      expect(store.entries.map((entry) => entry.word), ['Salamat', 'Tulong']);
    },
  );

  test('malformed payload preserves the existing cache', () async {
    final cached = const FslVocabularyItem(
      id: 8,
      word: 'Pakiusap',
      meaning: 'Kahilingan',
      gestureLabel: 'pakiusap',
    );
    final store = _MemoryVocabularyStore()..entries = [cached];
    final service = VocabularySyncService(
      store: store,
      dio: Dio()
        ..httpClientAdapter = _VocabularyAdapter([
          {
            'fsl_id': 9,
            'word': '',
            'meaning': 'Invalid',
            'gesture_label': 'invalid',
          },
        ]),
    );

    expect(await service.syncFrom('https://api.example.com'), 0);
    expect(store.replaceCalls, 0);
    expect(store.entries.single.word, 'Pakiusap');
  });

  test('does not make a request when no server is configured', () async {
    final store = _MemoryVocabularyStore();
    final adapter = _VocabularyAdapter(const []);
    final service = VocabularySyncService(
      store: store,
      dio: Dio()..httpClientAdapter = adapter,
    );

    expect(await service.syncFrom('  '), 0);
    expect(adapter.requestCount, 0);
    expect(store.replaceCalls, 0);
  });
}

class _MemoryVocabularyStore implements FslVocabularyStore {
  List<FslVocabularyItem> entries = [];
  int replaceCalls = 0;

  @override
  Future<List<String>> getVocabularyWords() async =>
      entries.map((entry) => entry.word).toList();

  @override
  Future<void> replaceVocabulary(List<FslVocabularyItem> items) async {
    replaceCalls++;
    entries = List.of(items);
  }
}

class _VocabularyAdapter implements HttpClientAdapter {
  _VocabularyAdapter(this.payload);

  final List<Object?> payload;
  int requestCount = 0;
  String? lastPath;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    lastPath = options.uri.path;
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
