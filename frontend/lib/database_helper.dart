import 'package:flutter/foundation.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  
  DatabaseHelper._init();

  final List<Map<String, dynamic>> _mockConversations = [];

  Future<int> saveRecognizedGesture(String word, double confidence) async {
    final now = DateTime.now().toIso8601String();
    
    final record = {
      'convo_id': _mockConversations.length + 1,
      'output_text': word,
      'confidence': confidence,
      'created_at': now,
    };

    _mockConversations.insert(0, record);
    debugPrint("SAVED TO MOCK DATABASE: $word");
    return record['convo_id'] as int;
  }

  Future<List<Map<String, dynamic>>> getHistory() async {
    return _mockConversations;
  }
}
