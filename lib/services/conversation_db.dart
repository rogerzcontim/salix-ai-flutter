// lib/services/conversation_db.dart
//
// v7.0.0+32 — Local conversation persistence (SQLite via sqflite).
//
// Roger 29/abr (Galaxy S24 Ultra Samsung One UI):
// "salvando as conversas no celular para buscar alguma coisa que de uma
// conversa antiga".
//
// Goals:
//   1. Every chat turn (user + assistant) is durably persisted on the
//      device, immediately, even if the OS kills the app mid-stream.
//   2. The streaming assistant message is updated transactionally as
//      tokens arrive (throttled to ~500ms so we don't flood SQLite).
//   3. On app open we restore the last conversation and scroll-to-bottom.
//   4. A search page can run LIKE queries over content without paging the
//      entire history into memory.
//   5. Partial / failed messages keep their accumulated text and a
//      `status` flag so the UI shows "↻ tentar novamente" instead of
//      a noisy "(interrompida)" line.
//
// Schema:
//   conversations(
//     id              INTEGER PRIMARY KEY AUTOINCREMENT,
//     persona_id      TEXT NOT NULL,
//     started_at      INTEGER NOT NULL,   -- ms epoch
//     last_msg_at     INTEGER NOT NULL,   -- ms epoch
//     title           TEXT,               -- first user msg truncated
//     message_count   INTEGER NOT NULL DEFAULT 0
//   )
//
//   messages(
//     id              INTEGER PRIMARY KEY AUTOINCREMENT,
//     conv_id         INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
//     role            TEXT NOT NULL,        -- user|assistant|system
//     kind            TEXT NOT NULL DEFAULT 'text',
//     content         TEXT NOT NULL DEFAULT '',
//     ts              INTEGER NOT NULL,     -- ms epoch
//     status          TEXT NOT NULL DEFAULT 'complete',
//                      -- complete|streaming|partial|failed|sending
//     tokens_in       INTEGER,
//     tokens_out      INTEGER,
//     tool_name       TEXT,
//     tool_status     TEXT,
//     tool_calls_json TEXT,
//     artifact_url    TEXT,
//     artifact_type   TEXT,
//     meta_json       TEXT
//   )
//
//   CREATE INDEX idx_messages_conv ON messages(conv_id, ts);
//   CREATE INDEX idx_messages_status ON messages(status);
//   CREATE INDEX idx_messages_content ON messages(content) WHERE length(content) > 0;
//
// Interaction:
//   - chat_page.initState -> ConversationDb.instance.openOrCreateActive(personaId)
//   - _send() -> insertUserMessage + insertStreamingAssistant
//   - delta -> appendStreamingDelta(messageId, text) (throttled 500ms)
//   - done  -> markComplete(messageId)
//   - error -> markPartial(messageId) (NEVER append "(interrompida)")
//   - search page -> searchMessages(query, limit:50)

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/message.dart';

class ConversationDb {
  ConversationDb._();
  static final ConversationDb instance = ConversationDb._();

  static const _dbName = 'salix_conversations_v1.db';
  static const _dbVersion = 1;

  Database? _db;
  Future<Database>? _opening;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _opening ??= _open();
    _db = await _opening!;
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    return await openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (d) async {
        await d.execute('PRAGMA foreign_keys = ON');
        await d.execute('PRAGMA journal_mode = WAL');
      },
      onCreate: (d, version) async {
        await d.execute('''
          CREATE TABLE conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            persona_id TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            last_msg_at INTEGER NOT NULL,
            title TEXT,
            message_count INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await d.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conv_id INTEGER NOT NULL,
            role TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'text',
            content TEXT NOT NULL DEFAULT '',
            ts INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'complete',
            tokens_in INTEGER,
            tokens_out INTEGER,
            tool_name TEXT,
            tool_status TEXT,
            tool_calls_json TEXT,
            artifact_url TEXT,
            artifact_type TEXT,
            meta_json TEXT,
            FOREIGN KEY (conv_id) REFERENCES conversations(id) ON DELETE CASCADE
          )
        ''');
        await d.execute(
            'CREATE INDEX idx_messages_conv ON messages(conv_id, ts)');
        await d.execute(
            'CREATE INDEX idx_messages_status ON messages(status)');
        await d.execute('CREATE INDEX idx_conv_persona ON conversations(persona_id, last_msg_at)');
      },
    );
  }

  // ------------------------- Conversations ---------------------------------

  /// Returns the most recent conversation for this persona, or creates a new
  /// one if none exists. The "active" conversation is just the most recent.
  Future<int> openOrCreateActive(String personaId) async {
    final database = await db;
    final rows = await database.query(
      'conversations',
      where: 'persona_id = ?',
      whereArgs: [personaId],
      orderBy: 'last_msg_at DESC',
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return rows.first['id'] as int;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return await database.insert('conversations', {
      'persona_id': personaId,
      'started_at': now,
      'last_msg_at': now,
      'title': null,
      'message_count': 0,
    });
  }

  /// Force-create a brand-new conversation (used when user taps "limpar").
  Future<int> newConversation(String personaId) async {
    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    return await database.insert('conversations', {
      'persona_id': personaId,
      'started_at': now,
      'last_msg_at': now,
      'title': null,
      'message_count': 0,
    });
  }

  Future<List<Map<String, Object?>>> listConversations(String personaId,
      {int limit = 100}) async {
    final database = await db;
    return await database.query(
      'conversations',
      where: 'persona_id = ?',
      whereArgs: [personaId],
      orderBy: 'last_msg_at DESC',
      limit: limit,
    );
  }

  Future<void> deleteConversation(int convId) async {
    final database = await db;
    await database.delete('conversations', where: 'id = ?', whereArgs: [convId]);
  }

  // -------------------------- Messages -------------------------------------

  /// Inserts a user-typed message and bumps conversation metadata.
  Future<int> insertUserMessage({
    required int convId,
    required String text,
  }) async {
    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await database.insert('messages', {
      'conv_id': convId,
      'role': Role.user.name,
      'kind': MessageKind.text.name,
      'content': text,
      'ts': now,
      'status': 'complete',
    });
    await _bumpConversation(convId, now, titleHint: text);
    return id;
  }

  /// Inserts a fresh, empty assistant message in `streaming` state. Returns
  /// its id so subsequent token deltas can update it in place.
  Future<int> insertStreamingAssistant({required int convId}) async {
    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await database.insert('messages', {
      'conv_id': convId,
      'role': Role.assistant.name,
      'kind': MessageKind.text.name,
      'content': '',
      'ts': now,
      'status': 'streaming',
    });
    await _bumpConversation(convId, now);
    return id;
  }

  /// Replaces the entire content (used by the throttler in chat_page).
  Future<void> updateAssistantContent({
    required int messageId,
    required String content,
  }) async {
    final database = await db;
    await database.update(
      'messages',
      {'content': content},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> markComplete({required int messageId, String? content}) async {
    final database = await db;
    final values = <String, Object?>{'status': 'complete'};
    if (content != null) values['content'] = content;
    await database.update('messages', values,
        where: 'id = ?', whereArgs: [messageId]);
  }

  /// Marks a message as "partial" — stream died mid-flight but we keep the
  /// accumulated text. NEVER appends "(interrompida)".
  Future<void> markPartial({required int messageId, String? content}) async {
    final database = await db;
    final values = <String, Object?>{'status': 'partial'};
    if (content != null) values['content'] = content;
    await database.update('messages', values,
        where: 'id = ?', whereArgs: [messageId]);
  }

  Future<void> markFailed({required int messageId, String? content}) async {
    final database = await db;
    final values = <String, Object?>{'status': 'failed'};
    if (content != null) values['content'] = content;
    await database.update('messages', values,
        where: 'id = ?', whereArgs: [messageId]);
  }

  /// Inserts an arbitrary system/tool/artifact bubble (already complete).
  Future<int> insertNonText({
    required int convId,
    required ChatMessage m,
  }) async {
    final database = await db;
    final ts = m.ts.millisecondsSinceEpoch;
    final id = await database.insert('messages', {
      'conv_id': convId,
      'role': m.role.name,
      'kind': m.kind.name,
      'content': m.content,
      'ts': ts,
      'status': 'complete',
      'tool_name': m.toolName,
      'tool_status': m.toolStatus,
      'artifact_url': m.artifactUrl,
      'artifact_type': m.artifactType,
      'meta_json': m.meta != null ? jsonEncode(m.meta) : null,
    });
    await _bumpConversation(convId, ts);
    return id;
  }

  /// Returns messages for a conversation, oldest first (chat order).
  Future<List<ChatMessage>> messagesFor(int convId, {int limit = 500}) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      where: 'conv_id = ?',
      whereArgs: [convId],
      orderBy: 'ts ASC, id ASC',
      limit: limit,
    );
    return rows.map(_rowToMessage).toList(growable: false);
  }

  /// Returns the message ids that are still streaming/partial — used on app
  /// resume to decide whether to mark them as `partial` and offer retry.
  Future<List<Map<String, Object?>>> findOrphanStreaming() async {
    final database = await db;
    return await database.query(
      'messages',
      where: "status IN ('streaming','sending')",
      orderBy: 'ts DESC',
      limit: 50,
    );
  }

  /// Marks any orphan-streaming messages (left over from a previous app
  /// session that was killed) as `partial`. Called on app boot.
  Future<int> reapOrphans() async {
    final database = await db;
    return await database.update(
      'messages',
      {'status': 'partial'},
      where: "status IN ('streaming','sending')",
    );
  }

  // -------------------------- Search ---------------------------------------

  /// LIKE search over message content. Returns rows with a `conv_id`,
  /// `ts`, and a snippet (the matching content trimmed to ~140 chars).
  Future<List<Map<String, Object?>>> searchMessages(
    String query, {
    int limit = 100,
  }) async {
    if (query.trim().isEmpty) return const [];
    final database = await db;
    final pattern = '%${query.trim()}%';
    final rows = await database.rawQuery('''
      SELECT m.id AS msg_id, m.conv_id, m.role, m.content, m.ts, m.kind,
             c.persona_id, c.title
      FROM messages m
      JOIN conversations c ON c.id = m.conv_id
      WHERE m.content LIKE ?
        AND m.kind = 'text'
        AND length(m.content) > 0
      ORDER BY m.ts DESC
      LIMIT ?
    ''', [pattern, limit]);
    return rows;
  }

  // -------------------------- internal -------------------------------------

  Future<void> _bumpConversation(int convId, int ts, {String? titleHint}) async {
    final database = await db;
    final cur = await database.query('conversations',
        where: 'id = ?', whereArgs: [convId], limit: 1);
    if (cur.isEmpty) return;
    final row = cur.first;
    final hadTitle = (row['title'] != null) &&
        (row['title'] as String).trim().isNotEmpty;
    final values = <String, Object?>{
      'last_msg_at': ts,
      'message_count': (row['message_count'] as int? ?? 0) + 1,
    };
    if (!hadTitle && titleHint != null && titleHint.trim().isNotEmpty) {
      var t = titleHint.trim();
      if (t.length > 80) t = '${t.substring(0, 77)}...';
      values['title'] = t;
    }
    await database.update('conversations', values,
        where: 'id = ?', whereArgs: [convId]);
  }

  ChatMessage _rowToMessage(Map<String, Object?> row) {
    final m = ChatMessage(
      role: Role.values.firstWhere(
        (r) => r.name == (row['role'] as String? ?? 'assistant'),
        orElse: () => Role.assistant,
      ),
      content: (row['content'] as String?) ?? '',
      ts: DateTime.fromMillisecondsSinceEpoch(
          (row['ts'] as int?) ?? DateTime.now().millisecondsSinceEpoch),
      kind: MessageKind.values.firstWhere(
        (k) => k.name == (row['kind'] as String? ?? 'text'),
        orElse: () => MessageKind.text,
      ),
      toolName: row['tool_name'] as String?,
      toolStatus: row['tool_status'] as String?,
      artifactUrl: row['artifact_url'] as String?,
      artifactType: row['artifact_type'] as String?,
      meta: _decodeMeta(row['meta_json'] as String?),
      dbId: row['id'] as int?,
      status: (row['status'] as String?) ?? 'complete',
    );
    return m;
  }

  Map<String, dynamic>? _decodeMeta(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {}
    return null;
  }
}

/// Throttles assistant content writes to SQLite so a fast SSE stream doesn't
/// hammer the disk. Latest content wins; a final flush is guaranteed via
/// [flush] (called from the _send() finally block).
class AssistantContentThrottler {
  AssistantContentThrottler({this.interval = const Duration(milliseconds: 500)});

  final Duration interval;
  String? _pending;
  int? _messageId;
  Timer? _timer;
  bool _writing = false;
  bool _disposed = false;

  void update(int messageId, String content) {
    if (_disposed) return;
    _messageId = messageId;
    _pending = content;
    _timer ??= Timer(interval, _flush);
  }

  Future<void> _flush() async {
    _timer = null;
    if (_writing) {
      // Re-arm — another flush is in flight; this latest content will be
      // picked up by that flush (we always write the most recent _pending).
      _timer = Timer(interval, _flush);
      return;
    }
    final id = _messageId;
    final content = _pending;
    if (id == null || content == null) return;
    _writing = true;
    try {
      await ConversationDb.instance
          .updateAssistantContent(messageId: id, content: content);
    } catch (e) {
      if (kDebugMode) debugPrint('[chat_db] throttle flush failed: $e');
    } finally {
      _writing = false;
    }
    if (_pending != content) {
      // More updates arrived during the write; keep flushing.
      _timer = Timer(interval, _flush);
    }
  }

  /// Flush any pending content immediately (best-effort).
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final id = _messageId;
    final content = _pending;
    if (id == null || content == null) return;
    try {
      await ConversationDb.instance
          .updateAssistantContent(messageId: id, content: content);
    } catch (e) {
      if (kDebugMode) debugPrint('[chat_db] final flush failed: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
