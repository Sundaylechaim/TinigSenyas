import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:path/path.dart';
import '../models/conversation.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  final ValueNotifier<int> historyChangeNotifier = ValueNotifier<int>(0);

  void _notifyHistoryChanged() {
    historyChangeNotifier.value++;
  }

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('tinigsenyas.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
    }
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL,
        confidence REAL NOT NULL,
        source TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        is_synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_conversations_timestamp ON conversations(timestamp DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_conversations_is_synced ON conversations(is_synced)',
    );
  }

  Future<int> saveConversation(Conversation conversation) async {
    final db = await database;
    final id = await db.insert('conversations', conversation.toMap());
    _notifyHistoryChanged();
    return id;
  }

  Future<int> saveRecognizedGesture(
    String text,
    double confidence, {
    String source = 'sign',
  }) async {
    final conversation = Conversation(
      text: text,
      confidence: confidence,
      source: source,
      timestamp: DateTime.now(),
    );
    return await saveConversation(conversation);
  }

  Future<List<Conversation>> getHistory({
    int limit = 100,
    int offset = 0,
  }) async {
    final db = await database;
    final maps = await db.query(
      'conversations',
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((map) => Conversation.fromMap(map)).toList();
  }

  Future<Conversation?> getConversationById(int id) async {
    final db = await database;
    final maps = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Conversation.fromMap(maps.first);
  }

  Future<int> deleteConversation(int id) async {
    final db = await database;
    final count = await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
    _notifyHistoryChanged();
    return count;
  }

  Future<int> clearHistory() async {
    final db = await database;
    final count = await db.delete('conversations');
    _notifyHistoryChanged();
    return count;
  }

  Future<int> getCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM conversations',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> markAsSynced(int id) async {
    final db = await database;
    await db.update(
      'conversations',
      {'is_synced': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Conversation>> getUnsyncedConversations() async {
    final db = await database;
    final maps = await db.query(
      'conversations',
      where: 'is_synced = 0',
      orderBy: 'timestamp DESC',
    );
    return maps.map((map) => Conversation.fromMap(map)).toList();
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
