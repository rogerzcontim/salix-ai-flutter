import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/message.dart';
import '../models/persona.dart';
import '../services/attachments.dart';
import '../services/chat_stream_keepalive.dart';
import '../services/conversation_db.dart';
import '../services/crash_reporter.dart';
import '../services/intent_launcher.dart';
import '../services/meta_agent_client.dart';
import '../services/persona_store.dart';
import '../services/upload_service.dart';
import '../services/voice.dart';
import '../services/wake_word.dart';
import '../theme.dart';
import 'conversation_search_page.dart';
import 'memories_page.dart';
import 'settings_page.dart';
import 'tools_catalog_page.dart';

final _client = MetaAgentClient();
final _voice = VoiceService();
final _wake = WakeWordService();
final _attachments = AttachmentsService();
final _uploads = UploadService();
final _chatKeepalive = ChatStreamKeepalive();

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});
  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];

  /// Extracted text from the most recent attachment(s), to be injected as
  /// extra context into the next system prompt. Cleared after use.
  final List<_PendingAttachment> _pendingContext = [];

  Persona? _persona;
  bool _streaming = false;
  bool _listening = false;
  bool _uploading = false;
  String _partialVoice = '';

  /// v8.0.0+33: send-state hardening (Galaxy S24 Ultra typing-not-sending fix).
  ///
  /// Bug Roger 29/abr: "estou digitando a pergunta e nao esta enviando".
  /// Root cause: previous _send() error path could leave _streaming=true
  /// indefinitely (setState() guarded by `if (mounted)` -- if widget was
  /// rebuilt mid-stream, the flag never reset). Send button silently did
  /// nothing.
  ///
  /// Mitigations:
  ///  1. _streamingSince timestamp -> watchdog forces reset after 120s.
  ///  2. _lastSendTapAt -> debounce 200ms against accidental double-taps.
  ///  3. _sendError -> visible chip on input bar (not modal dialog).
  DateTime? _streamingSince;
  DateTime? _lastSendTapAt;
  String? _sendError;
  Timer? _streamingWatchdog;

  /// v7.0.0+32: SQLite conversation id (active = most recent for persona).
  /// v9.0.0+34: -1 means "DB is dead, running in-memory-only".
  int? _convId;

  /// v9.0.0+34: when true, we render a "histórico inacessível, conversa
  /// nova iniciada" pill at the top of the chat. Triggered when the DB
  /// failed to open OR the file was corrupt and got renamed out of the
  /// way (recovered_after_corruption). Roger: "erro ao abrir a conversa"
  /// must NEVER block the app — degrade gracefully and explain.
  bool _dbDegraded = false;

  /// Throttler so streaming token deltas don't hammer SQLite.
  final AssistantContentThrottler _dbThrottle = AssistantContentThrottler();

  /// Highlight a specific message id when arriving from search.
  int? _highlightMessageDbId;

  /// v10.0.0+35: compaction guards. We only attempt compaction once per
  /// 5-minute window to avoid hammering the LLM if every send re-checks the
  /// counter. _compactionInFlight blocks parallel compactions.
  DateTime? _lastCompactionAt;
  bool _compactionInFlight = false;

  /// v10.0.0+35: compaction thresholds (Roger spec):
  ///   * trigger when raw message count > 500
  ///   * each pass takes oldest 100 raw text msgs, compacts to a 5-bullet
  ///     summary, deletes the source rows.
  static const int _kCompactTriggerCount = 500;
  static const int _kCompactBatchSize = 100;
  static const Duration _kCompactCooldown = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    // v6.0.0+31: observe lifecycle so we can keep the chat keepalive service
    // alive across screen-off transitions (Samsung Galaxy S24 Doze fix).
    WidgetsBinding.instance.addObserver(this);
    // v1.8.0: defer ALL side-effects to post-first-frame; never block initState.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _load();
      } catch (e, st) {
        debugPrint('[chat] _load failed: $e\n$st');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // v7.0.0+32: on resume, ALWAYS jump to bottom (Roger: "tem que rolar
    // para a ultima pergunta"). Persistent FG service guarantees nothing
    // was lost; we just need to refresh the view if SQLite has new
    // content (e.g., another instance wrote while we were paused — rare).
    if (state == AppLifecycleState.paused) {
      // ignore: discarded_futures
      _dbThrottle.flush();
      CrashReporter.info('chat.paused streaming=$_streaming');
    } else if (state == AppLifecycleState.resumed) {
      _jumpToBottom();
      CrashReporter.info('chat.resumed streaming=$_streaming');
    }
  }

  Future<void> _load() async {
    Persona? p;
    try {
      p = await PersonaStore().active();
    } catch (e) {
      debugPrint('[chat] PersonaStore.active failed: $e');
      p = null;
    }
    if (p != null) {
      try {
        await _voice.initTts(p.voice);
      } catch (e) {
        debugPrint('[chat] initTts failed: $e');
      }
    }
    // v7.0.0+32: load all messages from SQLite for the active conversation.
    // shared_preferences fallback is also imported below for legacy users
    // upgrading from v6, so on first run we migrate the in-memory history
    // into the new schema.
    if (p != null) {
      try {
        await _loadFromDb(p.id);
      } catch (e) {
        debugPrint('[chat] loadFromDb failed: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _persona = p;
      if (_messages.isEmpty && p != null) {
        _messages.add(ChatMessage(
          role: Role.assistant,
          content:
              'Oi ${p.displayName}! Eu sou SALIX. Como posso ajudar hoje?',
          status: 'complete',
        ));
      }
    });
    // Auto-scroll to bottom (last message) on app open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _jumpToBottom();
    });
    // Onda 3 — wake word "Oi SALIX" só se opt-in. Best-effort; nunca crasha.
    try {
      await _maybeStartWakeWord();
    } catch (e) {
      debugPrint('[chat] maybeStartWakeWord failed: $e');
    }
  }

  /// v7.0.0+32: load conversation history from SQLite. Migrates legacy
  /// SharedPreferences history on first run.
  ///
  /// v9.0.0+34: NEVER throws. Fully defensive — if any step fails, we
  /// degrade gracefully to in-memory-only mode and the chat page renders
  /// a "histórico inacessível" pill at top via [_dbDegraded] flag.
  Future<void> _loadFromDb(String personaId) async {
    final db = ConversationDb.instance;
    try {
      // Reap any orphan-streaming messages from a previous session that the
      // OS killed mid-flight (mark as 'partial' so the UI shows retry).
      try {
        await db.reapOrphans();
      } catch (e) {
        debugPrint('[chat] reapOrphans failed: $e');
      }
      final convId = await db.openOrCreateActive(personaId);
      _convId = convId;
      if (convId < 0) {
        // DB is dead — in-memory mode. Signal UI.
        if (mounted) setState(() => _dbDegraded = true);
        _messages.clear();
        return;
      }
      final loaded = await db.messagesFor(convId, limit: 500);

      // Legacy migration: if SQLite is empty but SharedPreferences has the
      // v6 history blob, import it once and then forget.
      if (loaded.isEmpty) {
        try {
          await _migrateLegacyHistory(personaId, convId);
        } catch (e) {
          debugPrint('[chat] legacy migration failed: $e');
        }
        final remigrated = await db.messagesFor(convId, limit: 500);
        _messages
          ..clear()
          ..addAll(remigrated);
      } else {
        _messages
          ..clear()
          ..addAll(loaded);
      }
      // If DB is in "recovered_after_corruption" mode, also flag the UI so
      // user knows old history was archived (still on disk under
      // .corrupted-{ts}.db) and a fresh DB was created.
      if (db.lastOpenError == 'recovered_after_corruption' && mounted) {
        setState(() => _dbDegraded = true);
      }
    } catch (e, st) {
      // Defensive catch — every public method on ConversationDb is now
      // soft-fail, but if a future change introduces a throw we still
      // never crash the chat page.
      debugPrint('[chat] _loadFromDb top-level failed: $e\n$st');
      if (mounted) setState(() => _dbDegraded = true);
    }
  }

  Future<void> _migrateLegacyHistory(String personaId, int convId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'chat.history.$personaId.v1';
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return;
    try {
      // ignore: avoid_dynamic_calls
      final decoded = (raw.startsWith('[')) ? raw : null;
      if (decoded == null) return;
    } catch (_) {}
    // We just import each message verbatim. Streaming/partial states are
    // dropped — we mark them as complete since the pre-v7 client didn't
    // track lifecycle status.
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! List) return;
      for (final item in parsed) {
        if (item is Map<String, dynamic>) {
          final m = ChatMessage.fromJson(item);
          if (m.kind == MessageKind.text) {
            if (m.role == Role.user) {
              await ConversationDb.instance.insertUserMessage(
                convId: convId,
                text: m.content,
              );
            } else {
              final id = await ConversationDb.instance
                  .insertStreamingAssistant(convId: convId);
              await ConversationDb.instance
                  .markComplete(messageId: id, content: m.content);
            }
          } else {
            await ConversationDb.instance.insertNonText(convId: convId, m: m);
          }
        }
      }
      await prefs.remove(key);
    } catch (e) {
      debugPrint('[chat] legacy parse failed: $e');
    }
  }

  Future<void> _maybeStartWakeWord() async {
    if (!_wake.supported) return;
    bool enabled = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool('wake_word.enabled') ?? false;
    } catch (_) {
      enabled = false;
    }
    if (!enabled) return;

    // v3.0.0+25: Re-validate microphone permission BEFORE asking native
    // side to start the foreground service. If user revoked permission
    // at OS level (Settings > Apps > Permissions), the SharedPreferences
    // flag may still say enabled=true. Without this guard the service
    // launch path hits ForegroundServiceTypeException native-side and
    // SIGKILLs the process before any Dart catch can run.
    try {
      final micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        debugPrint('[chat] wake_word.enabled=true but mic perm revoked; clearing flag');
        try {
          final p = await SharedPreferences.getInstance();
          await p.setBool('wake_word.enabled', false);
        } catch (_) {}
        return;
      }
    } catch (e) {
      debugPrint('[chat] mic permission check failed: $e — skip wake word');
      return;
    }

    try {
      await _wake.start(
        onDetected: () async {
          // v2.1.0: blind concurrent triggers — RangeError on _send was
          // caused by overlapping streams mutating _messages. Wake word
          // must NEVER spawn a parallel _send while one is in flight.
          if (_listening) return;
          if (_streaming) {
            debugPrint('[wake] ignoring detection while streaming');
            return;
          }
          if (!mounted) return;
          await _toggleMic();
        },
        onEvent: (ev) {
          // Útil pra debug; sem UI ruidosa.
        },
      );
    } catch (e) {
      debugPrint('[chat] wake.start failed: $e');
    }
  }

  @override
  void dispose() {
    // v7.0.0+32: do NOT stop the persistent FG service in dispose() —
    // it must keep running so background SSE never gets killed by Doze.
    // We only flush the throttler.
    // ignore: discarded_futures
    _dbThrottle.flush();
    _dbThrottle.dispose();
    // v8.0.0+33: cancel watchdog + abort any active client to avoid leaks.
    _streamingWatchdog?.cancel();
    _streamingWatchdog = null;
    try {
      _client.cancel();
    } catch (_) {}
    _input.dispose();
    _scroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _wake.stop();
    super.dispose();
  }

  // -------------------------------------------------- Persistence (v7 SQLite)
  //
  // v7.0.0+32: SharedPreferences blob is gone. Every mutation persists
  // through ConversationDb directly:
  //   - user msg     -> insertUserMessage()
  //   - asst start   -> insertStreamingAssistant()
  //   - asst delta   -> AssistantContentThrottler (500ms)
  //   - asst done    -> markComplete()
  //   - asst partial -> markPartial() (NEVER appends "(interrompida)")
  //   - tool/artifact-> insertNonText()

  // ------------------------------------------------------------------ Send

  Future<void> _send([String? overrideText]) async {
    // v8.0.0+33: Galaxy S24 Ultra typing-not-sending hardening.
    //
    // 1) Self-heal stuck _streaming flag. If the previous attempt left
    //    _streaming=true for >120s, we know it's stale (network hard timeout
    //    is 90s, plus retries = ~7s). Reset and continue.
    if (_streaming) {
      final since = _streamingSince;
      if (since != null && DateTime.now().difference(since).inSeconds > 120) {
        debugPrint('[chat] _streaming flag stuck for >120s; force-resetting');
        if (mounted) {
          setState(() {
            _streaming = false;
            _streamingSince = null;
          });
        } else {
          _streaming = false;
          _streamingSince = null;
        }
      } else {
        // Genuinely streaming. Show a brief visual feedback so the user
        // doesn't think the app is broken.
        if (mounted) {
          setState(() => _sendError = 'Aguarde a resposta atual terminar...');
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted && _sendError == 'Aguarde a resposta atual terminar...') {
              setState(() => _sendError = null);
            }
          });
        }
        return;
      }
    }

    // 2) Debounce: ignore rapid double-taps within 200ms.
    final now = DateTime.now();
    if (_lastSendTapAt != null &&
        now.difference(_lastSendTapAt!).inMilliseconds < 200) {
      debugPrint('[chat] _send debounced (double-tap)');
      return;
    }
    _lastSendTapAt = now;

    final text = (overrideText ?? _input.text).trim();
    if (text.isEmpty) {
      // 3) Visible feedback so Roger knows the tap registered.
      if (mounted) {
        setState(() => _sendError = 'Digite uma pergunta antes de enviar.');
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && _sendError == 'Digite uma pergunta antes de enviar.') {
            setState(() => _sendError = null);
          }
        });
      }
      return;
    }
    _input.clear();
    final p = _persona;
    if (p == null) {
      if (mounted) {
        setState(() => _sendError = 'Persona nao carregada. Reabra o app.');
      }
      return;
    }

    // 4) Mark _streaming=true with timestamp BEFORE any await so a sync
    //    exception in setup still leaves a known stale state we can clean up.
    _streamingSince = now;
    if (mounted) {
      setState(() {
        _streaming = true;
        _sendError = null;
      });
    } else {
      _streaming = true;
    }
    // Watchdog: force-reset _streaming if no completion within 120s.
    _streamingWatchdog?.cancel();
    _streamingWatchdog = Timer(const Duration(seconds: 120), () {
      if (_streaming && mounted) {
        debugPrint('[chat] watchdog firing: _streaming stuck');
        setState(() {
          _streaming = false;
          _streamingSince = null;
          _sendError = 'Conexao demorou demais. Tente novamente.';
        });
      }
    });

    // v9.0.0+34: NEVER abort _send() because of a DB error. ConversationDb
    // is fully soft-fail now — openOrCreateActive returns -1 if the DB is
    // dead, and every subsequent insert/update is a no-op. The user gets
    // an in-memory-only chat (history won't persist this session) but the
    // app continues working. This fixes Roger's "erro ao abrir a conversa"
    // bug where a corrupt/locked SQLite file blocked sending entirely.
    int convId;
    try {
      convId = _convId ??
          await ConversationDb.instance.openOrCreateActive(p.id);
      _convId = convId;
    } catch (e, st) {
      // Defensive: ConversationDb shouldn't throw anymore, but if it does
      // (plugin missing on a weird Samsung build, etc.) we still proceed.
      CrashReporter.report(e, st, context: '_send.openConv.unexpected');
      convId = -1;
      _convId = -1;
    }

    // v2.1.0: hold ChatMessage references directly instead of indexes.
    final userMsg = ChatMessage(role: Role.user, content: text, status: 'complete');
    final assistantMsg = ChatMessage(
      role: Role.assistant,
      content: '',
      status: 'streaming',
    );

    CrashReporter.info('_send.start');

    // v7.0.0+32: persist user msg + assistant placeholder in SQLite BEFORE
    // we start the SSE stream so a Doze kill in the middle never loses the
    // user's question.
    try {
      userMsg.dbId = await ConversationDb.instance.insertUserMessage(
        convId: convId,
        text: text,
      );
      assistantMsg.dbId =
          await ConversationDb.instance.insertStreamingAssistant(convId: convId);
    } catch (e) {
      debugPrint('[chat] db insert failed: $e');
    }

    // v7.0.0+32: foreground service is already persistent; we just bump
    // the notif text so the user sees "SALIX está respondendo..." while
    // the stream is in flight.
    try {
      await _chatKeepalive.bumpStreaming();
    } catch (e) {
      debugPrint('[chat] keepalive.bumpStreaming failed: $e');
    }

    // v8.0.0+33: _streaming was already set true above (before convId load)
    // so a stuck flag is impossible -- here we just append the bubbles.
    if (mounted) {
      setState(() {
        _messages.add(userMsg);
        _messages.add(assistantMsg);
      });
    }
    _scrollToBottom();

    // History is everything before the assistantMsg placeholder.
    // Filter by reference identity, not index, so concurrent mutations
    // can't shift the boundary.
    // v10.0.0+35: clone the LATEST user message and prepend a strict pt-BR
    // language instruction so OSS doesn't drift into English mid-stream
    // (Bug 4 — "as vezes fala misturado os idiomas"). Only the last user
    // turn is mutated; older history goes through unchanged.
    final allHist = _messages
        .where((m) =>
            !identical(m, assistantMsg) &&
            m.role != Role.system &&
            m.kind == MessageKind.text)
        .toList();
    final history = <ChatMessage>[];
    for (var i = 0; i < allHist.length; i++) {
      final m = allHist[i];
      final isLastUser = (i == allHist.length - 1) && m.role == Role.user;
      if (!isLastUser) {
        history.add(m);
        continue;
      }
      // Wrap last user content. Locale-aware.
      final wrapped = _wrapUserMessageForLanguageLock(p, m.content);
      history.add(ChatMessage(
        role: Role.user,
        content: wrapped,
        kind: MessageKind.text,
        status: m.status,
      ));
    }

    // Inject extracted text from any pending attachments into the system prompt
    // for this turn only, then clear so future turns don't repeat it.
    var systemPrompt = _composeSystemPrompt(p);
    _pendingContext.clear();

    // v10.0.0+35: prepend up to 3 most-relevant compacted summaries (long-
    // term memory). Roger spec: "compacta e coloca no banco de dados do cel
    // assim quando precisar alguma coisa a salix puxa". Best-effort — never
    // blocks send if retrieval fails.
    try {
      final memCtx = await _buildLongTermMemoryContext(p, text);
      if (memCtx.isNotEmpty) {
        systemPrompt = '$memCtx\n$systemPrompt';
        debugPrint('[chat] long-term memory injected (${memCtx.length} chars)');
      }
    } catch (e) {
      debugPrint('[chat] long-term memory build failed: $e');
    }
    // Trigger background compaction if conversation grew past threshold.
    _maybeKickCompaction(p);

    String? finalErrorCode;
    try {
      await for (final ev in _client.streamEvents(
        history: history,
        systemPrompt: systemPrompt,
        backend: p.backend,
      )) {
        // v8.0.0+33: do NOT bare-return when unmounted -- break and let the
        // finally block reset _streaming + watchdog. Otherwise next _send()
        // sees a stuck flag and the user can't type. Set finalErrorCode so
        // the bubble is marked partial in SQLite (resume on app reopen).
        if (!mounted) {
          finalErrorCode = 'unmounted';
          break;
        }
        switch (ev.type) {
          case StreamEventType.delta:
            setState(() {
              assistantMsg.content += ev.text ?? '';
            });
            // v7.0.0+32: persist delta to SQLite via throttler so a
            // mid-stream OS kill leaves us with the latest content.
            if (assistantMsg.dbId != null) {
              _dbThrottle.update(assistantMsg.dbId!, assistantMsg.content);
            }
            _scrollToBottom();
            break;

          case StreamEventType.resetContent:
            // v7.0.0+32: emitted by MetaAgentClient just before a transient
            // retry. Clear partial text so the next deltas don't append to
            // a half-broken message.
            setState(() {
              assistantMsg.content = '';
            });
            if (assistantMsg.dbId != null) {
              _dbThrottle.update(assistantMsg.dbId!, '');
            }
            break;

          case StreamEventType.toolCall:
            final chip = ChatMessage(
              role: Role.system,
              content: ev.toolName ?? 'tool',
              kind: MessageKind.toolCall,
              toolName: ev.toolName,
              toolStatus: 'running',
              meta: ev.raw,
            );
            setState(() {
              final pos = _messages.indexOf(assistantMsg);
              final insertAt = pos >= 0 ? pos : _messages.length;
              _messages.insert(insertAt, chip);
            });
            // ignore: discarded_futures
            _persistChip(chip);
            _scrollToBottom();
            break;

          case StreamEventType.toolResult:
            final idx = _messages.lastIndexWhere((m) =>
                m.kind == MessageKind.toolCall &&
                m.toolName == ev.toolName &&
                m.toolStatus != 'ok' &&
                m.toolStatus != 'error');
            setState(() {
              if (idx >= 0) {
                _messages[idx]
                  ..kind = MessageKind.toolResult
                  ..toolStatus = ev.toolStatus
                  ..content =
                      ev.text ?? (ev.toolStatus == 'ok' ? 'enviado' : 'erro')
                  ..meta = ev.raw;
              } else {
                final pos = _messages.indexOf(assistantMsg);
                final insertAt = pos >= 0 ? pos : _messages.length;
                _messages.insert(
                  insertAt,
                  ChatMessage(
                    role: Role.system,
                    content: ev.text ?? '',
                    kind: MessageKind.toolResult,
                    toolName: ev.toolName,
                    toolStatus: ev.toolStatus,
                    meta: ev.raw,
                  ),
                );
              }
            });
            // Persist the (possibly updated) chip.
            if (idx >= 0) {
              // ignore: discarded_futures
              _persistChip(_messages[idx]);
            } else {
              // ignore: discarded_futures
              _persistChip(_messages.last);
            }
            _scrollToBottom();
            break;

          case StreamEventType.artifact:
            final chip = ChatMessage(
              role: Role.system,
              content: ev.artifactLabel ?? 'Arquivo gerado',
              kind: MessageKind.artifact,
              artifactUrl: ev.artifactUrl,
              artifactType: ev.artifactType,
              meta: ev.raw,
            );
            setState(() {
              final pos = _messages.indexOf(assistantMsg);
              final insertAt = pos >= 0 ? pos : _messages.length;
              _messages.insert(insertAt, chip);
            });
            // ignore: discarded_futures
            _persistChip(chip);
            _scrollToBottom();
            break;

          case StreamEventType.done:
            break;

          case StreamEventType.error:
            // v7.0.0+32: error events are status codes — they NEVER bleed
            // into the visible content. Track the latest code so we can
            // mark the bubble after the loop exits.
            finalErrorCode = ev.text ?? 'unknown';
            break;
        }
      }
    } catch (e, s) {
      CrashReporter.report(e, s, context: '_send.catch');
      finalErrorCode = 'exception:$e';
    } finally {
      // v7.0.0+32: ALWAYS flush throttled content + bump notif idle.
      try {
        await _dbThrottle.flush();
      } catch (_) {}
      try {
        await _chatKeepalive.bumpIdle();
      } catch (e) {
        debugPrint('[chat] keepalive.bumpIdle failed: $e');
      }
      // Dispatch any [OPEN_INTENT] tags then strip them.
      final cleaned = await IntentLauncher.dispatch(assistantMsg.content);
      assistantMsg.content = cleaned;

      // v7.0.0+32: assign final status based on what happened.
      if (finalErrorCode == null) {
        assistantMsg.status = 'complete';
        if (assistantMsg.dbId != null) {
          // ignore: discarded_futures
          ConversationDb.instance.markComplete(
            messageId: assistantMsg.dbId!,
            content: assistantMsg.content,
          );
        }
      } else if (finalErrorCode == 'user_canceled') {
        assistantMsg.status = 'partial';
        if (assistantMsg.dbId != null) {
          // ignore: discarded_futures
          ConversationDb.instance.markPartial(
            messageId: assistantMsg.dbId!,
            content: assistantMsg.content,
          );
        }
      } else {
        assistantMsg.status = 'failed';
        if (assistantMsg.dbId != null) {
          // ignore: discarded_futures
          ConversationDb.instance.markFailed(
            messageId: assistantMsg.dbId!,
            content: assistantMsg.content,
          );
        }
      }

      // v8.0.0+33: ALWAYS reset streaming state, watchdog, and timestamp.
      // Done in finally so even unhandled errors mid-stream don't leave a
      // stuck flag (the original Galaxy S24 bug).
      _streamingWatchdog?.cancel();
      _streamingWatchdog = null;
      _streamingSince = null;
      if (mounted) {
        setState(() {
          _streaming = false;
          if (finalErrorCode != null &&
              finalErrorCode != 'user_canceled' &&
              !finalErrorCode.startsWith('FATAL:')) {
            // Mid-stream non-fatal error -- show subtle hint.
            _sendError = null;
          }
        });
      } else {
        _streaming = false;
      }

      // Speak final text only if we actually got a complete response.
      if (assistantMsg.status == 'complete' && cleaned.trim().isNotEmpty) {
        _voice.speak(
          cleaned,
          lang: p.voice,
          gender: p.voiceGender,
        );
      }
      CrashReporter.info('_send.done status=${assistantMsg.status}');
    }
  }

  /// v7.0.0+32: persist a tool/artifact chip to SQLite (best-effort).
  Future<void> _persistChip(ChatMessage m) async {
    final cid = _convId;
    if (cid == null) return;
    if (m.dbId != null) return; // already persisted (toolResult update path)
    try {
      m.dbId = await ConversationDb.instance.insertNonText(convId: cid, m: m);
    } catch (e) {
      debugPrint('[chat] persist chip failed: $e');
    }
  }

  // ----------------- v10.0.0+35: long-term memory (RAG-lite) -----------------

  /// Retrieve up to 3 most-relevant compacted summaries for [userQuery] and
  /// build a system message snippet that gets prepended to the next request.
  /// Returns empty string when no summaries exist (first-time use).
  Future<String> _buildLongTermMemoryContext(
      Persona persona, String userQuery) async {
    try {
      final summaries = await ConversationDb.instance.retrieveRelevantSummaries(
        personaId: persona.id,
        query: userQuery,
        limit: 3,
      );
      if (summaries.isEmpty) return '';
      final buf = StringBuffer();
      buf.writeln('# Memoria de longo prazo (conversas anteriores compactadas)');
      buf.writeln('Use as informacoes abaixo se forem relevantes para a pergunta atual. NAO mencione que voce esta usando "memoria" — apenas use o contexto naturalmente.');
      for (var i = 0; i < summaries.length; i++) {
        buf.writeln('\n## Resumo ${i + 1}');
        buf.writeln(summaries[i]);
      }
      buf.writeln('\n# Fim da memoria de longo prazo.\n');
      return buf.toString();
    } catch (e) {
      debugPrint('[chat] build long-term memory failed: $e');
      return '';
    }
  }

  /// Trigger compaction if the active conversation exceeds threshold and
  /// no compaction was performed in the last 5 min. Runs in background — the
  /// user's send is NEVER blocked by compaction.
  void _maybeKickCompaction(Persona persona) {
    final cid = _convId;
    if (cid == null || cid < 0) return;
    if (_compactionInFlight) return;
    final last = _lastCompactionAt;
    if (last != null && DateTime.now().difference(last) < _kCompactCooldown) {
      return;
    }
    // ignore: discarded_futures
    _runCompaction(persona, cid);
  }

  /// Background compaction: take oldest [_kCompactBatchSize] msgs of the
  /// conversation, ask OSS to summarize them in 5 bullets, save the summary,
  /// delete the source rows. NEVER throws to caller. Runs without any
  /// user-visible UI changes.
  Future<void> _runCompaction(Persona persona, int convId) async {
    _compactionInFlight = true;
    try {
      final db = ConversationDb.instance;
      final total = await db.messageCount(convId);
      if (total < _kCompactTriggerCount) {
        debugPrint('[chat] compaction skipped: $total < $_kCompactTriggerCount');
        return;
      }
      final oldest = await db.oldestTextMessages(convId, _kCompactBatchSize);
      if (oldest.length < _kCompactBatchSize) {
        debugPrint('[chat] compaction skipped: only ${oldest.length} text msgs');
        return;
      }
      // Build a prompt for OSS to summarize.
      final convoText = StringBuffer();
      for (final row in oldest) {
        final role = (row['role'] as String?) ?? 'unknown';
        final content = ((row['content'] as String?) ?? '').trim();
        if (content.isEmpty) continue;
        // Cap each message at 800 chars to control prompt size.
        final capped =
            content.length > 800 ? '${content.substring(0, 800)}…' : content;
        convoText.writeln('[$role] $capped');
      }
      final tsFrom = (oldest.first['ts'] as int?) ?? 0;
      final tsTo = (oldest.last['ts'] as int?) ?? 0;
      final ids = oldest
          .map((r) => r['id'] as int?)
          .whereType<int>()
          .toList(growable: false);

      final summary = await _callOssSummarize(persona, convoText.toString());
      if (summary.trim().isEmpty) {
        debugPrint('[chat] compaction skipped: summary empty (LLM err?)');
        return;
      }
      final id = await db.insertSummaryAndPrune(
        convId: convId,
        personaId: persona.id,
        tsFrom: tsFrom,
        tsTo: tsTo,
        content: summary.trim(),
        messageIdsToDelete: ids,
      );
      if (id > 0) {
        _lastCompactionAt = DateTime.now();
        // Optional: refresh in-memory list to drop the now-deleted rows.
        if (mounted) {
          final fresh = await db.messagesFor(convId, limit: 500);
          if (mounted) {
            setState(() {
              _messages
                ..clear()
                ..addAll(fresh);
            });
          }
        }
        debugPrint('[chat] compaction OK: summary id=$id, deleted ${ids.length} msgs');
      }
    } catch (e, st) {
      debugPrint('[chat] _runCompaction failed: $e\n$st');
    } finally {
      _compactionInFlight = false;
    }
  }

  /// Call OSS via meta-agent in non-streaming mode for compaction. We use a
  /// dedicated POST so we don't disturb the main streaming chat client. On
  /// failure returns "" — the caller silently skips compaction.
  Future<String> _callOssSummarize(Persona persona, String convoText) async {
    final endpoint = Uri.parse('https://ironedgeai.com/api/meta-agent/run');
    final body = jsonEncode({
      'stream': false,
      'backend': 'oss',
      'system':
          'Voce e um compactador de conversas. RESPONDA APENAS em portugues do Brasil. Recebe uma sequencia de mensagens [user]/[assistant] e produz um resumo em 5 a 7 bullet points curtos preservando: nomes proprios, datas, decisoes tomadas, acordos, numeros importantes, comandos pedidos. NAO inclua introducao ou conclusao — somente os bullets, um por linha, comecando com "- ". Cap 800 caracteres totais.',
      'messages': [
        {
          'role': 'user',
          'content':
              'Compacte estas mensagens em 5-7 bullets pt-BR (preserve nomes/datas/decisoes/numeros):\n\n${convoText.length > 30000 ? '${convoText.substring(0, 30000)}…' : convoText}',
        },
      ],
      'tools_enabled': false,
    });
    try {
      final r = await http
          .post(
            endpoint,
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 60));
      if (r.statusCode != 200) {
        debugPrint('[chat] compaction LLM HTTP ${r.statusCode}: ${r.body.substring(0, r.body.length.clamp(0, 200))}');
        return '';
      }
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      // Try common shapes:
      //  1) {choices:[{message:{content:"..."}}]}
      //  2) {content:"..."}
      //  3) {output:"..."}
      if (j is Map) {
        final ch = j['choices'];
        if (ch is List && ch.isNotEmpty) {
          final msg = (ch.first as Map?)?['message'];
          if (msg is Map && msg['content'] is String) {
            return msg['content'] as String;
          }
        }
        for (final k in const ['content', 'output', 'text', 'summary']) {
          if (j[k] is String) return j[k] as String;
        }
      }
    } catch (e) {
      debugPrint('[chat] compaction LLM call failed: $e');
    }
    return '';
  }

  /// Retry a failed/partial assistant message. Re-runs _send() with the
  /// original user prompt that immediately preceded the failed bubble.
  Future<void> _retryMessage(ChatMessage failed) async {
    if (_streaming) return;
    final idx = _messages.indexOf(failed);
    if (idx <= 0) return;
    // Walk backwards for the most recent user text.
    String? userText;
    for (int i = idx - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.role == Role.user && m.kind == MessageKind.text) {
        userText = m.content;
        break;
      }
    }
    if (userText == null || userText.isEmpty) return;
    // Drop the failed bubble (and any tool chips between it and the user msg)
    // so the retry produces a clean response.
    setState(() {
      _messages.removeAt(idx);
    });
    if (failed.dbId != null) {
      try {
        await ConversationDb.instance.markFailed(
          messageId: failed.dbId!,
          content: failed.content,
        );
      } catch (_) {}
    }
    await _send(userText);
  }

  /// User pressed STOP — abort the in-flight stream. The MetaAgentClient
  /// closes its http.Client, which propagates a tear-down to the server.
  ///
  /// v7.0.0+32: NEVER appends "(interrompido)" to the visible content.
  /// The bubble shows whatever partial text we already streamed, plus a
  /// "↻ tentar novamente" button (rendered by _Bubble when status='partial').
  void _stopStream() {
    if (!_streaming) return;
    _client.cancel();
    _voice.stopSpeaking();
    // v7.0.0+32: keep the persistent FG service alive — only bump notif
    // back to idle. The _send() finally block will mark the bubble as
    // partial and persist it.
    // ignore: discarded_futures
    _chatKeepalive.bumpIdle();
    // Tag the active assistant bubble visually as paused; final status is
    // assigned in _send()'s finally block when the SSE loop exits.
    setState(() {
      if (_messages.isNotEmpty &&
          _messages.last.role == Role.assistant &&
          _messages.last.kind == MessageKind.text) {
        _messages.last.status = 'partial';
      }
    });
  }

  /// v10.0.0+35: wrap the last user message with a strict language
  /// instruction so OSS doesn't drift idioms (Bug 4). For pt-BR we say
  /// "[responda obrigatoriamente em portugues do Brasil]" before the user
  /// content. The persisted (DB) row keeps the ORIGINAL text — we only
  /// rewrite the API payload here.
  String _wrapUserMessageForLanguageLock(Persona p, String userContent) {
    switch (p.voice) {
      case 'en-US':
        return '[reply strictly in US English] $userContent';
      case 'it-IT':
        return '[rispondi rigorosamente in italiano] $userContent';
      default:
        return '[responda obrigatoriamente em portugues do Brasil, sem misturar com ingles] $userContent';
    }
  }

  /// Builds the system prompt for the next turn, optionally appending
  /// extracted text from any pending attachments.
  String _composeSystemPrompt(Persona p) {
    final base = p.systemPrompt();
    if (_pendingContext.isEmpty) return base;
    final buf = StringBuffer(base);
    buf.writeln('\n\n# Contexto adicional do(s) anexo(s) recente(s):');
    for (final a in _pendingContext) {
      buf.writeln('\n## ${a.label}');
      // Cap each attachment's text injected to ~12 KB to avoid blowing the
      // context window when users attach huge PDFs.
      final cap = a.text.length > 12000 ? a.text.substring(0, 12000) + '\n…[truncado]' : a.text;
      buf.writeln(cap);
    }
    buf.writeln(
        '\nUse este contexto para responder a próxima pergunta do usuário se relevante.');
    return buf.toString();
  }

  // -------------------------------------------------------------- Attach UI

  Future<void> _attachDocument() async {
    if (_uploading || _streaming) return;
    final path = await _attachments.pickDocument();
    if (path == null) return;
    await _doUpload(path: path, kind: 'document');
  }

  Future<void> _capturePhoto() async {
    if (_uploading || _streaming) return;
    final path = await _attachments.capturePhoto();
    if (path == null) return;
    await _doUpload(path: path, kind: 'image');
  }

  Future<void> _doUpload({required String path, required String kind}) async {
    final fileName = path.split(RegExp(r'[\\/]+')).last;
    // v2.1.0: hold message reference rather than index (same fix as _send).
    final placeholder = ChatMessage(
      role: Role.system,
      content: 'Enviando $fileName…',
      kind: MessageKind.upload,
      artifactType: kind,
    );
    setState(() {
      _uploading = true;
      _messages.add(placeholder);
    });
    _scrollToBottom();

    try {
      final res = await _uploads.upload(path: path, kind: kind);
      _pendingContext.add(_PendingAttachment(
        label: res.fileName,
        text: res.extractedText,
      ));
      String summary;
      if (kind == 'image') {
        summary = '📷 Foto enviada (${res.fileName})';
      } else {
        final pages = res.pages != null ? '${res.pages} páginas' : 'extraído';
        summary = '📎 ${res.fileName} ($pages)';
      }
      setState(() {
        placeholder
          ..content = summary
          ..artifactUrl = res.url
          ..meta = {
            'file_id': res.fileId,
            'pages': res.pages,
          };
        _uploading = false;
      });
      _scrollToBottom();

      // Auto-trigger SALIX analysis (UX: upload = pergunta implícita)
      final autoQuery = (kind == 'image')
          ? 'Analise essa imagem em detalhes. Descreva o que aparece, contexto, e qualquer texto visível.'
          : 'Resuma o conteúdo desse arquivo em pontos principais.';
      // Pequeno delay pra UI atualizar antes do stream
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) await _send(autoQuery);
    } catch (e) {
      setState(() {
        placeholder
          ..content = '⚠️ Falha ao enviar $fileName: $e'
          ..toolStatus = 'error';
        _uploading = false;
      });
      _scrollToBottom();
    }
  }

  // ---------------------------------------------------------------- Misc UI

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  /// v7.0.0+32: instant jump (no animation) — used on app resume so the
  /// user sees the most recent message immediately.
  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _openSearch() async {
    final result = await Navigator.of(context).push<ConversationOpenRequest?>(
      MaterialPageRoute(
        builder: (_) => ConversationSearchPage(
          personaIdHint: _persona?.id,
        ),
      ),
    );
    if (result == null || !mounted) return;
    // For now we only support 1 active conversation per persona, so just
    // highlight the message. (Multi-conversation switching would also live
    // here in the future.)
    setState(() => _highlightMessageDbId = result.messageId);
    _jumpToBottom();
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      await _voice.stopListening();
      setState(() => _listening = false);
      return;
    }
    // v2.1.0: refuse to start a new mic session while a stream is active —
    // the resulting parallel _send would mutate _messages mid-flight and
    // could produce stale references/RangeError.
    if (_streaming) {
      debugPrint('[mic] ignoring start while streaming');
      return;
    }
    final p = _persona;
    if (p == null) return;

    // v1.6.0: pede permissão JIT quando user explicitamente clica no mic.
    // Evita crash ao tentar startListening sem permissão concedida.
    try {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Permissão de microfone necessária pra falar.'),
        ));
        return;
      }
    } catch (e) {
      debugPrint('[mic] permission request failed: $e');
    }

    final localeId = p.voice.replaceAll('-', '_');
    setState(() {
      _listening = true;
      _partialVoice = '';
    });
    await _voice.startListening(
      localeId: localeId,
      onPartial: (s) => setState(() => _partialVoice = s),
      onFinal: (s) async {
        setState(() {
          _listening = false;
          _partialVoice = '';
        });
        // v1.6.0: tenta parser local de comandos universais ANTES de mandar
        // pro chat. Se casar, executa direto + speak feedback. Se não casar,
        // segue fluxo normal (manda pro SALIX/OSS).
        try {
          final voiceCmd = await IntentLauncher.handleVoiceCommand(s);
          if (voiceCmd.matched) {
            // Mostra na UI um chip "🎙️ comando executado" pra feedback visual.
            final chip = ChatMessage(
              role: Role.system,
              content: voiceCmd.spokenFeedback ?? 'comando executado',
              kind: MessageKind.toolResult,
              toolName: 'voice_command',
              toolStatus: 'ok',
              meta: {'transcript': s},
            );
            setState(() {
              _messages.add(chip);
            });
            _scrollToBottom();
            // ignore: discarded_futures
            _persistChip(chip);
            // TTS feedback
            if (voiceCmd.spokenFeedback != null) {
              _voice.speak(
                voiceCmd.spokenFeedback!,
                lang: p.voice,
                gender: p.voiceGender,
              );
            }
            return;
          }
        } catch (e) {
          debugPrint('[mic] voice command parse failed: $e');
        }
        // fallback: manda pro chat — guard streaming pra evitar _send paralelo.
        if (_streaming) {
          debugPrint('[mic] dropping voice input while streaming: $s');
          return;
        }
        setState(() => _input.text = s);
        _send(s);
      },
    );
  }

  // --------------------------------------------------------------- Builder

  @override
  Widget build(BuildContext context) {
    final p = _persona;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(p?.avatarEmoji ?? '🤖',
                style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
            const Text('SALIX AI'),
            const SizedBox(width: 8),
            if (p != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: IronTheme.magenta.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: IronTheme.magenta),
                ),
                child: Text(p.backend.toUpperCase(),
                    style: const TextStyle(
                        color: IronTheme.magenta, fontSize: 11)),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Buscar nas conversas',
            icon: const Icon(Icons.search),
            onPressed: _openSearch,
          ),
          IconButton(
            tooltip: 'Configurações',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SettingsPage(),
              ));
              _load();
            },
          ),
          IconButton(
            tooltip: 'Memórias',
            icon: const Icon(Icons.psychology_outlined),
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const MemoriesPage(),
              ));
            },
          ),
          IconButton(
            tooltip: 'Capacidades (100+ tools)',
            icon: const Icon(Icons.auto_fix_high),
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ToolsCatalogPage(),
              ));
            },
          ),
          IconButton(
            tooltip: 'Nova conversa',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () async {
              // v7.0.0+32: "Limpar" agora cria nova conversa SQLite (preserva
              // historico antigo no banco — busca ainda acha). Fluxo: usuario
              // ainda ve o feed limpo na UI, mas nada eh deletado do disco.
              final p = _persona;
              if (p != null) {
                try {
                  _convId = await ConversationDb.instance.newConversation(p.id);
                } catch (e) {
                  debugPrint('[chat] newConversation failed: $e');
                }
              }
              if (!mounted) return;
              setState(() {
                _messages.clear();
                _pendingContext.clear();
                if (p != null) {
                  _messages.add(ChatMessage(
                    role: Role.assistant,
                    content:
                        'Nova conversa iniciada. O que voce quer fazer?',
                    status: 'complete',
                  ));
                }
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // v9.0.0+34: explainer pill when SQLite history is unavailable
          // (corrupt file moved aside / IO error / first-time recovery).
          // Chat still works, just doesn't persist this session.
          if (_dbDegraded)
            Container(
              width: double.infinity,
              color: IronTheme.magenta.withOpacity(0.10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      size: 16, color: IronTheme.magenta),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Histórico inacessível, conversa nova iniciada.',
                      style: TextStyle(color: IronTheme.magenta, fontSize: 12),
                    ),
                  ),
                  InkWell(
                    onTap: () => setState(() => _dbDegraded = false),
                    child: const Icon(Icons.close,
                        size: 14, color: IronTheme.magenta),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length +
                  (_listening && _partialVoice.isNotEmpty ? 1 : 0),
              itemBuilder: (_, i) {
                if (i == _messages.length) {
                  return _Bubble(
                    role: Role.user,
                    text: _partialVoice + ' …',
                    streaming: true,
                    persona: p,
                  );
                }
                final m = _messages[i];
                final isHighlighted =
                    _highlightMessageDbId != null && _highlightMessageDbId == m.dbId;
                return _Bubble(
                  role: m.role,
                  text: m.content,
                  streaming: _streaming &&
                      m.role == Role.assistant &&
                      i == _messages.length - 1 &&
                      m.kind == MessageKind.text,
                  persona: p,
                  message: m,
                  highlighted: isHighlighted,
                  onRetry: (m.role == Role.assistant &&
                          m.kind == MessageKind.text &&
                          (m.status == 'partial' || m.status == 'failed') &&
                          !_streaming)
                      ? () => _retryMessage(m)
                      : null,
                );
              },
            ),
          ),
          _composer(),
        ],
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        decoration: const BoxDecoration(
          color: IronTheme.bgPanel,
          border: Border(top: BorderSide(color: Color(0x4400FFFF))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // v8.0.0+33: visible error chip on the composer (Galaxy S24 Ultra
            // typing-not-sending fix). Tells the user EXACTLY why their tap
            // didn't go through (vs the original silent return).
            if (_sendError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: IronTheme.magenta.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: IronTheme.magenta.withOpacity(0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 14, color: IronTheme.magenta),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _sendError!,
                          style: const TextStyle(
                              color: IronTheme.magenta, fontSize: 12),
                        ),
                      ),
                      InkWell(
                        onTap: () => setState(() => _sendError = null),
                        child: const Icon(Icons.close,
                            size: 14, color: IronTheme.magenta),
                      ),
                    ],
                  ),
                ),
              ),
            Row(
          children: [
            IconButton(
              tooltip: 'Anexar arquivo',
              onPressed: (_uploading || _streaming) ? null : _attachDocument,
              icon: _uploading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: IronTheme.cyan))
                  : const Icon(Icons.attach_file, color: IronTheme.cyan),
            ),
            IconButton(
              tooltip: 'Câmera',
              onPressed: (_uploading || _streaming) ? null : _capturePhoto,
              icon: const Icon(Icons.camera_alt, color: IronTheme.cyan),
            ),
            IconButton(
              tooltip: _listening ? 'Parar mic' : 'Falar',
              onPressed: _toggleMic,
              icon: Icon(
                _listening ? Icons.mic : Icons.mic_none,
                color: _listening ? IronTheme.magenta : IronTheme.cyan,
              ),
            ),
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'Pergunte algo...',
                  hintStyle: const TextStyle(color: IronTheme.fgDim),
                  filled: true,
                  fillColor: IronTheme.bgElev,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                ),
              ),
            ),
            // While streaming, swap send → STOP. Tap aborts in-flight request
            // (Wave 1 / C1). Otherwise it's a regular send button.
            _streaming
                ? IconButton(
                    tooltip: 'Parar resposta',
                    onPressed: _stopStream,
                    icon: const Icon(Icons.stop_circle,
                        color: IronTheme.magenta, size: 28),
                  )
                : IconButton(
                    tooltip: 'Enviar',
                    onPressed: _uploading ? null : () => _send(),
                    icon: const Icon(Icons.send, color: IronTheme.cyan),
                  ),
          ],
        ),
          ],
        ),
      ),
    );
  }
}

class _PendingAttachment {
  final String label;
  final String text;
  _PendingAttachment({required this.label, required this.text});
}

class _Bubble extends StatelessWidget {
  final Role role;
  final String text;
  final bool streaming;
  final Persona? persona;
  final ChatMessage? message;
  final bool highlighted;
  final VoidCallback? onRetry;
  const _Bubble({
    required this.role,
    required this.text,
    required this.streaming,
    required this.persona,
    this.message,
    this.highlighted = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    // Specialized rendering for non-text bubbles.
    if (message != null && message!.kind != MessageKind.text) {
      switch (message!.kind) {
        case MessageKind.upload:
          return _SystemChip(
            icon: message!.artifactType == 'image'
                ? Icons.photo_camera
                : Icons.attach_file,
            text: text,
            color: IronTheme.cyan,
          );
        case MessageKind.toolCall:
          {
            // v5.0.0+30 — Onda 13 PII Vault: highlight per-user encrypted memory
            // tools with a 🔒 vault chip + LGPD tooltip.
            final tn = message!.toolName ?? 'tool';
            final isPii = tn.startsWith('user_pii_');
            final label = isPii
                ? '🔒 vault — $tn…'
                : '🔧 chamando $tn…';
            final chip = _SystemChip(
              icon: isPii ? Icons.lock_outline : Icons.build_circle_outlined,
              text: label,
              color: isPii ? IronTheme.cyan : IronTheme.magenta,
              spinning: !isPii,
            );
            return isPii
                ? Tooltip(
                    message: 'Memória pessoal protegida (AES-256-GCM, LGPD)',
                    child: chip,
                  )
                : chip;
          }
        case MessageKind.toolResult:
          final ok = message!.toolStatus == 'ok';
          final raw = message!.meta ?? const <String, dynamic>{};
          final tool = message!.toolName ?? 'tool';
          // Wave 1 / C3 — render concrete proof per-tool so the user sees
          // exactly what shipped (recipient, message_id, filename, etc).
          String txt;
          if (!ok) {
            final err = (raw['error'] ?? text).toString();
            txt = '✗ $tool — ${err.isEmpty ? 'erro' : err}';
          } else if (tool == 'send_email') {
            final to   = (raw['to'] ?? raw['recipient'] ?? '').toString();
            final subj = (raw['subject'] ?? '').toString();
            final id   = (raw['message_id'] ?? raw['id'] ?? '').toString();
            final sid  = id.length > 12 ? id.substring(0, 12) + '…' : id;
            final parts = <String>[];
            if (to.isNotEmpty)   parts.add('pra $to');
            if (subj.isNotEmpty) parts.add('"$subj"');
            if (sid.isNotEmpty)  parts.add('ID: $sid');
            txt = '✓ Email enviado${parts.isEmpty ? '' : ' — ' + parts.join(' · ')}';
          } else if (tool == 'create_xlsx') {
            final fn = (raw['filename'] ?? '').toString();
            txt = '✓ Planilha gerada${fn.isEmpty ? '' : ': $fn'}';
          } else if (tool == 'create_pdf') {
            final fn = (raw['filename'] ?? '').toString();
            txt = '✓ PDF gerado${fn.isEmpty ? '' : ': $fn'}';
          } else if (tool == 'web_search') {
            final n = raw['results_count'];
            txt = '✓ Busca completa${n is num ? ' (${n.toInt()} resultados)' : ''}';
          } else if (tool == 'analyze_image') {
            txt = '✓ Imagem analisada';
          } else if (tool == 'voice_command') {
            txt = '🎙️ ${text.isEmpty ? "comando executado" : text}';
          } else {
            txt = text.isEmpty ? '✓ $tool' : '✓ $tool — $text';
          }
          return _SystemChip(
            icon: ok ? Icons.check_circle : Icons.error_outline,
            text: txt,
            color: ok ? IronTheme.ok : IronTheme.danger,
          );
        case MessageKind.artifact:
          return _ArtifactBubble(
            label: text,
            url: message!.artifactUrl ?? '',
            type: message!.artifactType,
          );
        case MessageKind.text:
          break;
      }
    }

    final isUser = role == Role.user;
    final bubbleColor = highlighted
        ? IronTheme.magenta.withOpacity(0.20)
        : (isUser ? IronTheme.cyan.withOpacity(0.12) : IronTheme.bgElev);
    Color borderColor = isUser ? IronTheme.cyan : IronTheme.magenta;
    if (highlighted) borderColor = IronTheme.magenta;
    if (message?.status == 'partial' || message?.status == 'failed') {
      borderColor = IronTheme.fgDim;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser)
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 4),
              child: Text(persona?.avatarEmoji ?? '🤖',
                  style: const TextStyle(fontSize: 22)),
            ),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: borderColor.withOpacity(highlighted ? 0.9 : 0.4),
                    width: highlighted ? 2 : 1),
              ),
              child: text.isEmpty && streaming
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: IronTheme.cyan))
                  : (text.isEmpty && onRetry != null)
                      ? InkWell(
                          onTap: onRetry,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.refresh,
                                    size: 16, color: IronTheme.magenta),
                                SizedBox(width: 6),
                                Text(
                                  'tentar novamente',
                                  style: TextStyle(
                                    color: IronTheme.magenta,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MarkdownBody(
                          data: text,
                          styleSheet: MarkdownStyleSheet(
                            p: const TextStyle(
                                color: IronTheme.fgBright, fontSize: 15),
                            code: const TextStyle(
                                color: IronTheme.cyan,
                                fontFamily: 'monospace',
                                backgroundColor: Color(0x2200FFFF)),
                          ),
                        ),
                        if (!isUser && !streaming && text.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                InkWell(
                                  onTap: () => _voice.speak(
                                    text,
                                    lang: persona?.voice ?? 'pt-BR',
                                    gender: persona?.voiceGender ?? 'feminina',
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    child: Icon(
                                      Icons.volume_up,
                                      size: 16,
                                      color: IronTheme.cyan,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                InkWell(
                                  onTap: () => _voice.stopSpeaking(),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    child: Icon(
                                      Icons.stop,
                                      size: 16,
                                      color: IronTheme.fgDim,
                                    ),
                                  ),
                                ),
                                if (onRetry != null) ...[
                                  const SizedBox(width: 8),
                                  InkWell(
                                    onTap: onRetry,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.refresh,
                                              size: 16, color: IronTheme.magenta),
                                          SizedBox(width: 4),
                                          Text(
                                            'tentar novamente',
                                            style: TextStyle(
                                              color: IronTheme.magenta,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SystemChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final bool spinning;
  const _SystemChip({
    required this.icon,
    required this.text,
    required this.color,
    this.spinning = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (spinning)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: color),
                )
              else
                Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  style: TextStyle(color: color, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtifactBubble extends StatelessWidget {
  final String label;
  final String url;
  final String? type;
  const _ArtifactBubble({
    required this.label,
    required this.url,
    this.type,
  });

  String get _emoji {
    switch ((type ?? '').toLowerCase()) {
      case 'xlsx':
      case 'csv':
        return '📊';
      case 'pdf':
        return '📄';
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'image':
        return '🖼️';
      case 'docx':
        return '📝';
      default:
        return '📎';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Material(
            color: IronTheme.bgElev,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: IronTheme.cyan.withOpacity(0.4)),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                if (url.isEmpty) return;
                final uri = Uri.parse(url);
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_emoji, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label.isEmpty ? 'Arquivo gerado' : label,
                            style: const TextStyle(
                                color: IronTheme.fgBright,
                                fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'clique pra baixar',
                            style: TextStyle(
                                color: IronTheme.fgDim, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Icon(Icons.download, color: IronTheme.cyan),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
