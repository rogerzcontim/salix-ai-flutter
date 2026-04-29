// SALIX onda 4 — Comandos nativos do celular
//
// Controles que rodam puramente no Android sem chamar o backend:
//   - Volume (media / ringtone / notification)
//   - Brilho da tela
//   - Lanterna (flashlight)
//   - Vibração
//   - Bluetooth (toggle on Android <= 12 / abre settings em >= 13)
//   - Wifi (sempre abre settings — restrição da plataforma desde Android 10)
//
// iOS pega o que dá: brilho funciona, volume é read-only, lanterna existe via
// torch_light, BT/Wifi não dá.
//
// Cada método retorna um [DeviceActionResult] que a UI/LLM pode logar.

import 'dart:io';

import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:torch_light/torch_light.dart';
import 'package:vibration/vibration.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:android_intent_plus/android_intent.dart';

/// Result of a device-control action. `ok=true` means the platform accepted
/// the call. `ok=false` means we couldn't perform it (permission denied,
/// platform not supported, etc) — `message` explains why.
class DeviceActionResult {
  final bool ok;
  final String message;
  final dynamic value;
  const DeviceActionResult(this.ok, this.message, {this.value});

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'message': message,
        if (value != null) 'value': value,
      };
}

/// Categories supported by the volume controller.
enum VolumeCategory { media, ringtone, notification, system, voiceCall }

extension on VolumeCategory {
  AudioStream toStream() {
    switch (this) {
      case VolumeCategory.media:
        return AudioStream.music;
      case VolumeCategory.ringtone:
        return AudioStream.ring;
      case VolumeCategory.notification:
        return AudioStream.notification;
      case VolumeCategory.system:
        return AudioStream.system;
      case VolumeCategory.voiceCall:
        return AudioStream.voiceCall;
    }
  }
}

class DeviceControl {
  // ----------------------------------------------------------------- Volume

  /// Set [category] volume to [level] in 0.0..1.0.
  static Future<DeviceActionResult> setVolume(
    double level, {
    VolumeCategory category = VolumeCategory.media,
    bool showSystemUI = false,
  }) async {
    final clamped = level.clamp(0.0, 1.0);
    try {
      await FlutterVolumeController.updateShowSystemUI(showSystemUI);
      await FlutterVolumeController.setVolume(
        clamped,
        stream: category.toStream(),
      );
      return DeviceActionResult(
        true,
        'volume ${category.name} = ${(clamped * 100).round()}%',
        value: clamped,
      );
    } catch (e) {
      return DeviceActionResult(false, 'falha set volume: $e');
    }
  }

  /// Read current volume for [category].
  static Future<DeviceActionResult> getVolume({
    VolumeCategory category = VolumeCategory.media,
  }) async {
    try {
      final v = await FlutterVolumeController.getVolume(
        stream: category.toStream(),
      );
      return DeviceActionResult(
        true,
        'volume ${category.name} = ${((v ?? 0) * 100).round()}%',
        value: v,
      );
    } catch (e) {
      return DeviceActionResult(false, 'falha get volume: $e');
    }
  }

  /// Mute media (level 0).
  static Future<DeviceActionResult> mute({
    VolumeCategory category = VolumeCategory.media,
  }) =>
      setVolume(0.0, category: category);

  // ----------------------------------------------------------------- Bright

  /// Set screen brightness 0.0..1.0.
  static Future<DeviceActionResult> setBrightness(double level) async {
    final clamped = level.clamp(0.0, 1.0);
    try {
      await ScreenBrightness().setScreenBrightness(clamped);
      return DeviceActionResult(
        true,
        'brilho = ${(clamped * 100).round()}%',
        value: clamped,
      );
    } catch (e) {
      return DeviceActionResult(false, 'falha set brilho: $e');
    }
  }

  static Future<DeviceActionResult> getBrightness() async {
    try {
      final v = await ScreenBrightness().current;
      return DeviceActionResult(
        true,
        'brilho = ${(v * 100).round()}%',
        value: v,
      );
    } catch (e) {
      return DeviceActionResult(false, 'falha get brilho: $e');
    }
  }

  /// Restore the system brightness (cancel app override).
  static Future<DeviceActionResult> resetBrightness() async {
    try {
      await ScreenBrightness().resetScreenBrightness();
      return const DeviceActionResult(true, 'brilho restaurado pro sistema');
    } catch (e) {
      return DeviceActionResult(false, 'falha reset brilho: $e');
    }
  }

  // -------------------------------------------------------------- Flashlight

  static Future<DeviceActionResult> setFlashlight(bool on) async {
    try {
      if (on) {
        await TorchLight.enableTorch();
        return const DeviceActionResult(true, 'lanterna ligada');
      } else {
        await TorchLight.disableTorch();
        return const DeviceActionResult(true, 'lanterna desligada');
      }
    } on EnableTorchExistentUserException {
      return const DeviceActionResult(false, 'lanterna em uso por outro app');
    } on EnableTorchNotAvailableException {
      return const DeviceActionResult(false, 'lanterna indisponível neste device');
    } catch (e) {
      return DeviceActionResult(false, 'falha lanterna: $e');
    }
  }

  static Future<DeviceActionResult> toggleFlashlight() async {
    // torch_light doesn't expose state — try enable, fall back to disable.
    final r = await setFlashlight(true);
    if (r.ok) return r;
    return setFlashlight(false);
  }

  // ----------------------------------------------------------------- Vibrate

  /// Vibrate for [ms] milliseconds (default 300).
  static Future<DeviceActionResult> vibrate({int ms = 300}) async {
    try {
      final has = await Vibration.hasVibrator() ?? false;
      if (!has) return const DeviceActionResult(false, 'sem vibrador');
      Vibration.vibrate(duration: ms);
      return DeviceActionResult(true, 'vibrou ${ms}ms');
    } catch (e) {
      return DeviceActionResult(false, 'falha vibrar: $e');
    }
  }

  /// Pattern in milliseconds (e.g. [0, 200, 100, 200] = wait 0, on 200,
  /// off 100, on 200).
  static Future<DeviceActionResult> vibratePattern(List<int> pattern) async {
    try {
      Vibration.vibrate(pattern: pattern);
      return DeviceActionResult(true, 'pattern ${pattern.length} steps');
    } catch (e) {
      return DeviceActionResult(false, 'falha pattern: $e');
    }
  }

  // -------------------------------------------------------------- Bluetooth

  /// On Android we open the BT settings panel (works on every API). Toggling
  /// programmatically without user consent was removed in Android 13.
  static Future<DeviceActionResult> openBluetoothSettings() async {
    if (!Platform.isAndroid) {
      return const DeviceActionResult(false, 'BT settings só Android');
    }
    try {
      const intent = AndroidIntent(
        action: 'android.settings.BLUETOOTH_SETTINGS',
      );
      await intent.launch();
      return const DeviceActionResult(true, 'abriu settings de Bluetooth');
    } catch (e) {
      return DeviceActionResult(false, 'falha abrir BT settings: $e');
    }
  }

  // ------------------------------------------------------------------- Wifi

  /// Wifi toggle is restricted since Android 10 — we always open settings.
  static Future<DeviceActionResult> openWifiSettings() async {
    if (!Platform.isAndroid) {
      return const DeviceActionResult(false, 'Wifi settings só Android');
    }
    try {
      const intent = AndroidIntent(action: 'android.settings.WIFI_SETTINGS');
      await intent.launch();
      return const DeviceActionResult(true, 'abriu settings de Wifi');
    } catch (e) {
      return DeviceActionResult(false, 'falha abrir Wifi settings: $e');
    }
  }

  // ------------------------------------------------------------------ DND

  /// Open Do Not Disturb / sound mode settings (the only safe path on modern
  /// Android — programmatic ring mode change requires NotificationPolicy
  /// access and confuses users).
  static Future<DeviceActionResult> openSoundSettings() async {
    if (!Platform.isAndroid) {
      return const DeviceActionResult(false, 'sound settings só Android');
    }
    try {
      const intent = AndroidIntent(action: 'android.settings.SOUND_SETTINGS');
      await intent.launch();
      return const DeviceActionResult(true, 'abriu settings de som');
    } catch (e) {
      return DeviceActionResult(false, 'falha sound settings: $e');
    }
  }

  // ----------------------------------------------------------- Generic launch

  /// Launch a generic URL — used by [IntentLauncherV2] and rotinas.
  static Future<DeviceActionResult> openUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      return ok
          ? DeviceActionResult(true, 'abriu $url')
          : DeviceActionResult(false, 'não pôde abrir $url');
    } catch (e) {
      return DeviceActionResult(false, 'falha url: $e');
    }
  }
}
