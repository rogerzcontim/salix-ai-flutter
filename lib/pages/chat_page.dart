import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/message.dart';
import '../models/persona.dart';
import '../services/attachments.dart';
import '../services/intent_launcher.dart';
import '../services/meta_agent_client.dart';
import '../services/persona_store.dart';
import '../services/upload_service.dart';
import '../services/voice.dart';
import '../theme.dart';
import 'settings_page.dart';

final _client = MetaAgentClient();
final _voice = VoiceService();
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
    _load();
  }

  Future<void> _load() async {
    final p = await PersonaStore().active();
    if (p != null) {
      await _voice.initTts(p.voice);
    }
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
  }

  // ------------------------------------------------------------------ Send

  Future<void> _send([String? overrideText]) async {
    if (_streaming) return;
    final text = (overrideText ?? _input.text).trim();
    if (text.isEmpty) return;
    _input.clear();
    final p = _persona;
    if (p == null) return;

    setState(() {
      _messages.add(ChatMessage(role: Role.user, content: text));
      _messages.add(ChatMessage(role: Role.assistant, content: ''));
      _streaming = true;
    });
    _scrollToBottom();

    final assistantIdx = _messages.length - 1;
    final history = _messages
        .sublist(0, assistantIdx)
        .where((m) => m.role != Role.system && m.kind == MessageKind.text)
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
            setState(() {
              _messages[assistantIdx].content += ev.text ?? '';
            });
            _scrollToBottom();
            break;

          case StreamEventType.toolCall:
            setState(() {
              _messages.insert(
                assistantIdx,
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
                  ..content = ev.text ?? (ev.toolStatus == 'ok' ? 'enviado' : 'erro');
              } else {
                _messages.insert(
                  _messages.length - 1, // before the active assistant bubble
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
              _messages.insert(
                _messages.length - 1, // before active assistant bubble
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
            setState(() {
              _messages[assistantIdx].content += ev.text ?? '';
            });
            break;
        }
      }
    } catch (e) {
      _messages[assistantIdx].content += '\n[erro: $e]';
    } finally {
      // Dispatch any [OPEN_INTENT] tags then strip them.
      final cleaned =
          await IntentLauncher.dispatch(_messages[assistantIdx].content);
      _messages[assistantIdx].content = cleaned;
      if (mounted) setState(() => _streaming = false);
      // Speak final text in the persona's language and chosen voice gender.
      _voice.speak(
        cleaned,
        lang: p.voice,
        gender: p.voiceGender,
      );
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
    setState(() {
      _uploading = true;
      _messages.add(ChatMessage(
        role: Role.system,
        content: 'Enviando $fileName…',
        kind: MessageKind.upload,
        artifactType: kind,
      ));
    });
    _scrollToBottom();
    final placeholderIdx = _messages.length - 1;

    try {
      final res = await _uploads.upload(path: path, kind: kind);
      _pendingContext.add(_PendingAttachment(
        label: res.fileName,
        text: res.extractedText,
      ));
      final preview = res.extractedText.trim().replaceAll('\n', ' ');
      final shortPreview =
          preview.length > 80 ? '${preview.substring(0, 80)}…' : preview;
      String summary;
      if (kind == 'image') {
        summary = preview.isEmpty
            ? '📷 Foto enviada — nenhum texto identificado'
            : '📷 Foto enviada — texto identificado: $shortPreview';
      } else {
        final pages = res.pages != null ? '${res.pages} páginas' : 'extraído';
        summary =
            '📎 Arquivo anexado: ${res.fileName} ($pages) — texto extraído carregado no contexto';
      }
      setState(() {
        _messages[placeholderIdx]
          ..content = summary
          ..artifactUrl = res.url
          ..meta = {
            'file_id': res.fileId,
            'pages': res.pages,
            'preview': shortPreview,
          };
      });
    } catch (e) {
      setState(() {
        _messages[placeholderIdx]
          ..content = '⚠️ Falha ao enviar $fileName: $e'
          ..toolStatus = 'error';
      });
    } finally {
      if (mounted) setState(() => _uploading = false);
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
    final p = _persona;
    if (p == null) return;
    final localeId = p.voice.replaceAll('-', '_');
    setState(() {
      _listening = true;
      _partialVoice = '';
    });
    await _voice.startListening(
      localeId: localeId,
      onPartial: (s) => setState(() => _partialVoice = s),
      onFinal: (s) {
        setState(() {
          _listening = false;
          _partialVoice = '';
          _input.text = s;
        });
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
            tooltip: 'Limpar',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => setState(() {
              _messages.clear();
              _pendingContext.clear();
            }),
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
            IconButton(
              tooltip: 'Enviar',
              onPressed: _streaming ? null : () => _send(),
              icon: _streaming
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: IronTheme.cyan))
                  : const Icon(Icons.send, color: IronTheme.cyan),
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
          return _SystemChip(
            icon: Icons.build_circle_outlined,
            text: '🔧 chamando ${message!.toolName ?? 'tool'}…',
            color: IronTheme.magenta,
            spinning: true,
          );
        case MessageKind.toolResult:
          final ok = message!.toolStatus == 'ok';
          final txt = ok
              ? '✓ ${message!.toolName ?? 'tool'} ${text.isEmpty ? 'ok' : '($text)'}'
              : '✗ ${message!.toolName ?? 'tool'} ${text.isEmpty ? 'erro' : '($text)'}';
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
