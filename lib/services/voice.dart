// SALIX voice service v1.3.0
// TTS: Edge TTS Microsoft via salix-tools-backend (/api/tools/tts).
//   - Server returns audio_url (mp3); we play with audioplayers.
//   - Markdown stripped server-side AND client-side (defensive).
// STT: speech_to_text package, lang aware.
// Cache: last 12 audios kept in-memory by hash(text,voice) so repeats are instant.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class VoiceService {
  static const String _ttsEndpoint = 'https://ironedgeai.com/api/tools/tts';

  final AudioPlayer _player = AudioPlayer();
  final stt.SpeechToText _stt = stt.SpeechToText();
  bool _sttReady = false;

  // LRU cache: hash → audio_url
  final LinkedHashMap<String, String> _cache = LinkedHashMap<String, String>();
  static const int _cacheMax = 12;

  // ---------- markdown strip (client defensive) ----------

  static final RegExp _reCodeFence =
      RegExp(r'```[a-zA-Z0-9_-]*\n?(.*?)```', dotAll: true);
  static final RegExp _reInlineCode = RegExp(r'`([^`]+)`');
  static final RegExp _reBoldStar = RegExp(r'\*\*([^*]+)\*\*');
  static final RegExp _reBoldUnder = RegExp(r'__([^_]+)__');
  static final RegExp _reItalicStar = RegExp(r'(^|[^*])\*([^*\n]+)\*');
  static final RegExp _reItalicUnd = RegExp(r'(^|[^_])_([^_\n]+)_');
  static final RegExp _reStrike = RegExp(r'~~([^~]+)~~');
  static final RegExp _reLink = RegExp(r'\[([^\]]+)\]\([^)]+\)');
  static final RegExp _reImage = RegExp(r'!\[[^\]]*\]\([^)]+\)');
  static final RegExp _reHeading = RegExp(r'^#{1,6}\s+', multiLine: true);
  static final RegExp _reBlockQuote = RegExp(r'^>\s?', multiLine: true);
  static final RegExp _reListBullet = RegExp(r'^\s*[-*+]\s+', multiLine: true);
  static final RegExp _reListNum = RegExp(r'^\s*\d+\.\s+', multiLine: true);
  static final RegExp _reHRule = RegExp(r'^\s*[-*_]{3,}\s*$', multiLine: true);
  static final RegExp _reMultiSpace = RegExp(r'[ \t]+');
  static final RegExp _reMultiNL = RegExp(r'\n{3,}');

  static String stripMarkdown(String s) {
    if (s.isEmpty) return s;
    s = s.replaceAllMapped(_reCodeFence, (m) => m.group(1) ?? '');
    s = s.replaceAll(_reImage, '');
    s = s.replaceAllMapped(_reLink, (m) => m.group(1) ?? '');
    s = s.replaceAllMapped(_reInlineCode, (m) => m.group(1) ?? '');
    s = s.replaceAllMapped(_reBoldStar, (m) => m.group(1) ?? '');
    s = s.replaceAllMapped(_reBoldUnder, (m) => m.group(1) ?? '');
    s = s.replaceAllMapped(
        _reItalicStar, (m) => '${m.group(1) ?? ''}${m.group(2) ?? ''}');
    s = s.replaceAllMapped(
        _reItalicUnd, (m) => '${m.group(1) ?? ''}${m.group(2) ?? ''}');
    s = s.replaceAllMapped(_reStrike, (m) => m.group(1) ?? '');
    s = s.replaceAll(_reHeading, '');
    s = s.replaceAll(_reBlockQuote, '');
    s = s.replaceAll(_reListBullet, '');
    s = s.replaceAll(_reListNum, '');
    s = s.replaceAll(_reHRule, '');
    s = s.replaceAll('**', '');
    s = s.replaceAll('__', '');
    s = s.replaceAll('~~', '');
    s = s.replaceAll('`', '');
    s = s.replaceAll(_reMultiSpace, ' ');
    s = s.replaceAll(_reMultiNL, '\n\n');
    return s.trim();
  }

  // ---------- TTS ----------

  /// Speak [text] via Edge TTS in [lang] ('pt-BR' | 'en-US' | 'it-IT').
  /// [gender] is 'feminina' or 'masculina'. Markdown is stripped before TTS.
  Future<void> speak(
    String text, {
    String lang = 'pt-BR',
    String gender = 'feminina',
  }) async {
    final clean = stripMarkdown(text);
    if (clean.trim().isEmpty) return;

    // Cap: 4000 chars on client to avoid huge POSTs.
    final capped = clean.length > 4000 ? '${clean.substring(0, 4000)}…' : clean;

    final cacheKey = '${lang}_${gender}_${capped.hashCode}';
    String? url = _cache[cacheKey];

    if (url == null) {
      try {
        final r = await http
            .post(
              Uri.parse(_ttsEndpoint),
              headers: const {'Content-Type': 'application/json; charset=utf-8'},
              body: jsonEncode({
                'text': capped,
                'lang': lang,
                'voice': gender,
              }),
            )
            .timeout(const Duration(seconds: 30));
        if (r.statusCode != 200) return;
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        url = j['audio_url'] as String?;
        if (url == null || url.isEmpty) return;
        _cache[cacheKey] = url;
        if (_cache.length > _cacheMax) {
          _cache.remove(_cache.keys.first);
        }
      } catch (_) {
        return;
      }
    }

    try {
      await _player.stop();
      await _player.play(UrlSource(url));
    } catch (_) {
      // ignore playback errors silently
    }
  }

  /// Stop currently playing TTS (does NOT clear cache).
  Future<void> stopSpeaking() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> pauseSpeaking() async {
    try {
      await _player.pause();
    } catch (_) {}
  }

  Future<void> resumeSpeaking() async {
    try {
      await _player.resume();
    } catch (_) {}
  }

  /// Returns true while audio is playing.
  Future<bool> isPlaying() async {
    return _player.state == PlayerState.playing;
  }

  // ---------- STT ----------

  /// v10.0.0+35: MethodChannel to wake-word service so we can pause its
  /// AudioRecord while the foreground STT grabs the mic. Fixes Bug 1
  /// (Galaxy S24 Ultra "nao esta permitindo gravar").
  static const MethodChannel _wakeChan = MethodChannel('salix.wake_word');

  /// v10.0.0+35: track last error so the chat page can surface it.
  String? lastSttError;

  Future<bool> initStt() async {
    if (_sttReady) return true;
    _sttReady = await _stt.initialize(
      onError: (e) {
        lastSttError = '${e.errorMsg}';
        if (kDebugMode) debugPrint('[stt] error: ${e.errorMsg} permanent=${e.permanent}');
      },
      onStatus: (s) {
        if (kDebugMode) debugPrint('[stt] status: $s');
      },
    );
    if (!_sttReady) {
      lastSttError = 'STT engine init failed (verifique Google App / OK Google).';
    }
    return _sttReady;
  }

  Future<void> startListening({
    required void Function(String partial) onPartial,
    required void Function(String finalText) onFinal,
    String localeId = 'pt_BR',
  }) async {
    lastSttError = null;
    // v10.0.0+35: explicit permission check (Bug 1).
    try {
      final st = await Permission.microphone.status;
      if (!st.isGranted) {
        final r = await Permission.microphone.request();
        if (!r.isGranted) {
          lastSttError = 'Permissao de microfone negada.';
          return;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[stt] perm check failed: $e');
    }

    // Pause wake-word AudioRecord BEFORE attempting to grab the mic.
    // pauseForForegroundMic is best-effort — failure (e.g. WW not running)
    // is fine and we proceed.
    try {
      await _wakeChan.invokeMethod('pauseForForegroundMic');
    } catch (e) {
      if (kDebugMode) debugPrint('[stt] pauseForForegroundMic failed (ok): $e');
    }
    // Give the wake-word service ~250ms to actually release the recorder.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final ok = await initStt();
    if (!ok) {
      // Resume wake word if init failed.
      try { await _wakeChan.invokeMethod('resumeAfterForegroundMic'); } catch (_) {}
      return;
    }
    try {
      await _stt.listen(
        localeId: localeId,
        listenOptions: stt.SpeechListenOptions(partialResults: true),
        onResult: (r) {
          if (r.finalResult) {
            onFinal(r.recognizedWords);
          } else {
            onPartial(r.recognizedWords);
          }
        },
      );
    } catch (e) {
      lastSttError = 'STT.listen falhou: $e';
      if (kDebugMode) debugPrint('[stt] listen failed: $e');
      try { await _wakeChan.invokeMethod('resumeAfterForegroundMic'); } catch (_) {}
    }
  }

  Future<void> stopListening() async {
    try {
      await _stt.stop();
    } catch (_) {}
    // v10.0.0+35: resume wake-word capture.
    try {
      await _wakeChan.invokeMethod('resumeAfterForegroundMic');
    } catch (e) {
      if (kDebugMode) debugPrint('[stt] resumeAfterForegroundMic failed: $e');
    }
  }

  bool get isListening => _stt.isListening;

  // ---------- compat ----------

  /// Kept for source compatibility with v1.2.0; no-op (TTS init is per-call).
  Future<void> initTts(String voice) async {}
}
