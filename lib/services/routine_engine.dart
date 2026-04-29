// SALIX onda 4 — Engine local de execução de rotinas
//
// Quando uma rotina dispara (porque o backend mandou push, ou porque o
// trigger é local — ex: voz reconhecida, geofence enter detectado pelo
// `geolocator` plugin, app aberto), o ENGINE pega a lista de `actions` da
// rotina e executa cada uma chamando o tool correspondente.
//
// Tools whitelisted (mesmo set do daemon salix-routines-runner :9298):
//   open_app                 args: { app_name, action?, data? }   — via DeepLinks
//   open_app_package         args: { package }                    — Android only
//   open_url                 args: { url }
//   set_volume               args: { level (0..1), category? }
//   mute                     args: { category? }
//   set_brightness           args: { level (0..1) }
//   reset_brightness
//   flashlight               args: { on: bool }
//   vibrate                  args: { ms?: int }
//   vibrate_pattern          args: { pattern: [int,...] }
//   open_bluetooth_settings
//   open_wifi_settings
//   open_sound_settings
//   set_alarm                args: { hour, minute, label?, days? }
//   set_timer                args: { seconds, label? }
//   make_call                args: { number, direct? }
//   send_sms                 args: { number, body? }
//   notify                   args: { title, body }   — local toast/snack hook
//
// Cada action retorna [DeviceActionResult]; o engine acumula e devolve um log.

import 'package:url_launcher/url_launcher.dart';

import 'app_intents.dart';
import 'deep_links.dart';
import 'device_commands.dart';
import 'device_control.dart';

/// Hook chamada quando uma action `notify` executa. UI (chat_page) deve
/// registrar via [RoutineEngine.onNotify].
typedef NotifyHandler = void Function(String title, String body);

class RoutineActionLog {
  final String tool;
  final bool ok;
  final String message;
  final DateTime ts;
  RoutineActionLog(this.tool, this.ok, this.message)
      : ts = DateTime.now().toUtc();
  Map<String, dynamic> toJson() => {
        'tool': tool,
        'ok': ok,
        'message': message,
        'ts': ts.toIso8601String(),
      };
}

class RoutineEngine {
  static NotifyHandler? onNotify;

  /// Executa uma lista de actions sequencialmente. Não para se uma falhar —
  /// só loga. Retorna log completo.
  static Future<List<RoutineActionLog>> runActions(
    List<Map<String, dynamic>> actions,
  ) async {
    final logs = <RoutineActionLog>[];
    for (final a in actions) {
      final tool = (a['tool'] ?? '').toString();
      final args = (a['args'] is Map)
          ? Map<String, dynamic>.from(a['args'] as Map)
          : <String, dynamic>{};
      final res = await _runOne(tool, args);
      logs.add(RoutineActionLog(tool, res.ok, res.message));
    }
    return logs;
  }

  /// Executa uma única action. Pública pra o IntentLauncher e testes.
  static Future<DeviceActionResult> runOne(
    String tool,
    Map<String, dynamic> args,
  ) =>
      _runOne(tool, args);

  static Future<DeviceActionResult> _runOne(
    String tool,
    Map<String, dynamic> args,
  ) async {
    try {
      switch (tool) {
        // ---------------------------------------------------------- launch
        case 'open_app':
          final app = (args['app_name'] ?? args['app'] ?? '').toString();
          final action = (args['action'] ?? 'open').toString();
          final data = (args['data'] is Map)
              ? Map<String, dynamic>.from(args['data'] as Map)
              : <String, dynamic>{};
          final dl = DeepLinks.resolve(
            appName: app,
            action: action,
            data: data,
          );
          if (dl == null) {
            return DeviceActionResult(false, 'app desconhecido: $app');
          }
          // Try primary scheme; if it fails (app not installed) fallback to web.
          try {
            final ok = await launchUrl(
              Uri.parse(dl.primary),
              mode: LaunchMode.externalApplication,
            );
            if (ok) return DeviceActionResult(true, dl.description);
          } catch (_) {}
          final ok2 = await launchUrl(
            Uri.parse(dl.fallback),
            mode: LaunchMode.externalApplication,
          );
          return ok2
              ? DeviceActionResult(true, '${dl.description} (web)')
              : DeviceActionResult(false, 'não pôde abrir $app');

        case 'open_app_package':
          return DeviceCommands.openAppByPackage(
              (args['package'] ?? '').toString());

        case 'open_url':
          return DeviceControl.openUrl((args['url'] ?? '').toString());

        // ---------------------------------------------------------- audio
        case 'set_volume':
          final level = (args['level'] as num?)?.toDouble() ?? 0.5;
          final cat = _parseVolumeCategory(args['category']?.toString());
          return DeviceControl.setVolume(level, category: cat);
        case 'mute':
          final cat = _parseVolumeCategory(args['category']?.toString());
          return DeviceControl.mute(category: cat);

        // ----------------------------------------------------- brightness
        case 'set_brightness':
          final level = (args['level'] as num?)?.toDouble() ?? 0.5;
          return DeviceControl.setBrightness(level);
        case 'reset_brightness':
          return DeviceControl.resetBrightness();

        // ---------------------------------------------------------- torch
        case 'flashlight':
        case 'torch':
          final on = args['on'] == true || args['on']?.toString() == 'true';
          return DeviceControl.setFlashlight(on);

        // -------------------------------------------------------- vibrate
        case 'vibrate':
          final ms = (args['ms'] as num?)?.toInt() ?? 300;
          return DeviceControl.vibrate(ms: ms);
        case 'vibrate_pattern':
          final raw = args['pattern'];
          if (raw is List) {
            return DeviceControl.vibratePattern(
              raw.map((e) => (e as num).toInt()).toList(),
            );
          }
          return const DeviceActionResult(false, 'pattern inválido');

        // -------------------------------------------------------- settings
        case 'open_bluetooth_settings':
          return DeviceControl.openBluetoothSettings();
        case 'open_wifi_settings':
          return DeviceControl.openWifiSettings();
        case 'open_sound_settings':
          return DeviceControl.openSoundSettings();
        case 'toggle_wifi':
          return DeviceCommands.toggleWifi();
        case 'toggle_bluetooth':
          return DeviceCommands.toggleBluetooth();

        // ---------------------------------------------------- alarm/timer
        case 'set_alarm':
          final hour = (args['hour'] as num?)?.toInt() ?? 0;
          final minute = (args['minute'] as num?)?.toInt() ?? 0;
          final label = args['label']?.toString();
          final skipUi =
              args['skip_ui'] == true || args['skipUi'] == true;
          List<String>? days;
          final rawDays = args['days'];
          if (rawDays is List) days = rawDays.map((e) => e.toString()).toList();
          return DeviceCommands.setAlarm(
            hour: hour,
            minute: minute,
            label: label,
            skipUi: skipUi,
            days: days,
          );
        case 'set_timer':
          final secs = (args['seconds'] as num?)?.toInt() ?? 60;
          final label = args['label']?.toString();
          return DeviceCommands.setTimer(seconds: secs, label: label);

        // ---------------------------------------------------------- phone
        case 'make_call':
          final num = (args['number'] ?? args['phone'] ?? '').toString();
          final direct = args['direct'] == true;
          return DeviceCommands.makeCall(num, direct: direct);
        case 'send_sms':
          final num = (args['number'] ?? args['phone'] ?? '').toString();
          final body = args['body']?.toString() ?? args['text']?.toString();
          return DeviceCommands.sendSms(number: num, body: body);

        // -------------------------------------------------------- notify
        case 'notify':
        case 'send_notification':
          final title = (args['title'] ?? 'SALIX').toString();
          final body = (args['body'] ?? args['text'] ?? '').toString();
          final h = onNotify;
          if (h != null) {
            h(title, body);
            return DeviceActionResult(true, 'notificou: $title');
          }
          return const DeviceActionResult(false, 'sem handler de notificação');

        // ------------------------------------------------------- generic deep link
        // Permite que o LLM chame "tool: open_deep_link" sem saber o nome do app
        // se já tiver um URL pronto.
        case 'open_deep_link':
          final url = (args['url'] ?? '').toString();
          if (url.isEmpty) {
            return const DeviceActionResult(false, 'url vazia');
          }
          final ok = await launchUrl(
            Uri.parse(url),
            mode: LaunchMode.externalApplication,
          );
          return ok
              ? DeviceActionResult(true, 'abriu $url')
              : DeviceActionResult(false, 'falha abrir $url');

        // ---------------------------------------------- legacy compat (AppIntents)
        case 'app_intent':
          final app = (args['app'] ?? '').toString();
          final action = (args['action'] ?? 'open').toString();
          final data = (args['data'] is Map)
              ? Map<String, dynamic>.from(args['data'] as Map)
              : <String, dynamic>{};
          final ai = AppIntents.build(appName: app, action: action, data: data);
          if (ai == null) {
            return DeviceActionResult(false, 'app intent: $app desconhecido');
          }
          return DeviceControl.openUrl(ai.url);

        default:
          return DeviceActionResult(false, 'tool não-whitelisted: $tool');
      }
    } catch (e) {
      return DeviceActionResult(false, 'exceção em $tool: $e');
    }
  }

  static VolumeCategory _parseVolumeCategory(String? s) {
    switch ((s ?? '').toLowerCase()) {
      case 'ringtone':
      case 'ring':
        return VolumeCategory.ringtone;
      case 'notification':
      case 'notif':
        return VolumeCategory.notification;
      case 'system':
        return VolumeCategory.system;
      case 'voice':
      case 'voicecall':
      case 'call':
        return VolumeCategory.voiceCall;
      case 'media':
      default:
        return VolumeCategory.media;
    }
  }
}
