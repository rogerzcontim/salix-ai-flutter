import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/message.dart';

/// Type of stream event yielded by [MetaAgentClient.streamEvents].
enum StreamEventType { delta, toolCall, toolResult, artifact, done, error, resetContent }

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

  /// v7.0.0+32: emitted right before a retry attempt. The chat_page should
  /// clear the partial assistant content so the next stream starts from a
  /// clean slate (avoids duplicated text on transient retries).
  StreamEvent.resetContent()
      : type = StreamEventType.resetContent,
        text = null,
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

  /// Active client for the in-flight request. We hold a reference so the UI
  /// can call [cancel] to abort streaming (Wave 1 / C1 STOP button).
  http.Client? _activeClient;

  /// True while the user pressed STOP (do NOT auto-retry).
  bool _userCanceled = false;

  /// v7.0.0+32: retry tuning. We retry up to 3x on transient network errors,
  /// then surface a SILENT error (status=failed) — chat_page shows a
  /// "↻ tentar novamente" button instead of an "(interrompida)" message.
  static const int _maxRetries = 3;
  static const Duration _retryBaseDelay = Duration(seconds: 1);
  static const Duration _streamHardTimeout = Duration(seconds: 90);

  /// Aborts any in-flight stream. Closing the http.Client tears the connection
  /// down, which propagates client-side cancel to the SSE listener (LineSplitter
  /// errors out, the catch in streamEvents emits an error event and exits).
  void cancel() {
    _userCanceled = true;
    final c = _activeClient;
    _activeClient = null;
    try {
      c?.close();
    } catch (_) {}
  }

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
      }
      // v7.0.0+32: error events are status codes ("user_canceled",
      // "FATAL:..."), not user-visible text. Drop them silently here —
      // callers that care use streamEvents() and inspect the code.
    }
  }

  /// Rich event stream: deltas + tool calls + tool results + artifacts.
  ///
  /// v6.0.0+31: resilient against screen-lock kills (Samsung One UI Doze).
  /// Wraps a single attempt in [_streamOnce] and retries up to [_maxRetries]
  /// times on mid-stream network failures. The server doesn't support resume
  /// cursors, so each retry re-issues the original POST. The UI is signalled
  /// via "[reconectando…]" deltas so the user sees something is happening.
  Stream<StreamEvent> streamEvents({
    required List<ChatMessage> history,
    required String systemPrompt,
    String backend = 'auto',
    String? authToken,
  }) async* {
    _userCanceled = false;
    int attempt = 0;
    bool sawDone = false;

    while (attempt <= _maxRetries && !sawDone && !_userCanceled) {
      // Hard cap on TOTAL wall clock per call so a flaky network can't
      // hang the UI forever.
      // (We don't use Future.timeout on the whole stream because we need
      // to keep yielding events as they arrive; instead we rely on the
      // per-attempt http client timeout below.)
      bool hadAnyEvent = false;
      bool transient = false;
      String? errMsg;

      try {
        await for (final ev in _streamOnce(
          history: history,
          systemPrompt: systemPrompt,
          backend: backend,
          authToken: authToken,
        )) {
          hadAnyEvent = true;
          if (ev.type == StreamEventType.done) {
            sawDone = true;
            yield ev;
            return;
          }
          if (ev.type == StreamEventType.error) {
            // _streamOnce uses .error to signal transient drops. We swallow
            // it here and decide retry vs surface based on error text.
            errMsg = ev.text ?? '';
            transient = _isTransientError(errMsg);
            break; // exit await-for to attempt retry
          }
          yield ev;
        }
      } catch (e) {
        // _streamOnce is supposed to convert all errors to .error events,
        // but a Stream contract violation could still bubble up.
        errMsg = e.toString();
        transient = _isTransientError(errMsg);
      }

      if (sawDone) return;
      if (_userCanceled) {
        // v7.0.0+32: NEVER write "(interrompido)" into the visible content.
        // The chat_page receives this error code and marks the message
        // status=partial, showing a retry button instead.
        yield StreamEvent.error('user_canceled');
        return;
      }

      attempt++;
      final canRetry = transient && attempt <= _maxRetries;
      if (!canRetry) {
        // Out of retries OR not a transient error. We DO NOT write any
        // user-visible text — chat_page will read the error code and
        // toggle the bubble into status=failed (showing "↻ tentar
        // novamente" instead of an apology message).
        final code = (errMsg ?? '').trim().isEmpty ? 'unknown' : (errMsg ?? '');
        yield StreamEvent.error('FATAL:$code');
        return;
      }

      // Reconnecting silently — no visible delta, no "interrompida"-like
      // text. The chat_page keeps showing the spinner while we retry.
      // We emit resetContent so the partial accumulated text is cleared
      // before the fresh stream starts (otherwise the next deltas would
      // append to the previous half-response).
      yield StreamEvent.resetContent();
      // Back off: 1s, 2s, 4s.
      final backoff = _retryBaseDelay * (1 << (attempt - 1));
      try {
        await Future<void>.delayed(backoff);
      } catch (_) {}
      if (_userCanceled) {
        yield StreamEvent.error('user_canceled');
        return;
      }
      hadAnyEvent;
    }

    if (!sawDone && !_userCanceled) {
      yield StreamEvent.error('FATAL:exhausted');
    }
  }

  /// Returns true if the error looks like a transient network/Doze drop
  /// that's worth retrying. False for HTTP 4xx, JSON parse errors, etc.
  bool _isTransientError(String msg) {
    if (msg.isEmpty) return true;
    final lc = msg.toLowerCase();
    // User-cancel marker — never retry.
    if (lc.contains('interrompid')) return false;
    // HTTP non-200 status codes are not transient (server-side rejection).
    if (lc.contains('http 4') || lc.contains('http 5')) {
      // Actually 5xx CAN be transient (server overload). Retry once.
      if (lc.contains('http 5')) return true;
      return false;
    }
    // Connection lost / Doze kill / DNS / timeout — all transient.
    return lc.contains('socket') ||
        lc.contains('connection') ||
        lc.contains('closed') ||
        lc.contains('reset') ||
        lc.contains('timeout') ||
        lc.contains('handshake') ||
        lc.contains('network') ||
        lc.contains('host lookup') ||
        lc.contains('clientexception') ||
        lc.contains('httpexception');
  }

  /// Performs one streaming attempt against the meta-adapter. Errors are
  /// converted to [StreamEvent.error] for the orchestrator to inspect; this
  /// method never throws.
  Stream<StreamEvent> _streamOnce({
    required List<ChatMessage> history,
    required String systemPrompt,
    required String backend,
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
    _activeClient = client;
    String currentEvent = 'message'; // default SSE event name
    try {
      // Per-attempt connect/headers timeout — if the server doesn't even
      // open the stream within 90s we give up and let the orchestrator
      // retry. While streaming, individual reads are bounded by the
      // socket-level keepalive (server sends `:` comments); a Doze kill
      // throws via the LineSplitter, not via this timeout.
      final resp = await client.send(req).timeout(_streamHardTimeout);
      if (resp.statusCode != 200) {
        yield StreamEvent.error('HTTP ${resp.statusCode}');
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
      // Stream ended without [DONE]. That's a transient drop — let the
      // orchestrator decide whether to retry.
      yield StreamEvent.error('connection closed before [DONE]');
    } catch (e) {
      // If user pressed STOP, the client.close() throws ClientException.
      // Surface as "interrompid" so the orchestrator skips retries.
      final msg = e.toString();
      if (_userCanceled || msg.contains('interrompid')) {
        yield StreamEvent.error('interrompido');
      } else if (msg.toLowerCase().contains('closed') ||
          msg.toLowerCase().contains('aborted')) {
        // Could be user-cancel OR Doze kill — distinguish via _userCanceled.
        if (_userCanceled) {
          yield StreamEvent.error('interrompido');
        } else {
          yield StreamEvent.error('connection closed: $msg');
        }
      } else {
        yield StreamEvent.error(msg);
      }
    } finally {
      try {
        client.close();
      } catch (_) {}
      if (identical(_activeClient, client)) _activeClient = null;
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
        // Wave 1 / C3 — server now sends ok=bool and inline fields, normalise
        // both the legacy {status} and the new {ok} shapes into one status.
        String status;
        if (j['ok'] is bool) {
          status = (j['ok'] as bool) ? 'ok' : 'error';
        } else if (j['status'] is String) {
          status = j['status'] as String;
        } else {
          status = j['error'] != null ? 'error' : 'ok';
        }
        // Build a humanised summary line for the chip; the renderer in
        // chat_page also has access to raw via `meta` for the rich view.
        String? text;
        if (name == 'send_email') {
          final to = (j['to'] ?? j['recipient'] ?? '').toString();
          final id = (j['message_id'] ?? j['id'] ?? '').toString();
          if (to.isNotEmpty) {
            text = 'pra $to';
            if (id.isNotEmpty) {
              final sid = id.length > 12 ? id.substring(0, 12) + '…' : id;
              text = '$text (ID: $sid)';
            }
          }
        } else if (name == 'create_xlsx' || name == 'create_pdf') {
          final fn = (j['filename'] ?? '').toString();
          final url = (j['url'] ?? '').toString();
          if (fn.isNotEmpty) {
            text = fn;
          } else if (url.isNotEmpty) {
            text = url.split('/').last;
          }
        } else if (name == 'web_search') {
          final n = j['results_count'];
          if (n is num) text = '${n.toInt()} resultados';
        }
        if (text == null) {
          if (j['result'] is Map) {
            final r = j['result'] as Map;
            if (r['id'] != null) text = 'id: ${r['id']}';
            else if (r['summary'] is String) text = r['summary'] as String;
          } else if (j['result'] is String) {
            text = j['result'] as String;
          } else if (j['message'] is String) {
            text = j['message'] as String;
          }
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
