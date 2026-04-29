import 'dart:convert';

import 'package:android_intent_plus/android_intent.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_intents.dart';
import 'device_control.dart';
import 'routine_engine.dart';

/// Detects assistant-emitted action tokens and dispatches them on-device.
///
/// Supported tokens (any combination, multiple per response):
///
///   [OPEN_INTENT package=com.foo url=https://x]            (legacy)
///   [OPEN_APP app=youtube action=search data={"query":"..."}]
///   [OPEN_PKG package=com.foo.bar]                         (Onda 4)
///   [DEVICE action=set_volume args={"level":0.4,"category":"media"}]
///   [DEVICE action=set_brightness args={"level":0.6}]
///   [DEVICE action=flashlight args={"on":true}]
///   [DEVICE action=vibrate args={"ms":300}]
///   [DEVICE action=open_bluetooth_settings]
///   [DEVICE action=open_wifi_settings]
///   [DEVICE action=open_sound_settings]
///   [ALARM hour=7 minute=30 label="Acordar" skip_ui=true]   (Onda 4)
///   [TIMER seconds=600 label="Pizza"]                       (Onda 4)
///   [CALL number=+5511999999999 direct=false]               (Onda 4)
///   [SMS number=+5511999999999 body="oi"]                   (Onda 4)
///   [ROUTINE tool=set_volume args={"level":0.2}]            (Onda 4 — generic)
///
/// Tokens are always stripped from the visible text. Each dispatch is
/// best-effort — failures are silently swallowed so the chat keeps flowing.
class IntentLauncher {
  static final _legacyPattern =
      RegExp(r'\[OPEN_INTENT(?:\s+package=([^\s\]]+))?(?:\s+url=([^\s\]]+))?\]');

  static final _openAppPattern = RegExp(
    r'\[OPEN_APP\s+app=(\S+?)(?:\s+action=(\S+?))?(?:\s+data=(\{[^\]]*\}))?\]',
    multiLine: true,
  );

  static final _openPkgPattern = RegExp(
    r'\[OPEN_PKG\s+package=([^\s\]]+)\]',
    multiLine: true,
  );

  static final _devicePattern = RegExp(
    r'\[DEVICE\s+action=(\S+?)(?:\s+args=(\{[^\]]*\}))?\]',
    multiLine: true,
  );

  // Onda 4: tokens com argumentos curtos `key=val` ou `args={...}`
  static final _alarmPattern = RegExp(
    r'\[ALARM\s+([^\]]+)\]',
    multiLine: true,
  );
  static final _timerPattern = RegExp(
    r'\[TIMER\s+([^\]]+)\]',
    multiLine: true,
  );
  static final _callPattern = RegExp(
    r'\[CALL\s+([^\]]+)\]',
    multiLine: true,
  );
  static final _smsPattern = RegExp(
    r'\[SMS\s+([^\]]+)\]',
    multiLine: true,
  );
  static final _routinePattern = RegExp(
    r'\[ROUTINE\s+tool=(\S+?)(?:\s+args=(\{[^\]]*\}))?\]',
    multiLine: true,
  );

  /// Scans [text], dispatches every recognised token, returns text stripped
  /// of all tokens.
  static Future<String> dispatch(String text) async {
    String cleaned = text;

    // 1) Legacy [OPEN_INTENT ...]
    for (final m in _legacyPattern.allMatches(text)) {
      final pkg = m.group(1);
      final url = m.group(2);
      try {
        if (url != null && url.isNotEmpty) {
          await launchUrl(Uri.parse(url),
              mode: LaunchMode.externalApplication);
        } else if (pkg != null && pkg.isNotEmpty) {
          final intent = AndroidIntent(
            action: 'android.intent.action.MAIN',
            category: 'android.intent.category.LAUNCHER',
            package: pkg,
            componentName: null,
          );
          await intent.launch();
        }
      } catch (_) {}
      cleaned = cleaned.replaceAll(m.group(0)!, '').trim();
    }

    // 2) [OPEN_APP app=... action=... data={...}]
    for (final m in _openAppPattern.allMatches(text)) {
      final app = m.group(1) ?? '';
      final action = m.group(2) ?? 'open';
      final dataRaw = m.group(3);
      Map<String, dynamic> data = {};
      if (dataRaw != null && dataRaw.isNotEmpty) {
        try {
          final j = jsonDecode(dataRaw);
          if (j is Map) data = Map<String, dynamic>.from(j);
        } catch (_) {}
      }
      try {
        final intent = AppIntents.build(
          appName: app,
          action: action,
          data: data,
        );
        if (intent != null) {
          await DeviceControl.openUrl(intent.url);
        }
      } catch (_) {}
      cleaned = cleaned.replaceAll(m.group(0)!, '').trim();
    }

    // 2b) [OPEN_PKG package=...]
    for (final m in _openPkgPattern.allMatches(text)) {
      final pkg = m.group(1) ?? '';
      if (pkg.isNotEmpty) {
        await RoutineEngine.runOne('open_app_package', {'package': pkg});
      }
      cleaned = cleaned.replaceAll(m.group(0)!, '').trim();
    }

    // 3) [DEVICE action=... args={...}]
    for (final m in _devicePattern.allMatches(text)) {
      final action = m.group(1) ?? '';
      final argsRaw = m.group(2);
      Map<String, dynamic> args = {};
      if (argsRaw != null && argsRaw.isNotEmpty) {
        try {
          final j = jsonDecode(argsRaw);
          if (j is Map) args = Map<String, dynamic>.from(j);
        } catch (_) {}
      }
      await RoutineEngine.runOne(action, args);
      cleaned = cleaned.replaceAll(m.group(0)!, '').trim();
    }

    // 4) [ALARM ...]   args estilo `key=val` ou `args={...}`
    for (final m in _alarmPattern.allMatches(text)) {
      final inner = m.group(1) ?? '';
      final args = _parseInlineArgs(inner);
      await RoutineEngine.runOne('set_alarm', args);
      cleaned = cleaned.replaceAll(m.group(0)!, '').trim();
    }

    // 5) [TIMER ...]
    for (final m in _timerPattern.allMatches(text)) {
      final inner = m.group(1) ?? '';
      final args = _parseInlineArgs(inner);
      await RoutineEngine.runOne('set_timer', args);
      cleaned = cleaned.replaceAll(m.group(0)!, '').trim();
    }

    // 6) [CALL ...]
    for (final m in _callPattern.allMatches(text)) {
      final inner = m.group(1) ?? '';
      final args = _parseInlineArgs(inner);
      await RoutineEngine.runOne('make_call', args);
      cleaned = cleaned.replaceAll(m.group(0)!, '').trim();
    }

    // 7) [SMS ...]
    for (final m in _smsPattern.allMatches(text)) {
      final inner = m.group(1) ?? '';
      final args = _parseInlineArgs(inner);
      await RoutineEngine.runOne('send_sms', args);
      cleaned = cleaned.replaceAll(m.group(0)!, '').trim();
    }

    // 8) [ROUTINE tool=... args={...}]
    for (final m in _routinePattern.allMatches(text)) {
      final tool = m.group(1) ?? '';
      final argsRaw = m.group(2);
      Map<String, dynamic> args = {};
      if (argsRaw != null && argsRaw.isNotEmpty) {
        try {
          final j = jsonDecode(argsRaw);
          if (j is Map) args = Map<String, dynamic>.from(j);
        } catch (_) {}
      }
      if (tool.isNotEmpty) {
        await RoutineEngine.runOne(tool, args);
      }
      cleaned = cleaned.replaceAll(m.group(0)!, '').trim();
    }

    return cleaned;
  }

  /// Parse inline args like `hour=7 minute=30 label="Acordar"` OR
  /// `args={"hour":7,"minute":30}` into a uniform map.
  static Map<String, dynamic> _parseInlineArgs(String inner) {
    inner = inner.trim();
    // Prefer JSON form
    final jsonMatch = RegExp(r'args=(\{[^}]*\})').firstMatch(inner);
    if (jsonMatch != null) {
      try {
        final j = jsonDecode(jsonMatch.group(1)!);
        if (j is Map) return Map<String, dynamic>.from(j);
      } catch (_) {}
    }
    // Fallback: parse k=v pairs (string values may be quoted)
    final out = <String, dynamic>{};
    final pairRe = RegExp(r'(\w+)=("([^"]*)"|(\S+))');
    for (final m in pairRe.allMatches(inner)) {
      final key = m.group(1)!;
      final quoted = m.group(3);
      final raw = m.group(4);
      final value = quoted ?? raw ?? '';
      // coerce numbers and bools
      if (value == 'true') {
        out[key] = true;
      } else if (value == 'false') {
        out[key] = false;
      } else {
        final asInt = int.tryParse(value);
        final asDouble = double.tryParse(value);
        if (asInt != null) {
          out[key] = asInt;
        } else if (asDouble != null) {
          out[key] = asDouble;
        } else {
          out[key] = value;
        }
      }
    }
    return out;
  }
}
