import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/message.dart';

/// Type of stream event yielded by [MetaAgentClient.streamEvents].
enum StreamEventType { delta, toolCall, toolResult, artifact, done, error }

/// One event emitted by the SSE stream.
class StreamEvent {
  final StreamEventType type;
  final String? text;          // for delta / error
  final String? toolName;      // for toolCall / toolResult
  final String? toolStatus;    // ok | error | running
  final String? artifactUrl;   // for artifact
  final String? artifactType;  // pdf | xlsx | png | docx
  final String? artifactLabel; // human label (e.g. "Planilha gerada")
  final Map<String, dynamic>? raw;

  StreamEvent.delta(this.text)
      : type = StreamEventType.delta,
        toolName = null,
        toolStatus = null,
        artifactUrl = null,
        artifactType = null,
        artifactLabel = null,
        raw = null;

  StreamEvent.toolCall(this.toolName, {this.raw})
      : type = StreamEventType.toolCall,
        text = null,
        toolStatus = 'running',
        artifactUrl = null,
        artifactType = null,
        artifactLabel = null;

  StreamEvent.toolResult(this.toolName, this.toolStatus, {this.text, this.raw})
      : type = StreamEventType.toolResult,
        artifactUrl = null,
        artifactType = null,
        artifactLabel = null;

  StreamEvent.artifact({
    required this.artifactUrl,
    this.artifactType,
    this.artifactLabel,
    this.raw,
  })  : type = StreamEventType.artifact,
        text = null,
        toolName = null,
        toolStatus = null;

  StreamEvent.done()
      : type = StreamEventType.done,
        text = null,
        toolName = null,
        toolStatus = null,
        artifactUrl = null,
        artifactType = null,
        artifactLabel = null,
        raw = null;

  StreamEvent.error(this.text)
      : type = StreamEventType.error,
        toolName = null,
        toolStatus = null,
        artifactUrl = null,
        artifactType = null,
        artifactLabel = null,
        raw = null;
}

/// SSE client for `/api/meta-agent/run` (meta-agent integrador on :9237 via nginx).
/// Server emits OpenAI-compatible deltas (`data: {choices:[{delta:{content:...}}]}`)
/// plus optional named events:
///
///   event: tool_call
///   data: {"name":"send_email","args":{...}}
///
///   event: tool_result
///   data: {"name":"send_email","status":"ok","result":{"id":"abc"}}
///
///   event: artifact
///   data: {"url":"https://.../foo.xlsx","type":"xlsx","label":"Planilha gerada"}
///
/// Allowed backends: salix | oss | auto. Mistral/GLM/Hermes are intentionally not
/// referenced anywhere.
class MetaAgentClient {
  static const baseUrl = 'https://ironedgeai.com';
  static const endpoint = '$baseUrl/api/meta-agent/run';

  /// Backwards-compatible: yields only text deltas. Kept so older callers keep
  /// working without modification.
  Stream<String> stream({
    required List<ChatMessage> history,
    required String systemPrompt,
    String backend = 'auto',
    String? authToken,
  }) async* {
    await for (final ev in streamEvents(
      history: history,
      systemPrompt: systemPrompt,
      backend: backend,
      authToken: authToken,
    )) {
      if (ev.type == StreamEventType.delta && ev.text != null) {
        yield ev.text!;
      } else if (ev.type == StreamEventType.error && ev.text != null) {
        yield ev.text!;
      }
    }
  }

  /// Rich event stream: deltas + tool calls + tool results + artifacts.
  Stream<StreamEvent> streamEvents({
    required List<ChatMessage> history,
    required String systemPrompt,
    String backend = 'auto',
    String? authToken,
  }) async* {
    final body = jsonEncode({
      'stream': true,
      'backend': backend, // salix | oss | auto
      'system': systemPrompt,
      'messages': history.map((m) => m.toApi()).toList(),
      'tools_enabled': true,
    });

    final req = http.Request('POST', Uri.parse(endpoint));
    req.headers['Content-Type'] = 'application/json';
    req.headers['Accept'] = 'text/event-stream';
    if (authToken != null) {
      req.headers['Authorization'] = 'Bearer $authToken';
    }
    req.body = body;

    final client = http.Client();
    String currentEvent = 'message'; // default SSE event name
    try {
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        yield StreamEvent.error('\n[erro: HTTP ${resp.statusCode}]');
        return;
      }
      final stream =
          resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in stream) {
        if (line.isEmpty) {
          // SSE event terminator — reset event name.
          currentEvent = 'message';
          continue;
        }
        if (line.startsWith(':')) continue; // SSE comment/keepalive
        if (line.startsWith('event:')) {
          currentEvent = line.substring(6).trim();
          continue;
        }
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') {
          yield StreamEvent.done();
          return;
        }

        // Route by event type.
        if (currentEvent == 'tool_call') {
          final ev = _parseToolCall(payload);
          if (ev != null) yield ev;
          continue;
        }
        if (currentEvent == 'tool_result') {
          final ev = _parseToolResult(payload);
          if (ev != null) yield ev;
          continue;
        }
        if (currentEvent == 'artifact') {
          final ev = _parseArtifact(payload);
          if (ev != null) yield ev;
          continue;
        }

        // Default: OpenAI-compatible delta or fallback shapes.
        final delta = _parseDelta(payload);
        if (delta != null) yield StreamEvent.delta(delta);
      }
    } catch (e) {
      yield StreamEvent.error('\n[erro de rede: $e]');
    } finally {
      client.close();
    }
  }

  String? _parseDelta(String payload) {
    try {
      final j = jsonDecode(payload);
      if (j is Map &&
          j['choices'] is List &&
          (j['choices'] as List).isNotEmpty) {
        final delta = (j['choices'][0] as Map)['delta'];
        if (delta is Map && delta['content'] is String) {
          final s = delta['content'] as String;
          if (s.isNotEmpty) return s;
        }
        final msg = (j['choices'][0] as Map)['message'];
        if (msg is Map && msg['content'] is String) {
          return msg['content'] as String;
        }
      }
      if (j is Map) {
        for (final k in const ['delta', 'text', 'content']) {
          if (j[k] is String) return j[k] as String;
        }
      }
    } catch (_) {
      // ignore malformed line
    }
    return null;
  }

  StreamEvent? _parseToolCall(String payload) {
    try {
      final j = jsonDecode(payload);
      if (j is Map) {
        final name = (j['name'] ?? j['tool'] ?? '').toString();
        if (name.isEmpty) return null;
        return StreamEvent.toolCall(name, raw: Map<String, dynamic>.from(j));
      }
    } catch (_) {}
    return null;
  }

  StreamEvent? _parseToolResult(String payload) {
    try {
      final j = jsonDecode(payload);
      if (j is Map) {
        final name = (j['name'] ?? j['tool'] ?? '').toString();
        final status = (j['status'] ?? (j['error'] != null ? 'error' : 'ok'))
            .toString();
        String? text;
        if (j['result'] is Map) {
          final r = j['result'] as Map;
          if (r['id'] != null) text = 'id: ${r['id']}';
          else if (r['summary'] is String) text = r['summary'] as String;
        } else if (j['result'] is String) {
          text = j['result'] as String;
        } else if (j['message'] is String) {
          text = j['message'] as String;
        }
        if (j['error'] is String) text = j['error'] as String;
        return StreamEvent.toolResult(name, status,
            text: text, raw: Map<String, dynamic>.from(j));
      }
    } catch (_) {}
    return null;
  }

  StreamEvent? _parseArtifact(String payload) {
    try {
      final j = jsonDecode(payload);
      if (j is Map) {
        final url = (j['url'] ?? '').toString();
        if (url.isEmpty) return null;
        return StreamEvent.artifact(
          artifactUrl: url,
          artifactType: j['type']?.toString(),
          artifactLabel: j['label']?.toString(),
          raw: Map<String, dynamic>.from(j),
        );
      }
    } catch (_) {}
    return null;
  }
}
