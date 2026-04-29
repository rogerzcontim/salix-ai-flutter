import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'meta_agent_client.dart';
import 'meta_agent_client_ext.dart';

/// Onda 8 — Accessibility Service.
/// `read_screen_aloud` and `describe_image_audio` rely on backend OCR/Vision
/// + local TTS. Color-blind helper applies a transform layer.
class AccessibilityService {
  AccessibilityService._();
  static final instance = AccessibilityService._();

  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;

  Future<void> _ensureTts() async {
    if (_ttsReady) return;
    try {
      await _tts.setLanguage('pt-BR');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      _ttsReady = true;
    } catch (e) {
      if (kDebugMode) debugPrint('[a11y] tts init error: $e');
    }
  }

  Future<void> speak(String text) async {
    await _ensureTts();
    try { await _tts.speak(text); } catch (e) { if (kDebugMode) debugPrint('[a11y] speak: $e'); }
  }

  Future<void> stopSpeaking() async {
    try { await _tts.stop(); } catch (_) {}
  }

  /// Sends a screenshot bytes payload to backend for OCR, then speaks the
  /// recognized text aloud.
  Future<bool> readScreenAloud({required List<int> screenshotBytes}) async {
    try {
      final text = await MetaAgentClient().a11yScreenOcr(screenshotBytes);
      if (text.trim().isEmpty) return false;
      await speak(text);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[a11y] read_screen error: $e');
      return false;
    }
  }

  /// Describe an image via vision + TTS.
  Future<bool> describeImageAudio({required List<int> imageBytes}) async {
    try {
      final desc = await MetaAgentClient().a11yDescribeImage(imageBytes);
      if (desc.trim().isEmpty) return false;
      await speak(desc);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[a11y] describe_image error: $e');
      return false;
    }
  }
}

/// Color-blind friendly mode (Protanopia / Deuteranopia / Tritanopia).
/// Applied as a global ColorFilter overlay around MaterialApp child if user
/// opted in. Persisted in SharedPreferences.
enum ColorBlindMode { off, protanopia, deuteranopia, tritanopia }

class ColorBlindFilters {
  /// Lookup matrix for ColorFilter.matrix(...) — values from Vienot et al.
  static List<double>? matrixFor(ColorBlindMode m) {
    switch (m) {
      case ColorBlindMode.off:
        return null;
      case ColorBlindMode.protanopia:
        return [
          0.567, 0.433, 0,     0, 0,
          0.558, 0.442, 0,     0, 0,
          0,     0.242, 0.758, 0, 0,
          0,     0,     0,     1, 0,
        ];
      case ColorBlindMode.deuteranopia:
        return [
          0.625, 0.375, 0,    0, 0,
          0.7,   0.3,   0,    0, 0,
          0,     0.3,   0.7,  0, 0,
          0,     0,     0,    1, 0,
        ];
      case ColorBlindMode.tritanopia:
        return [
          0.95, 0.05,  0,     0, 0,
          0,    0.433, 0.567, 0, 0,
          0,    0.475, 0.525, 0, 0,
          0,    0,     0,     1, 0,
        ];
    }
  }
}
