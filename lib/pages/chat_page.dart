import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/message.dart';
import '../models/persona.dart';
import '../services/attachments.dart';
import '../services/crash_reporter.dart';
import '../services/intent_launcher.dart';
import '../services/meta_agent_client.dart';
import '../services/persona_store.dart';
import '../services/upload_service.dart';
import '../services/voice.dart';
import '../services/wake_word.dart';
import '../theme.dart';
import 'memories_page.dart';
import 'settings_page.dart';
import 'tools_catalog_page.dart';

final _client = MetaAgentClient();
final _voice = VoiceService();
final _wake = WakeWordService();
final _attachments = AttachmentsService();
final _uploads = UploadService();

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});
  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
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

  @override
  void initState() {
    super.initState();
    // v1.8.0: defer ALL side-effects to post-first-frame; never block initState.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _load();
      } catch (e, st) {
        debugPrint('[chat] _load failed: $e\n$st');
      }
    });
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
    // Restore in-memory history per persona so re-opening the app feels
    // continuous (Wave 1 / C4). Each persona has its own bucket.
    if (p != null) {
      try {
        await _restoreMessages(p.id);
      } catch (e) {
        debugPrint('[chat] restoreMessages failed: $e');
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
        ));
      }
    });
    if (_messages.isNotEmpty) {
      // best-effort; never block UI
      // ignore: discarded_futures
      _persistMessages();
    }
    // Onda 3 — wake word "Oi SALIX" só se opt-in. Best-effort; nunca crasha.
    try {
      await _maybeStartWakeWord();
    } catch (e) {
      debugPrint('[chat] maybeStartWakeWord failed: $e');
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
    _wake.stop();
    super.dispose();
  }

  // -------------------------------------------------- Persistence (Wave 1 C4)

  String? _persistKey(String personaId) => 'chat.history.$personaId.v1';

  Future<void> _restoreMessages(String personaId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _persistKey(personaId);
      if (key == null) return;
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final restored = <ChatMessage>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          restored.add(ChatMessage.fromJson(item));
        }
      }
      // Cap restore at 200 entries — anything older will be available on a
      // hypothetical /api/messages call but the local cache stays small.
      if (restored.length > 200) {
        restored.removeRange(0, restored.length - 200);
      }
      _messages
        ..clear()
        ..addAll(restored);
    } catch (e) {
      // Corrupted snapshot — just start fresh.
      // ignore: avoid_print
      print('[chat] restore failed: $e');
    }
  }

  Future<void> _persistMessages() async {
    final p = _persona;
    if (p == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _persistKey(p.id);
      if (key == null) return;
      // Only persist text + tool/artifact bubbles. Drop transient streaming
      // state (the streaming flag isn't stored — content is the truth).
      final tail = _messages.length > 200
          ? _messages.sublist(_messages.length - 200)
          : _messages;
      final encoded =
          jsonEncode(tail.map((m) => m.toJson()).toList(growable: false));
      await prefs.setString(key, encoded);
    } catch (e) {
      // ignore: avoid_print
      print('[chat] persist failed: $e');
    }
  }

  // ------------------------------------------------------------------ Send

  Future<void> _send([String? overrideText]) async {
    if (_streaming) return;
    final text = (overrideText ?? _input.text).trim();
    if (text.isEmpty) return;
    _input.clear();
    final p = _persona;
    if (p == null) return;

    // v2.1.0: hold ChatMessage references directly instead of indexes.
    // Indexes are invalidated when _messages is mutated by other paths
    // (clear, _restoreMessages, persona switch, parallel _send) — that
    // caused RangeError "Only valid value is 0: 2" reported via
    // CrashReporter on v2.0.0+21.
    final userMsg = ChatMessage(role: Role.user, content: text);
    final assistantMsg = ChatMessage(role: Role.assistant, content: '');

    CrashReporter.info('_send.start');

    setState(() {
      _messages.add(userMsg);
      _messages.add(assistantMsg);
      _streaming = true;
    });
    _scrollToBottom();

    // History is everything before the assistantMsg placeholder.
    // Filter by reference identity, not index, so concurrent mutations
    // can't shift the boundary.
    final history = _messages
        .where((m) =>
            !identical(m, assistantMsg) &&
            m.role != Role.system &&
            m.kind == MessageKind.text)
        .toList();

    // Inject extracted text from any pending attachments into the system prompt
    // for this turn only, then clear so future turns don't repeat it.
    final systemPrompt = _composeSystemPrompt(p);
    _pendingContext.clear();

    try {
      await for (final ev in _client.streamEvents(
        history: history,
        systemPrompt: systemPrompt,
        backend: p.backend,
      )) {
        if (!mounted) return;
        switch (ev.type) {
          case StreamEventType.delta:
            // assistantMsg is an object reference — always valid even
            // if _messages was mutated, cleared, or shifted around.
            setState(() {
              assistantMsg.content += ev.text ?? '';
            });
            _scrollToBottom();
            break;

          case StreamEventType.toolCall:
            setState(() {
              // Insert tool-call chip just BEFORE the assistant bubble.
              // Find current position by reference; if assistantMsg was
              // removed (clear), append at end as best-effort.
              final pos = _messages.indexOf(assistantMsg);
              final insertAt = pos >= 0 ? pos : _messages.length;
              _messages.insert(
                insertAt,
                ChatMessage(
                  role: Role.system,
                  content: ev.toolName ?? 'tool',
                  kind: MessageKind.toolCall,
                  toolName: ev.toolName,
                  toolStatus: 'running',
                  meta: ev.raw,
                ),
              );
            });
            _scrollToBottom();
            break;

          case StreamEventType.toolResult:
            // Find the most recent matching toolCall and update it; if not
            // found, drop a fresh result chip.
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
                  ..content = ev.text ?? (ev.toolStatus == 'ok' ? 'enviado' : 'erro')
                  // Wave 1 / C3: keep the raw payload so the chip can show
                  // concrete proof (email message_id, file URL, etc).
                  ..meta = ev.raw;
              } else {
                final pos = _messages.indexOf(assistantMsg);
                final insertAt = pos >= 0 ? pos : _messages.length;
                _messages.insert(
                  insertAt, // before the active assistant bubble
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
            _scrollToBottom();
            break;

          case StreamEventType.artifact:
            setState(() {
              final pos = _messages.indexOf(assistantMsg);
              final insertAt = pos >= 0 ? pos : _messages.length;
              _messages.insert(
                insertAt, // before active assistant bubble
                ChatMessage(
                  role: Role.system,
                  content: ev.artifactLabel ?? 'Arquivo gerado',
                  kind: MessageKind.artifact,
                  artifactUrl: ev.artifactUrl,
                  artifactType: ev.artifactType,
                  meta: ev.raw,
                ),
              );
            });
            _scrollToBottom();
            break;

          case StreamEventType.done:
            break;

          case StreamEventType.error:
            if (mounted) {
              setState(() {
                assistantMsg.content += ev.text ?? '';
              });
            }
            break;
        }
      }
    } catch (e, s) {
      CrashReporter.report(e, s, context: '_send.catch');
      assistantMsg.content += '\n[erro: $e]';
    } finally {
      // Dispatch any [OPEN_INTENT] tags then strip them.
      final cleaned = await IntentLauncher.dispatch(assistantMsg.content);
      assistantMsg.content = cleaned;
      if (mounted) setState(() => _streaming = false);
      // Persist the final history to disk so opening the app later restores
      // exactly what the user sees right now (Wave 1 / C4).
      await _persistMessages();
      // Speak final text in the persona's language and chosen voice gender.
      // Skip if the response was canceled (just an "[interrompido]" marker).
      if (!cleaned.trim().endsWith('[interrompido]')) {
        _voice.speak(
          cleaned,
          lang: p.voice,
          gender: p.voiceGender,
        );
      }
      CrashReporter.info('_send.done');
    }
  }

  /// User pressed STOP — abort the in-flight stream. The MetaAgentClient
  /// closes its http.Client, which propagates a tear-down to the server, and
  /// the server's r.Context() cancels the upstream request to the meta-adapter.
  void _stopStream() {
    if (!_streaming) return;
    _client.cancel();
    _voice.stopSpeaking();
    setState(() {
      _streaming = false;
      // Mark the active assistant bubble as interrupted so the user sees
      // immediate feedback (the SSE error event will arrive a moment later
      // and append "[interrompido]").
      if (_messages.isNotEmpty &&
          _messages.last.role == Role.assistant &&
          _messages.last.kind == MessageKind.text) {
        if (!_messages.last.content.contains('[interrompido')) {
          _messages.last.content += '\n_(interrompido)_';
        }
      }
    });
    _persistMessages();
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
            setState(() {
              _messages.add(ChatMessage(
                role: Role.system,
                content: voiceCmd.spokenFeedback ?? 'comando executado',
                kind: MessageKind.toolResult,
                toolName: 'voice_command',
                toolStatus: 'ok',
                meta: {'transcript': s},
              ));
            });
            _scrollToBottom();
            await _persistMessages();
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
            tooltip: 'Limpar',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () {
              setState(() {
                _messages.clear();
                _pendingContext.clear();
              });
              _persistMessages(); // wipe disk too
            },
          ),
        ],
      ),
      body: Column(
        children: [
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
                return _Bubble(
                  role: m.role,
                  text: m.content,
                  streaming: _streaming &&
                      m.role == Role.assistant &&
                      i == _messages.length - 1 &&
                      m.kind == MessageKind.text,
                  persona: p,
                  message: m,
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
        child: Row(
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
  const _Bubble({
    required this.role,
    required this.text,
    required this.streaming,
    required this.persona,
    this.message,
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
    final bubbleColor =
        isUser ? IronTheme.cyan.withOpacity(0.12) : IronTheme.bgElev;
    final borderColor = isUser ? IronTheme.cyan : IronTheme.magenta;

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
                border: Border.all(color: borderColor.withOpacity(0.4)),
              ),
              child: text.isEmpty && streaming
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: IronTheme.cyan))
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
