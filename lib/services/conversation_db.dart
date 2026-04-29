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
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/message.dart';

class ConversationDb {
  ConversationDb._();
  static final ConversationDb instance = ConversationDb._();

  static const _dbName = 'salix_conversations_v1.db';
  /// v10.0.0+35: bumped to 2 to add `conversation_summaries` table for
  /// long-term memory compaction (Roger: "compacta e coloca no banco de
  /// dados do cel assim quando precisar alguma coisa a salix puxa").
  static const _dbVersion = 2;

  Database? _db;
  Future<Database>? _opening;

  /// v9.0.0+34: last DB open error (corruption / IO / permission). When
  /// non-null, the chat page renders an "histórico inacessível, conversa
  /// nova iniciada" pill and degrades to in-memory-only mode (it never
  /// blocks the UI / never crashes the app). Cleared on next successful
  /// open (e.g., after corruption recovery).
  String? lastOpenError;

  /// v9.0.0+34: when true, the DB layer is in "soft-fail" mode -- every
  /// write is a no-op and every read returns []. Set when [_open] failed
  /// even after corruption recovery. The chat page checks this and runs
  /// in memory-only mode. Reset on next app start.
  bool inMemoryOnly = false;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _opening ??= _openWithRecovery();
    _db = await _opening!;
    return _db!;
  }

  /// v9.0.0+34: try-once-recover-once-give-up strategy. If the first
  /// [_open] throws (e.g., DatabaseException: file is encrypted or is
  /// not a database / SqliteException: database disk image is malformed),
  /// we rename the stale file to `.corrupted-{ts}.db` and recreate from
  /// scratch. Roger keeps a working app with empty history rather than a
  /// crashing app with intact history. The renamed file stays on disk so
  /// support can retrieve it later.
  Future<Database> _openWithRecovery() async {
    try {
      final d = await _open();
      lastOpenError = null;
      inMemoryOnly = false;
      return d;
    } catch (e, st) {
      debugPrint('[chat_db] FIRST open failed: $e\n$st');
      lastOpenError = '$e';
      // Try corruption recovery: rename existing file out of the way.
      try {
        final dir = await getApplicationDocumentsDirectory();
        final path = p.join(dir.path, _dbName);
        final f = File(path);
        if (await f.exists()) {
          final ts = DateTime.now().millisecondsSinceEpoch;
          final dead = p.join(dir.path, 'salix_conversations_v1.corrupted-$ts.db');
          try {
            await f.rename(dead);
            debugPrint('[chat_db] renamed corrupt db -> $dead');
          } catch (re) {
            debugPrint('[chat_db] rename corrupt db failed: $re; trying delete');
            try { await f.delete(); } catch (_) {}
          }
        }
      } catch (re) {
        debugPrint('[chat_db] cleanup attempt failed: $re');
      }
      // Second attempt — fresh schema.
      try {
        final d = await _open();
        lastOpenError = 'recovered_after_corruption';
        inMemoryOnly = false;
        return d;
      } catch (e2, st2) {
        debugPrint('[chat_db] SECOND open failed: $e2\n$st2');
        lastOpenError = '$e2';
        inMemoryOnly = true;
        // Return an in-memory database so subsequent calls don't NPE.
        // It will accept inserts/queries but won't survive app restart.
        try {
          return await openDatabase(
            inMemoryDatabasePath,
            version: _dbVersion,
            onConfigure: (d) async {
              await d.execute('PRAGMA foreign_keys = ON');
            },
            onCreate: (d, _) async => _createSchema(d),
          );
        } catch (e3) {
          debugPrint('[chat_db] in-memory fallback ALSO failed: $e3');
          rethrow;
        }
      }
    }
  }

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    debugPrint('[chat_db] opening DB at $path (v$_dbVersion)');
    return await openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (d) async {
        await d.execute('PRAGMA foreign_keys = ON');
        await d.execute('PRAGMA journal_mode = WAL');
      },
      onCreate: (d, version) async => _createSchema(d),
      onUpgrade: (d, oldV, newV) async {
        debugPrint('[chat_db] upgrade $oldV -> $newV');
        if (oldV < 2) {
          await _createSummariesSchema(d);
        }
      },
    );
  }

  Future<void> _createSchema(Database d) async {
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
    // v10.0.0+35: long-term memory compaction tables (created on first install).
    await _createSummariesSchema(d);
  }

  /// v10.0.0+35: Long-term memory compaction.
  ///
  /// Schema:
  ///   conversation_summaries(
  ///     id INTEGER PK,
  ///     conv_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  ///     persona_id TEXT NOT NULL,        -- denormalized for fast retrieval
  ///     ts_from INTEGER NOT NULL,        -- ms epoch of oldest message summarized
  ///     ts_to   INTEGER NOT NULL,        -- ms epoch of newest message summarized
  ///     content TEXT NOT NULL,           -- 5-bullet summary in pt-BR
  ///     msg_count INTEGER NOT NULL,      -- how many raw msgs were compacted
  ///     created_at INTEGER NOT NULL,     -- ms epoch when summary was generated
  ///     embedding_blob BLOB              -- reserved for future vector search
  ///   )
  ///
  /// Retrieval (chat_page calls this before sending):
  ///   SELECT content FROM conversation_summaries
  ///   WHERE persona_id = ? AND content LIKE '%kw1%'
  ///   ORDER BY ts_to DESC LIMIT 3;
  ///
  /// On user msg with text "X", we tokenize X (split spaces, lowercase,
  /// drop stopwords <3 chars) and OR-LIKE every keyword. If no matches,
  /// we fall back to the 3 most recent summaries (recency wins). This is
  /// "ship-able tonight" per Roger's spec — a real cosine-similarity
  /// upgrade is reserved for a later wave.
  Future<void> _createSummariesSchema(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS conversation_summaries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conv_id INTEGER NOT NULL,
        persona_id TEXT NOT NULL,
        ts_from INTEGER NOT NULL,
        ts_to INTEGER NOT NULL,
        content TEXT NOT NULL,
        msg_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        embedding_blob BLOB,
        FOREIGN KEY (conv_id) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_summ_persona_ts ON conversation_summaries(persona_id, ts_to DESC)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_summ_conv ON conversation_summaries(conv_id, ts_to)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_summ_content ON conversation_summaries(content)');
    debugPrint('[chat_db] conversation_summaries schema created');
  }

  // ------------------------- Conversations ---------------------------------

  /// Returns the most recent conversation for this persona, or creates a new
  /// one if none exists. The "active" conversation is just the most recent.
  ///
  /// v9.0.0+34: NEVER throws. If the DB is dead, returns -1 and the caller
  /// degrades to in-memory-only mode (chat still works, history doesn't
  /// persist this session). Roger: "erro ao abrir a conversa" must NEVER
  /// kill the app or block sending messages.
  ///
  /// v10.0.0+35: ALSO persist the resolved conv_id in SharedPreferences
  /// (`chat.active_conv_id.<personaId>`). This is paranoia for Bug 3 ("inicia
  /// do zero"): if the SQL `ORDER BY last_msg_at DESC` ever returns no rows
  /// due to a broken WAL or the conv row was wiped while messages survived
  /// (corruption edge case), we fall back to the SP pointer and keep the
  /// existing conversation alive. The pointer is updated on every successful
  /// open + every newConversation() call.
  Future<int> openOrCreateActive(String personaId) async {
    try {
      final database = await db;
      // First: try SP pointer for this persona. If it points to a valid row,
      // prefer that — guarantees stability across app restarts even if
      // last_msg_at gets out of sync.
      try {
        final sp = await SharedPreferences.getInstance();
        final spKey = 'chat.active_conv_id.$personaId';
        final spId = sp.getInt(spKey);
        if (spId != null && spId > 0) {
          final exists = await database.query(
            'conversations',
            columns: ['id'],
            where: 'id = ? AND persona_id = ?',
            whereArgs: [spId, personaId],
            limit: 1,
          );
          if (exists.isNotEmpty) {
            debugPrint('[chat_db] active conv resolved via SP pointer: $spId');
            return spId;
          } else {
            debugPrint('[chat_db] SP pointer $spId not found in DB; falling back to last_msg_at');
            await sp.remove(spKey);
          }
        }
      } catch (e) {
        debugPrint('[chat_db] SP pointer read failed (ignoring): $e');
      }

      final rows = await database.query(
        'conversations',
        where: 'persona_id = ?',
        whereArgs: [personaId],
        orderBy: 'last_msg_at DESC',
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final id = rows.first['id'] as int;
        await _setActiveConvId(personaId, id);
        debugPrint('[chat_db] active conv resolved via last_msg_at: $id');
        return id;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final newId = await database.insert('conversations', {
        'persona_id': personaId,
        'started_at': now,
        'last_msg_at': now,
        'title': null,
        'message_count': 0,
      });
      await _setActiveConvId(personaId, newId);
      debugPrint('[chat_db] created fresh conv: $newId');
      return newId;
    } catch (e, st) {
      debugPrint('[chat_db] openOrCreateActive failed: $e\n$st');
      lastOpenError = '$e';
      inMemoryOnly = true;
      return -1; // sentinel: caller treats this as "no persistence available"
    }
  }

  Future<void> _setActiveConvId(String personaId, int convId) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('chat.active_conv_id.$personaId', convId);
    } catch (e) {
      debugPrint('[chat_db] _setActiveConvId failed: $e');
    }
  }

  /// Force-create a brand-new conversation (used when user taps "limpar").
  ///
  /// v9.0.0+34: NEVER throws. Returns -1 if DB is dead.
  /// v10.0.0+35: also pin the new id as the SP active pointer.
  Future<int> newConversation(String personaId) async {
    if (inMemoryOnly) return -1;
    try {
      final database = await db;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = await database.insert('conversations', {
        'persona_id': personaId,
        'started_at': now,
        'last_msg_at': now,
        'title': null,
        'message_count': 0,
      });
      await _setActiveConvId(personaId, id);
      return id;
    } catch (e) {
      debugPrint('[chat_db] newConversation failed: $e');
      return -1;
    }
  }

  Future<List<Map<String, Object?>>> listConversations(String personaId,
      {int limit = 100}) async {
    if (inMemoryOnly) return const [];
    try {
      final database = await db;
      return await database.query(
        'conversations',
        where: 'persona_id = ?',
        whereArgs: [personaId],
        orderBy: 'last_msg_at DESC',
        limit: limit,
      );
    } catch (e) {
      debugPrint('[chat_db] listConversations failed: $e');
      return const [];
    }
  }

  Future<void> deleteConversation(int convId) async {
    if (convId < 0 || inMemoryOnly) return;
    try {
      final database = await db;
      await database.delete('conversations', where: 'id = ?', whereArgs: [convId]);
    } catch (e) {
      debugPrint('[chat_db] deleteConversation failed: $e');
    }
  }

  // -------------------------- Messages -------------------------------------

  /// Inserts a user-typed message and bumps conversation metadata.
  ///
  /// v9.0.0+34: NEVER throws. Returns -1 if the DB is dead.
  Future<int> insertUserMessage({
    required int convId,
    required String text,
  }) async {
    if (convId < 0 || inMemoryOnly) return -1;
    try {
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
    } catch (e) {
      debugPrint('[chat_db] insertUserMessage failed: $e');
      return -1;
    }
  }

  /// Inserts a fresh, empty assistant message in `streaming` state. Returns
  /// its id so subsequent token deltas can update it in place.
  ///
  /// v9.0.0+34: NEVER throws. Returns -1 if the DB is dead.
  Future<int> insertStreamingAssistant({required int convId}) async {
    if (convId < 0 || inMemoryOnly) return -1;
    try {
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
    } catch (e) {
      debugPrint('[chat_db] insertStreamingAssistant failed: $e');
      return -1;
    }
  }

  /// Replaces the entire content (used by the throttler in chat_page).
  ///
  /// v9.0.0+34: NEVER throws.
  Future<void> updateAssistantContent({
    required int messageId,
    required String content,
  }) async {
    if (messageId < 0 || inMemoryOnly) return;
    try {
      final database = await db;
      await database.update(
        'messages',
        {'content': content},
        where: 'id = ?',
        whereArgs: [messageId],
      );
    } catch (e) {
      debugPrint('[chat_db] updateAssistantContent failed: $e');
    }
  }

  Future<void> markComplete({required int messageId, String? content}) async {
    if (messageId < 0 || inMemoryOnly) return;
    try {
      final database = await db;
      final values = <String, Object?>{'status': 'complete'};
      if (content != null) values['content'] = content;
      await database.update('messages', values,
          where: 'id = ?', whereArgs: [messageId]);
    } catch (e) {
      debugPrint('[chat_db] markComplete failed: $e');
    }
  }

  /// Marks a message as "partial" — stream died mid-flight but we keep the
  /// accumulated text. NEVER appends "(interrompida)".
  Future<void> markPartial({required int messageId, String? content}) async {
    if (messageId < 0 || inMemoryOnly) return;
    try {
      final database = await db;
      final values = <String, Object?>{'status': 'partial'};
      if (content != null) values['content'] = content;
      await database.update('messages', values,
          where: 'id = ?', whereArgs: [messageId]);
    } catch (e) {
      debugPrint('[chat_db] markPartial failed: $e');
    }
  }

  Future<void> markFailed({required int messageId, String? content}) async {
    if (messageId < 0 || inMemoryOnly) return;
    try {
      final database = await db;
      final values = <String, Object?>{'status': 'failed'};
      if (content != null) values['content'] = content;
      await database.update('messages', values,
          where: 'id = ?', whereArgs: [messageId]);
    } catch (e) {
      debugPrint('[chat_db] markFailed failed: $e');
    }
  }

  /// Inserts an arbitrary system/tool/artifact bubble (already complete).
  ///
  /// v9.0.0+34: NEVER throws. Returns -1 if DB is dead.
  Future<int> insertNonText({
    required int convId,
    required ChatMessage m,
  }) async {
    if (convId < 0 || inMemoryOnly) return -1;
    try {
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
    } catch (e) {
      debugPrint('[chat_db] insertNonText failed: $e');
      return -1;
    }
  }

  /// Returns messages for a conversation, oldest first (chat order).
  ///
  /// v9.0.0+34: NEVER throws. Returns [] if DB is dead or convId is -1.
  /// v10.0.0+35: explicit Logcat trace ("Loaded X messages from conv Y") so
  /// Roger can verify via `adb logcat | grep chat_db` that history actually
  /// loads on every app open (Bug 3 — "inicia do zero" debugging).
  Future<List<ChatMessage>> messagesFor(int convId, {int limit = 500}) async {
    if (convId < 0 || inMemoryOnly) {
      debugPrint('[chat_db] messagesFor convId=$convId (skipped: dead or sentinel)');
      return const [];
    }
    try {
      final database = await db;
      final rows = await database.query(
        'messages',
        where: 'conv_id = ?',
        whereArgs: [convId],
        orderBy: 'ts ASC, id ASC',
        limit: limit,
      );
      debugPrint('[chat_db] Loaded ${rows.length} messages from conversation $convId');
      return rows.map(_rowToMessage).toList(growable: false);
    } catch (e) {
      debugPrint('[chat_db] messagesFor failed: $e');
      return const [];
    }
  }

  /// Returns the message ids that are still streaming/partial — used on app
  /// resume to decide whether to mark them as `partial` and offer retry.
  ///
  /// v9.0.0+34: NEVER throws.
  Future<List<Map<String, Object?>>> findOrphanStreaming() async {
    if (inMemoryOnly) return const [];
    try {
      final database = await db;
      return await database.query(
        'messages',
        where: "status IN ('streaming','sending')",
        orderBy: 'ts DESC',
        limit: 50,
      );
    } catch (e) {
      debugPrint('[chat_db] findOrphanStreaming failed: $e');
      return const [];
    }
  }

  /// Marks any orphan-streaming messages (left over from a previous app
  /// session that was killed) as `partial`. Called on app boot.
  ///
  /// v9.0.0+34: NEVER throws. Returns 0 if DB is dead.
  Future<int> reapOrphans() async {
    if (inMemoryOnly) return 0;
    try {
      final database = await db;
      return await database.update(
        'messages',
        {'status': 'partial'},
        where: "status IN ('streaming','sending')",
      );
    } catch (e) {
      debugPrint('[chat_db] reapOrphans failed: $e');
      return 0;
    }
  }

  // -------------------------- Search ---------------------------------------

  /// LIKE search over message content. Returns rows with a `conv_id`,
  /// `ts`, and a snippet (the matching content trimmed to ~140 chars).
  Future<List<Map<String, Object?>>> searchMessages(
    String query, {
    int limit = 100,
  }) async {
    if (query.trim().isEmpty) return const [];
    if (inMemoryOnly) return const [];
    try {
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
    } catch (e) {
      debugPrint('[chat_db] searchMessages failed: $e');
      return const [];
    }
  }

  // -------------------------- v10 long-term memory -------------------------

  /// v10.0.0+35: total message count for a conversation. Used by chat_page
  /// to decide when to trigger compaction (>500 msgs -> compact oldest 100).
  Future<int> messageCount(int convId) async {
    if (convId < 0 || inMemoryOnly) return 0;
    try {
      final database = await db;
      final r = await database.rawQuery(
        'SELECT COUNT(*) AS n FROM messages WHERE conv_id = ?',
        [convId],
      );
      if (r.isEmpty) return 0;
      return (r.first['n'] as int?) ?? 0;
    } catch (e) {
      debugPrint('[chat_db] messageCount failed: $e');
      return 0;
    }
  }

  /// v10.0.0+35: fetch the oldest [n] text messages of a conversation, for
  /// compaction. Returns [{role, content, ts}] in chronological order.
  Future<List<Map<String, Object?>>> oldestTextMessages(int convId, int n) async {
    if (convId < 0 || inMemoryOnly) return const [];
    try {
      final database = await db;
      return await database.query(
        'messages',
        columns: ['id', 'role', 'content', 'ts'],
        where: "conv_id = ? AND kind = 'text' AND length(content) > 0",
        whereArgs: [convId],
        orderBy: 'ts ASC, id ASC',
        limit: n,
      );
    } catch (e) {
      debugPrint('[chat_db] oldestTextMessages failed: $e');
      return const [];
    }
  }

  /// v10.0.0+35: insert a compacted summary, then delete the source raw
  /// messages atomically (transaction). Returns the summary id (-1 on err).
  Future<int> insertSummaryAndPrune({
    required int convId,
    required String personaId,
    required int tsFrom,
    required int tsTo,
    required String content,
    required List<int> messageIdsToDelete,
  }) async {
    if (convId < 0 || inMemoryOnly) return -1;
    if (content.trim().isEmpty) return -1;
    try {
      final database = await db;
      final now = DateTime.now().millisecondsSinceEpoch;
      int? summaryId;
      await database.transaction((txn) async {
        summaryId = await txn.insert('conversation_summaries', {
          'conv_id': convId,
          'persona_id': personaId,
          'ts_from': tsFrom,
          'ts_to': tsTo,
          'content': content,
          'msg_count': messageIdsToDelete.length,
          'created_at': now,
        });
        if (messageIdsToDelete.isNotEmpty) {
          // Batch delete in chunks of 500 to avoid SQLITE_MAX_VARIABLE_NUMBER.
          for (var i = 0; i < messageIdsToDelete.length; i += 500) {
            final chunk = messageIdsToDelete.sublist(
                i, (i + 500).clamp(0, messageIdsToDelete.length));
            final placeholders = List.filled(chunk.length, '?').join(',');
            await txn.delete(
              'messages',
              where: 'id IN ($placeholders)',
              whereArgs: chunk,
            );
          }
        }
      });
      debugPrint('[chat_db] summary $summaryId saved (compacted ${messageIdsToDelete.length} msgs)');
      return summaryId ?? -1;
    } catch (e, st) {
      debugPrint('[chat_db] insertSummaryAndPrune failed: $e\n$st');
      return -1;
    }
  }

  /// v10.0.0+35: retrieve up to [limit] summaries most relevant to the
  /// user's [query] for this persona. Strategy:
  ///   1. Tokenize query (lowercase, split, drop stopwords).
  ///   2. For each token, OR-LIKE the content column.
  ///   3. Rank by number of tokens matched DESC, then ts_to DESC (recency).
  ///   4. If query is empty OR yields zero rows, fall back to most recent.
  ///
  /// Returns a list of summary content strings, newest/most-relevant first.
  /// NEVER throws; returns [] on any error (including DB-dead state).
  Future<List<String>> retrieveRelevantSummaries({
    required String personaId,
    required String query,
    int limit = 3,
  }) async {
    if (inMemoryOnly) return const [];
    try {
      final database = await db;
      // Tokenize: lowercase, replace non-alphanum with space, split, drop
      // tokens <3 chars, dedupe, cap at 8 keywords (avoid huge OR clauses).
      final cleaned = query
          .toLowerCase()
          .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
          .trim();
      final tokens = cleaned
          .split(RegExp(r'\s+'))
          .where((t) => t.length >= 3)
          .toSet()
          .take(8)
          .toList();

      if (tokens.isEmpty) {
        final rows = await database.query(
          'conversation_summaries',
          columns: ['content'],
          where: 'persona_id = ?',
          whereArgs: [personaId],
          orderBy: 'ts_to DESC',
          limit: limit,
        );
        return rows
            .map((r) => (r['content'] as String?) ?? '')
            .where((s) => s.isNotEmpty)
            .toList(growable: false);
      }

      // Build dynamic SQL: ranked by hits per content row.
      // We use multiple LIKEs in a CASE to count matches.
      final whereClauses = <String>[];
      final args = <Object?>[personaId];
      final caseClauses = <String>[];
      for (final t in tokens) {
        final like = '%$t%';
        whereClauses.add('content LIKE ?');
        args.add(like);
      }
      // Add LIKE args again for the CASE counter (one occurrence per CASE WHEN).
      for (final t in tokens) {
        final like = '%$t%';
        caseClauses.add('CASE WHEN content LIKE ? THEN 1 ELSE 0 END');
        args.add(like);
      }
      final hitsExpr = caseClauses.join(' + ');
      final sql = '''
        SELECT content, ($hitsExpr) AS hits, ts_to
        FROM conversation_summaries
        WHERE persona_id = ?
          AND (${whereClauses.join(' OR ')})
        ORDER BY hits DESC, ts_to DESC
        LIMIT ?
      ''';
      // Reorder args to match placeholders order:
      // hits CASE WHENs come first (in SELECT), then persona_id, then OR LIKEs, then LIMIT.
      final reordered = <Object?>[];
      // CASE LIKE args:
      for (final t in tokens) reordered.add('%$t%');
      reordered.add(personaId);
      // WHERE LIKE args:
      for (final t in tokens) reordered.add('%$t%');
      reordered.add(limit);

      final rows = await database.rawQuery(sql, reordered);
      if (rows.isEmpty) {
        // Fallback: most recent.
        final fallback = await database.query(
          'conversation_summaries',
          columns: ['content'],
          where: 'persona_id = ?',
          whereArgs: [personaId],
          orderBy: 'ts_to DESC',
          limit: limit,
        );
        return fallback
            .map((r) => (r['content'] as String?) ?? '')
            .where((s) => s.isNotEmpty)
            .toList(growable: false);
      }
      return rows
          .map((r) => (r['content'] as String?) ?? '')
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
    } catch (e, st) {
      debugPrint('[chat_db] retrieveRelevantSummaries failed: $e\n$st');
      return const [];
    }
  }

  /// v10.0.0+35: how many summaries we have for this persona (for UI).
  Future<int> summariesCount(String personaId) async {
    if (inMemoryOnly) return 0;
    try {
      final database = await db;
      final r = await database.rawQuery(
        'SELECT COUNT(*) AS n FROM conversation_summaries WHERE persona_id = ?',
        [personaId],
      );
      if (r.isEmpty) return 0;
      return (r.first['n'] as int?) ?? 0;
    } catch (e) {
      debugPrint('[chat_db] summariesCount failed: $e');
      return 0;
    }
  }

  // -------------------------- internal -------------------------------------

  Future<void> _bumpConversation(int convId, int ts, {String? titleHint}) async {
    if (convId < 0 || inMemoryOnly) return;
    try {
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
    } catch (e) {
      debugPrint('[chat_db] _bumpConversation failed: $e');
    }
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
