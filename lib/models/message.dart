enum Role { user, assistant, system }

/// Lightweight tag for non-text bubbles (tool calls, tool results, file artifacts,
/// upload notices). Plain text messages keep [MessageKind.text].
enum MessageKind {
  text,
  upload,      // user attached a file/photo (shown as a small system chip)
  toolCall,    // assistant requested a tool execution
  toolResult,  // tool returned a result (ok or error)
  artifact,    // server emitted a downloadable file (xlsx/pdf/png)
}

class ChatMessage {
  final Role role;
  String content;
  final DateTime ts;
  MessageKind kind;

  // Optional per-kind fields. Kept loose on purpose so the SSE pipeline can
  // pass arbitrary tool metadata without forcing a new schema for every tool.
  String? toolName;     // for toolCall / toolResult
  String? toolStatus;   // ok | error | running
  String? artifactUrl;  // for artifact / upload (download link)
  String? artifactType; // pdf | xlsx | png | docx | image
  Map<String, dynamic>? meta;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? ts,
    this.kind = MessageKind.text,
    this.toolName,
    this.toolStatus,
    this.artifactUrl,
    this.artifactType,
    this.meta,
  }) : ts = ts ?? DateTime.now();

  /// Only text messages go into the API history. The server doesn't need to see
  /// our local system chips ("📎 anexei foo.pdf"), only the assistant turns.
  Map<String, dynamic> toApi() => {
        'role': role.name,
        'content': content,
      };

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'content': content,
        'ts': ts.toIso8601String(),
        'kind': kind.name,
        if (toolName != null) 'toolName': toolName,
        if (toolStatus != null) 'toolStatus': toolStatus,
        if (artifactUrl != null) 'artifactUrl': artifactUrl,
        if (artifactType != null) 'artifactType': artifactType,
        if (meta != null) 'meta': meta,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        role: Role.values.firstWhere((r) => r.name == j['role'],
            orElse: () => Role.assistant),
        content: j['content'] ?? '',
        ts: DateTime.tryParse(j['ts'] ?? '') ?? DateTime.now(),
        kind: MessageKind.values.firstWhere(
            (k) => k.name == (j['kind'] ?? 'text'),
            orElse: () => MessageKind.text),
        toolName: j['toolName'],
        toolStatus: j['toolStatus'],
        artifactUrl: j['artifactUrl'],
        artifactType: j['artifactType'],
        meta: (j['meta'] is Map) ? Map<String, dynamic>.from(j['meta']) : null,
      );
}
