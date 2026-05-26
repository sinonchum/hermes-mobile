import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/message.dart';

/// SQLite repository for persisting chat messages and sessions.
class MessageRepository {
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'hermes_messages.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            title TEXT,
            created_at INTEGER,
            updated_at INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            session_id TEXT,
            role TEXT,
            content TEXT,
            tool_name TEXT,
            tool_status TEXT,
            timestamp INTEGER,
            FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE INDEX idx_messages_session ON messages(session_id)
        ''');

        await db.execute('''
          CREATE INDEX idx_messages_timestamp ON messages(timestamp)
        ''');
      },
    );
  }

  // ── Sessions ──

  /// Create a new session and return its ID.
  static Future<String> createSession({String? title}) async {
    final db = await database;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert('sessions', {
      'id': id,
      'title': title ?? 'Chat $id',
      'created_at': now,
      'updated_at': now,
    });

    return id;
  }

  /// Get all sessions, newest first.
  static Future<List<Map<String, dynamic>>> getSessions() async {
    final db = await database;
    return db.query('sessions', orderBy: 'updated_at DESC');
  }

  /// Update session title.
  static Future<void> updateSessionTitle(String sessionId, String title) async {
    final db = await database;
    await db.update(
      'sessions',
      {'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Delete a session and its messages.
  static Future<void> deleteSession(String sessionId) async {
    final db = await database;
    await db.delete('messages', where: 'session_id = ?', whereArgs: [sessionId]);
    await db.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
  }

  // ── Messages ──

  /// Save a message to a session.
  static Future<void> saveMessage(String sessionId, ChatMessage message) async {
    final db = await database;

    await db.insert('messages', {
      'id': message.id,
      'session_id': sessionId,
      'role': message.role,
      'content': message.content,
      'tool_name': message.toolName,
      'tool_status': message.toolStatus,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    // Update session's updated_at
    await db.update(
      'sessions',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Save multiple messages at once.
  static Future<void> saveMessages(String sessionId, List<ChatMessage> messages) async {
    final db = await database;
    final batch = db.batch();

    for (final message in messages) {
      batch.insert('messages', {
        'id': message.id,
        'session_id': sessionId,
        'role': message.role,
        'content': message.content,
        'tool_name': message.toolName,
        'tool_status': message.toolStatus,
        'timestamp': message.timestamp.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);

    await db.update(
      'sessions',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Load all messages for a session.
  static Future<List<ChatMessage>> getMessages(String sessionId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
    );

    return rows.map((row) => ChatMessage(
      id: row['id'] as String,
      role: row['role'] as String,
      content: row['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      toolName: row['tool_name'] as String?,
      toolStatus: row['tool_status'] as String?,
    )).toList();
  }

  /// Search messages by content.
  static Future<List<ChatMessage>> searchMessages(String query) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'content LIKE ?',
      whereArgs: ['%$query%'],
      orderBy: 'timestamp DESC',
      limit: 50,
    );

    return rows.map((row) => ChatMessage(
      id: row['id'] as String,
      role: row['role'] as String,
      content: row['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      toolName: row['tool_name'] as String?,
      toolStatus: row['tool_status'] as String?,
    )).toList();
  }

  /// Get message count for a session.
  static Future<int> getMessageCount(String sessionId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM messages WHERE session_id = ?',
      [sessionId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Clear all messages in a session.
  static Future<void> clearSession(String sessionId) async {
    final db = await database;
    await db.delete('messages', where: 'session_id = ?', whereArgs: [sessionId]);
  }

  /// Close the database.
  static Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
