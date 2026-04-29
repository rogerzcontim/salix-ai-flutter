import 'dart:convert';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
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

  // -------------------------------------------------------------------------
  // v1.6.0 — Natural-language voice command parser (sempre ativo)
  // -------------------------------------------------------------------------
  //
  // Recebe a transcrição STT já em texto livre PT-BR e tenta casar com um
  // padrão de comando local. Se casar, executa direto (intent/device control)
  // e retorna VoiceCommandResult(matched=true, spokenFeedback="...") — o caller
  // (chat_page) NÃO envia esse texto pro chat (evita poluir o histórico
  // com "abre Youtube"), e fala o feedback via TTS.
  //
  // Se NÃO casar, retorna matched=false e o caller manda pro chat normal.
  static Future<VoiceCommandResult> handleVoiceCommand(String text) async {
    final raw = text.trim();
    if (raw.isEmpty) return const VoiceCommandResult(matched: false);
    // normaliza: lowercase + remove acento (versão simples)
    final norm = _normalize(raw);

    try {
      // ---- abre/abrir <app> ----
      final mOpen = RegExp(r'^(?:abr[ae]|abrir|inicia|inicie|inicia r|launch)\s+(.+)$')
          .firstMatch(norm);
      if (mOpen != null) {
        final app = mOpen.group(1)!.trim();
        final ok = await _openApp(app);
        return VoiceCommandResult(
          matched: true,
          spokenFeedback: ok ? 'Abrindo $app' : 'Não consegui abrir $app',
        );
      }

      // ---- lanterna ----
      if (RegExp(r'^(lig[ae]r?\s+)?lanterna(?:\s+lig[ae]r?)?$').hasMatch(norm) ||
          RegExp(r'^(?:ativ[ae]r?|acende[r]?)\s+lanterna$').hasMatch(norm)) {
        await RoutineEngine.runOne('flashlight', {'on': true});
        return const VoiceCommandResult(
            matched: true, spokenFeedback: 'Lanterna ligada');
      }
      if (RegExp(r'^desliga[r]?\s+lanterna$').hasMatch(norm) ||
          RegExp(r'^lanterna\s+desliga[r]?$').hasMatch(norm) ||
          RegExp(r'^apag[ae]r?\s+lanterna$').hasMatch(norm)) {
        await RoutineEngine.runOne('flashlight', {'on': false});
        return const VoiceCommandResult(
            matched: true, spokenFeedback: 'Lanterna desligada');
      }

      // ---- volume ----
      if (RegExp(r'^(?:aument[ae]r?|sub[ae]r?)\s+volume$').hasMatch(norm) ||
          RegExp(r'^volume\s+max(?:imo)?$').hasMatch(norm)) {
        await RoutineEngine.runOne('set_volume', {'level': 1.0});
        return const VoiceCommandResult(
            matched: true, spokenFeedback: 'Volume no máximo');
      }
      if (RegExp(r'^(?:diminu[ae]r?|abaix[ae]r?)\s+volume$').hasMatch(norm) ||
          RegExp(r'^volume\s+(?:baix[oa]|min(?:imo)?)$').hasMatch(norm)) {
        await RoutineEngine.runOne('set_volume', {'level': 0.2});
        return const VoiceCommandResult(
            matched: true, spokenFeedback: 'Volume baixo');
      }
      if (RegExp(r'^(?:mudo|silen[cs]i[oa]r?|sile?nciar?|tira[r]?\s+som)$')
          .hasMatch(norm)) {
        await RoutineEngine.runOne('mute', {});
        return const VoiceCommandResult(
            matched: true, spokenFeedback: 'No mudo');
      }
      // volume X% / volume X
      final mVol = RegExp(r'^volume\s+(\d{1,3})(?:\s*%|\s+por\s+cento)?$')
          .firstMatch(norm);
      if (mVol != null) {
        final pct = int.parse(mVol.group(1)!).clamp(0, 100);
        await RoutineEngine.runOne('set_volume', {'level': pct / 100.0});
        return VoiceCommandResult(
            matched: true, spokenFeedback: 'Volume em $pct por cento');
      }

      // ---- brilho ----
      if (RegExp(r'^(?:aument[ae]r?|sub[ae]r?)\s+brilho$').hasMatch(norm)) {
        await RoutineEngine.runOne('set_brightness', {'level': 1.0});
        return const VoiceCommandResult(
            matched: true, spokenFeedback: 'Brilho no máximo');
      }
      if (RegExp(r'^(?:diminu[ae]r?|abaix[ae]r?)\s+brilho$').hasMatch(norm)) {
        await RoutineEngine.runOne('set_brightness', {'level': 0.3});
        return const VoiceCommandResult(
            matched: true, spokenFeedback: 'Brilho baixo');
      }
      final mBri = RegExp(r'^brilho\s+(\d{1,3})(?:\s*%|\s+por\s+cento)?$')
          .firstMatch(norm);
      if (mBri != null) {
        final pct = int.parse(mBri.group(1)!).clamp(0, 100);
        await RoutineEngine.runOne(
            'set_brightness', {'level': pct / 100.0});
        return VoiceCommandResult(
            matched: true, spokenFeedback: 'Brilho em $pct por cento');
      }

      // ---- vibrar ----
      if (RegExp(r'^vibr[ae]r?$').hasMatch(norm) ||
          RegExp(r'^vibracao$').hasMatch(norm)) {
        await RoutineEngine.runOne('vibrate', {'ms': 400});
        return const VoiceCommandResult(
            matched: true, spokenFeedback: 'Vibrando');
      }

      // ---- timer N (minuto|min|segundo|s) ----
      final mTimer = RegExp(
              r'^(?:cria[r]?\s+)?timer\s+(?:de\s+)?(\d+)\s*(minuto|minutos|min|m|segundo|segundos|seg|s|hora|horas|h)?$')
          .firstMatch(norm);
      if (mTimer != null) {
        final n = int.parse(mTimer.group(1)!);
        final unit = (mTimer.group(2) ?? 'minuto').toLowerCase();
        int seconds;
        if (unit.startsWith('h')) {
          seconds = n * 3600;
        } else if (unit.startsWith('s')) {
          seconds = n;
        } else {
          seconds = n * 60;
        }
        if (seconds > 0 && seconds < 86400) {
          await RoutineEngine.runOne('set_timer', {'seconds': seconds});
          return VoiceCommandResult(
              matched: true,
              spokenFeedback: 'Timer de $n ${unit.startsWith("s") ? "segundos" : unit.startsWith("h") ? "horas" : "minutos"}');
        }
      }

      // ---- alarme HH:MM (ou HH e MM separados) ----
      final mAlarm = RegExp(
              r'^(?:cria[r]?\s+)?alarme\s+(?:para\s+)?(?:as\s+)?(\d{1,2})[:h ](\d{2})$')
          .firstMatch(norm);
      if (mAlarm != null) {
        final h = int.parse(mAlarm.group(1)!).clamp(0, 23);
        final m = int.parse(mAlarm.group(2)!).clamp(0, 59);
        await RoutineEngine.runOne('set_alarm', {'hour': h, 'minute': m});
        return VoiceCommandResult(
            matched: true,
            spokenFeedback:
                'Alarme criado pras ${h.toString().padLeft(2, '0')} e ${m.toString().padLeft(2, '0')}');
      }
      final mAlarmH = RegExp(
              r'^(?:cria[r]?\s+)?alarme\s+(?:para\s+)?(?:as\s+)?(\d{1,2})\s*(?:hora|horas|h)$')
          .firstMatch(norm);
      if (mAlarmH != null) {
        final h = int.parse(mAlarmH.group(1)!).clamp(0, 23);
        await RoutineEngine.runOne('set_alarm', {'hour': h, 'minute': 0});
        return VoiceCommandResult(
            matched: true,
            spokenFeedback: 'Alarme criado pras $h horas');
      }

      // ---- chamar / ligar pra <numero> ----
      final mCall = RegExp(
              r'^(?:cham[ae]r?|lig[ae]r?\s+(?:pra|para))\s+([\d\s\-+]+)$')
          .firstMatch(norm);
      if (mCall != null) {
        final num = mCall.group(1)!.replaceAll(RegExp(r'[^0-9+]'), '');
        if (num.isNotEmpty) {
          await RoutineEngine.runOne('make_call', {'number': num});
          return VoiceCommandResult(
              matched: true, spokenFeedback: 'Chamando $num');
        }
      }

      // ---- enviar SMS para <numero> <texto opcional> ----
      final mSms = RegExp(
              r'^(?:envi[ae]r?\s+)?(?:sms|mensagem)\s+(?:para|pra)\s+([\d\s\-+]+?)(?:\s+(.+))?$')
          .firstMatch(norm);
      if (mSms != null) {
        final num =
            mSms.group(1)!.replaceAll(RegExp(r'[^0-9+]'), '');
        final body = mSms.group(2);
        if (num.isNotEmpty) {
          await RoutineEngine.runOne(
              'send_sms', {'number': num, if (body != null) 'body': body});
          return VoiceCommandResult(
              matched: true, spokenFeedback: 'Compositor SMS aberto');
        }
      }

      // ---- pesquisa <termo> ----
      final mSearch = RegExp(
              r'^(?:pesquis[ae]r?|busc[ae]r?|googl[ae]r?)\s+(?:por\s+)?(.+)$')
          .firstMatch(norm);
      if (mSearch != null) {
        final q = raw
            .replaceFirst(
                RegExp(r'^(?:pesquis[ae]r?|busc[ae]r?|googl[ae]r?)\s+(?:por\s+)?',
                    caseSensitive: false),
                '')
            .trim();
        final url =
            'https://www.google.com/search?q=${Uri.encodeComponent(q)}';
        await DeviceControl.openUrl(url);
        return VoiceCommandResult(
            matched: true, spokenFeedback: 'Pesquisando $q');
      }

      // ---- bluetooth / wifi / som settings ----
      if (RegExp(r'^(?:abr[ae]r?\s+)?bluetooth$').hasMatch(norm)) {
        await RoutineEngine.runOne('open_bluetooth_settings', {});
        return const VoiceCommandResult(
            matched: true, spokenFeedback: 'Abrindo Bluetooth');
      }
      if (RegExp(r'^(?:abr[ae]r?\s+)?wi[ -]?fi$').hasMatch(norm)) {
        await RoutineEngine.runOne('open_wifi_settings', {});
        return const VoiceCommandResult(
            matched: true, spokenFeedback: 'Abrindo Wi-Fi');
      }

    } catch (e, st) {
      if (kDebugMode) debugPrint('[voicecmd] err: $e\n$st');
    }
    return const VoiceCommandResult(matched: false);
  }

  /// Resolve um nome de app (livre, falado pelo user) num deep link / intent.
  /// Retorna true se conseguiu disparar.
  static Future<bool> _openApp(String spoken) async {
    final s = _normalize(spoken);
    // 1) Aliases conhecidos -> AppIntents.build (deep link web fallback)
    final knownDeep = {
      'youtube': ('youtube', 'search'),
      'yt': ('youtube', 'search'),
      'spotify': ('spotify', 'search'),
      'whatsapp': ('whatsapp', 'send'),
      'wpp': ('whatsapp', 'send'),
      'maps': ('maps', 'search'),
      'mapa': ('maps', 'search'),
      'google maps': ('maps', 'search'),
    };
    for (final entry in knownDeep.entries) {
      if (s == entry.key || s.startsWith('${entry.key} ')) {
        final intent = AppIntents.build(
          appName: entry.value.$1,
          action: entry.value.$2,
          data: const {},
        );
        if (intent != null) {
          await DeviceControl.openUrl(intent.url);
          return true;
        }
      }
    }
    // 2) Aliases nome -> package (Android open package)
    final pkg = _packageForName(s);
    if (pkg != null) {
      try {
        final intent = AndroidIntent(
          action: 'android.intent.action.MAIN',
          category: 'android.intent.category.LAUNCHER',
          package: pkg,
        );
        await intent.launch();
        return true;
      } catch (_) {}
    }
    // 3) URL literal
    if (s.startsWith('http://') || s.startsWith('https://')) {
      await DeviceControl.openUrl(spoken);
      return true;
    }
    // 4) Fallback: Google search pelo nome
    final url =
        'https://www.google.com/search?q=${Uri.encodeComponent(spoken)}';
    await DeviceControl.openUrl(url);
    return true;
  }

  static String? _packageForName(String norm) {
    const map = <String, String>{
      'youtube': 'com.google.android.youtube',
      'yt': 'com.google.android.youtube',
      'spotify': 'com.spotify.music',
      'whatsapp': 'com.whatsapp',
      'wpp': 'com.whatsapp',
      'instagram': 'com.instagram.android',
      'insta': 'com.instagram.android',
      'telegram': 'org.telegram.messenger',
      'tg': 'org.telegram.messenger',
      'gmail': 'com.google.android.gm',
      'email': 'com.google.android.gm',
      'chrome': 'com.android.chrome',
      'firefox': 'org.mozilla.firefox',
      'maps': 'com.google.android.apps.maps',
      'google maps': 'com.google.android.apps.maps',
      'mapa': 'com.google.android.apps.maps',
      'waze': 'com.waze',
      'uber': 'com.ubercab',
      '99': 'com.taxis99',
      'taxis 99': 'com.taxis99',
      'ifood': 'br.com.brainweb.ifood',
      'i food': 'br.com.brainweb.ifood',
      'mercado livre': 'com.mercadolibre',
      'meli': 'com.mercadolibre',
      'netflix': 'com.netflix.mediaclient',
      'amazon': 'com.amazon.mShop.android.shopping',
      'twitter': 'com.twitter.android',
      'x': 'com.twitter.android',
      'tiktok': 'com.zhiliaoapp.musically',
      'facebook': 'com.facebook.katana',
      'fb': 'com.facebook.katana',
      'messenger': 'com.facebook.orca',
      'linkedin': 'com.linkedin.android',
      'discord': 'com.discord',
      'slack': 'com.Slack',
      'camera': 'com.android.camera',
      'cameras': 'com.android.camera',
      'galeria': 'com.google.android.apps.photos',
      'fotos': 'com.google.android.apps.photos',
      'calculadora': 'com.google.android.calculator',
      'calendario': 'com.google.android.calendar',
      'agenda': 'com.google.android.calendar',
      'play store': 'com.android.vending',
      'loja': 'com.android.vending',
      'configuracoes': 'com.android.settings',
      'ajustes': 'com.android.settings',
      'settings': 'com.android.settings',
    };
    if (map.containsKey(norm)) return map[norm];
    // try strip leading "o ", "a ", "do "
    final stripped =
        norm.replaceFirst(RegExp(r'^(o|a|os|as|do|da)\s+'), '');
    if (map.containsKey(stripped)) return map[stripped];
    return null;
  }

  static String _normalize(String s) {
    s = s.toLowerCase().trim();
    // strip accents (basic)
    const map = {
      'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a',
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
      'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
      'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
      'ç': 'c', 'ñ': 'n',
    };
    final buf = StringBuffer();
    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      buf.write(map[ch] ?? ch);
    }
    // remove punct end
    var out = buf.toString();
    out = out.replaceAll(RegExp(r'[.!?,;:]+$'), '').trim();
    return out;
  }
}

/// Result of a voice-command parse attempt.
class VoiceCommandResult {
  /// True if a local command was matched and executed.
  final bool matched;

  /// Short PT-BR message to speak via TTS (e.g. "Abrindo YouTube").
  final String? spokenFeedback;

  const VoiceCommandResult({
    required this.matched,
    this.spokenFeedback,
  });
}
