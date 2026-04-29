// SALIX onda 4 — Comandos nativos que dependem de Intent puro / url_launcher
//
// Esse service é COMPLEMENTAR ao [DeviceControl] (que cuida de volume/brilho/
// lanterna/vibração via plugins). Aqui ficam comandos que precisam de Intents
// específicos do Android (alarme, timer, telefone, SMS) ou que dependem de
// pacotes externos (open_app por package name).
//
// iOS: bloqueia quase tudo.
//   - Alarm/Timer: NÃO existe API pública. Usuário precisa abrir Atalhos
//     manualmente. Documentamos como limitação.
//   - Call: tel: scheme funciona (abre phone app, usuário confirma).
//   - SMS: sms: scheme funciona (abre Messages, usuário envia).
//   - Open app por bundle_id: só se o app declarar URL scheme custom (LSApplicationQueriesSchemes).
//
// Cada método retorna [DeviceActionResult] (importado de device_control.dart).

import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'device_control.dart' show DeviceActionResult;

class DeviceCommands {
  // -------------------------------------------------------------------- Alarm

  /// Set an alarm using the standard `AlarmClock.ACTION_SET_ALARM` Intent.
  /// On Android the user sees a confirmation in the system clock app — we
  /// don't bypass that. [hour] 0..23, [minute] 0..59.
  static Future<DeviceActionResult> setAlarm({
    required int hour,
    required int minute,
    String? label,
    bool skipUi = false,
    List<String>? days, // ["MONDAY","TUESDAY",...] optional
  }) async {
    if (!Platform.isAndroid) {
      return const DeviceActionResult(
        false,
        'iOS não tem API de alarme — abra o Atalhos manualmente',
      );
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return const DeviceActionResult(false, 'horário inválido (0-23 / 0-59)');
    }
    try {
      final args = <String, dynamic>{
        'android.intent.extra.alarm.HOUR': hour,
        'android.intent.extra.alarm.MINUTES': minute,
        if (label != null && label.isNotEmpty)
          'android.intent.extra.alarm.MESSAGE': label,
        'android.intent.extra.alarm.SKIP_UI': skipUi,
      };
      if (days != null && days.isNotEmpty) {
        args['android.intent.extra.alarm.DAYS'] = days;
      }
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_ALARM',
        arguments: args,
      );
      await intent.launch();
      return DeviceActionResult(
        true,
        'alarme criado ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}'
        '${label != null && label.isNotEmpty ? " ($label)" : ""}',
        value: {'hour': hour, 'minute': minute, 'label': label},
      );
    } catch (e) {
      return DeviceActionResult(false, 'falha set alarm: $e');
    }
  }

  // -------------------------------------------------------------------- Timer

  /// Start a countdown timer via `AlarmClock.ACTION_SET_TIMER`.
  /// [seconds] must be 1..86399.
  static Future<DeviceActionResult> setTimer({
    required int seconds,
    String? label,
    bool skipUi = true,
  }) async {
    if (!Platform.isAndroid) {
      return const DeviceActionResult(
        false,
        'iOS: peça ao usuário pra abrir o Atalhos / Cronômetro',
      );
    }
    if (seconds < 1 || seconds > 86399) {
      return const DeviceActionResult(false, 'segundos fora de 1..86399');
    }
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_TIMER',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.LENGTH': seconds,
          if (label != null && label.isNotEmpty)
            'android.intent.extra.alarm.MESSAGE': label,
          'android.intent.extra.alarm.SKIP_UI': skipUi,
        },
      );
      await intent.launch();
      return DeviceActionResult(
        true,
        'timer ${seconds}s${label != null && label.isNotEmpty ? " ($label)" : ""}',
        value: {'seconds': seconds, 'label': label},
      );
    } catch (e) {
      return DeviceActionResult(false, 'falha set timer: $e');
    }
  }

  // ------------------------------------------------------------------ Open app

  /// Open an app by its package name (Android) using the LAUNCHER intent.
  /// On iOS the same call must use a URL scheme — not implemented (returns false).
  static Future<DeviceActionResult> openAppByPackage(String packageName) async {
    if (packageName.isEmpty) {
      return const DeviceActionResult(false, 'package vazio');
    }
    if (!Platform.isAndroid) {
      return const DeviceActionResult(
        false,
        'iOS não tem package name — use deep link / URL scheme',
      );
    }
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        category: 'android.intent.category.LAUNCHER',
        package: packageName,
      );
      await intent.launch();
      return DeviceActionResult(true, 'abriu app $packageName');
    } catch (e) {
      return DeviceActionResult(false, 'falha abrir app $packageName: $e');
    }
  }

  // ------------------------------------------------------------------- Call

  /// Place a phone call. On Android with `CALL_PHONE` permission the call is
  /// placed directly; without permission we fallback to `tel:` (dialer with
  /// number filled). On iOS only `tel:` works (always opens dialer).
  static Future<DeviceActionResult> makeCall(String number, {bool direct = false}) async {
    final clean = number.replaceAll(RegExp(r'[^0-9+*#]'), '');
    if (clean.isEmpty) {
      return const DeviceActionResult(false, 'número inválido');
    }
    try {
      if (direct && Platform.isAndroid) {
        final granted = await Permission.phone.request();
        if (granted.isGranted) {
          final intent = AndroidIntent(
            action: 'android.intent.action.CALL',
            data: 'tel:$clean',
          );
          await intent.launch();
          return DeviceActionResult(true, 'chamando $clean (direto)');
        }
        // fallthrough: dialer
      }
      final ok = await launchUrl(
        Uri.parse('tel:$clean'),
        mode: LaunchMode.externalApplication,
      );
      return ok
          ? DeviceActionResult(true, 'discador aberto pra $clean')
          : DeviceActionResult(false, 'não pôde abrir discador');
    } catch (e) {
      return DeviceActionResult(false, 'falha call: $e');
    }
  }

  // --------------------------------------------------------------------- SMS

  /// Compose an SMS. We always use ACTION_SENDTO with `smsto:` so the user
  /// reviews and presses send themselves — direct SMS_SEND requires SEND_SMS
  /// permission which Play Store severely restricts.
  static Future<DeviceActionResult> sendSms({
    required String number,
    String? body,
  }) async {
    final clean = number.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) {
      return const DeviceActionResult(false, 'número inválido');
    }
    final encoded = Uri.encodeComponent(body ?? '');
    final url = 'sms:$clean${encoded.isNotEmpty ? "?body=$encoded" : ""}';
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      return ok
          ? DeviceActionResult(true, 'compositor SMS aberto pra $clean')
          : DeviceActionResult(false, 'não pôde abrir SMS');
    } catch (e) {
      return DeviceActionResult(false, 'falha SMS: $e');
    }
  }

  // ----------------------------------------------------------- Wifi/Bluetooth

  /// Open Wifi settings panel (toggle programático bloqueado desde Android 10).
  /// Reuses [DeviceControl.openWifiSettings] but exposes the same name as the
  /// LLM tool spec.
  static Future<DeviceActionResult> toggleWifi() async {
    if (!Platform.isAndroid) {
      return const DeviceActionResult(false, 'iOS: bloqueado');
    }
    try {
      const intent = AndroidIntent(action: 'android.settings.WIFI_SETTINGS');
      await intent.launch();
      return const DeviceActionResult(true, 'painel Wifi aberto');
    } catch (e) {
      return DeviceActionResult(false, 'falha wifi: $e');
    }
  }

  /// Open Bluetooth settings panel.
  static Future<DeviceActionResult> toggleBluetooth() async {
    if (!Platform.isAndroid) {
      return const DeviceActionResult(false, 'iOS: bloqueado');
    }
    try {
      const intent =
          AndroidIntent(action: 'android.settings.BLUETOOTH_SETTINGS');
      await intent.launch();
      return const DeviceActionResult(true, 'painel Bluetooth aberto');
    } catch (e) {
      return DeviceActionResult(false, 'falha bt: $e');
    }
  }

  // -------------------------------------------------------------- Permissions

  /// Pre-flight: ask once for the permissions onda-4 features need. Safe to
  /// call multiple times.
  static Future<Map<String, bool>> requestAllPermissions() async {
    final res = <String, bool>{};
    if (!Platform.isAndroid) return res;
    final perms = <Permission>[
      Permission.phone,
      Permission.sms,
      Permission.location,
      Permission.locationAlways,
      Permission.notification,
    ];
    for (final p in perms) {
      try {
        final s = await p.request();
        res[p.toString()] = s.isGranted;
      } catch (_) {
        res[p.toString()] = false;
      }
    }
    return res;
  }
}
