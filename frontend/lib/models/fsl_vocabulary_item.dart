class FslVocabularyItem {
  const FslVocabularyItem({
    required this.id,
    required this.word,
    required this.meaning,
    required this.gestureLabel,
    this.videoPath,
    this.createdAt,
  });

  final int id;
  final String word;
  final String meaning;
  final String gestureLabel;
  final String? videoPath;
  final String? createdAt;

  factory FslVocabularyItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Vocabulary entry must be an object.');
    }
    final rawId = value['fsl_id'];
    final word = value['word'];
    final meaning = value['meaning'];
    final gestureLabel = value['gesture_label'];
    if (rawId is! int ||
        rawId <= 0 ||
        word is! String ||
        word.trim().isEmpty ||
        meaning is! String ||
        meaning.trim().isEmpty ||
        gestureLabel is! String ||
        gestureLabel.trim().isEmpty) {
      throw const FormatException(
        'Vocabulary entry is missing required fields.',
      );
    }
    return FslVocabularyItem(
      id: rawId,
      word: word.trim(),
      meaning: meaning.trim(),
      gestureLabel: gestureLabel.trim(),
      videoPath: (value['video_path'] as String?)?.trim(),
      createdAt: (value['created_at'] as String?)?.trim(),
    );
  }

  Map<String, Object?> toDatabaseMap() => {
    'fsl_id': id,
    'word': word,
    'meaning': meaning,
    'gesture_label': gestureLabel,
    'video_path': videoPath,
    'created_at': createdAt,
  };
}

abstract interface class FslVocabularyStore {
  Future<void> replaceVocabulary(List<FslVocabularyItem> entries);
  Future<List<String>> getVocabularyWords();
}
