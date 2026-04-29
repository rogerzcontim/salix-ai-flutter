// SALIX onda 4 — pinger de localização foreground
//
// Quando o app está aberto, faz POST /api/routines/geofences/ping a cada
// LOCATION_INTERVAL pra que o daemon avalie geofence enter/exit.
// Background tracking real (foreground service Android) fica para uma
// segunda etapa quando publicarmos o app fora do Play Store.
//
// v2.0.0+21: cada chamada nativa do geolocator wrappada em try/catch
// específico por tipo de exceção (LocationServiceDisabledException,
// PermissionDeniedException, MissingPluginException, PlatformException),
// reportando via CrashReporter pra que possamos saber EXATAMENTE qual
// step falhou em campo.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crash_reporter.dart';
import 'persona_store.dart';
import 'routines_client.dart';

class LocationPinger {
  static const Duration _interval = Duration(seconds: 60);
  static const String _kEnabledKey = 'location.enabled';
  static StreamSubscription<Position>? _sub;
  static Timer? _timer;

  /// User-explicit opt-in. Default OFF. Use [setEnabled(true)] from Settings.
  static Future<bool> isEnabled() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(_kEnabledKey) ?? false;
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:isEnabled');
      return false;
    }
  }

  static Future<void> setEnabled(bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kEnabledKey, v);
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:setEnabled.prefs');
    }
    try {
      if (v) {
        await start();
      } else {
        stop();
      }
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:setEnabled.startStop');
    }
  }

  /// Starts pinger ONLY if user opted-in AND permission is granted. Safe to
  /// call multiple times; no-op if disabled.
  static Future<void> start() async {
    if (_timer != null) return;
    try {
      CrashReporter.info('location_pinger:start.BEFORE');
      if (!await isEnabled()) {
        CrashReporter.info('location_pinger:start.notEnabled');
        return;
      }
      final hasPerm = await _ensurePermission();
      if (!hasPerm) {
        CrashReporter.info('location_pinger:start.noPermission');
        return;
      }
      _timer = Timer.periodic(_interval, (_) => _pingOnce());
      // ping immediately (best-effort)
      unawaited(_pingOnce());
      CrashReporter.info('location_pinger:start.AFTER');
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:start.unknown');
      debugPrint('[location] start failed: $e');
    }
  }

  static void stop() {
    try {
      _timer?.cancel();
      _timer = null;
      _sub?.cancel();
      _sub = null;
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:stop');
    }
  }

  static Future<bool> _ensurePermission() async {
    // STEP A: serviço de GPS habilitado?
    bool svcOn = false;
    try {
      CrashReporter.info('location_pinger:ensurePerm.BEFORE_isLocServiceEnabled');
      svcOn = await Geolocator.isLocationServiceEnabled();
      CrashReporter.info('location_pinger:ensurePerm.AFTER_isLocServiceEnabled');
    } on MissingPluginException catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:isLocServiceEnabled.MissingPlugin');
      return false;
    } on PlatformException catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:isLocServiceEnabled.PlatformException');
      return false;
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:isLocServiceEnabled.unknown');
      return false;
    }
    if (!svcOn) return false;

    // STEP B: checa permissão atual
    LocationPermission perm = LocationPermission.denied;
    try {
      CrashReporter.info('location_pinger:ensurePerm.BEFORE_checkPermission');
      perm = await Geolocator.checkPermission();
      CrashReporter.info('location_pinger:ensurePerm.AFTER_checkPermission');
    } on MissingPluginException catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:checkPermission.MissingPlugin');
      return false;
    } on PlatformException catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:checkPermission.PlatformException');
      return false;
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:checkPermission.unknown');
      return false;
    }

    // STEP C: solicita se necessário
    if (perm == LocationPermission.denied) {
      try {
        CrashReporter.info('location_pinger:ensurePerm.BEFORE_requestPermission');
        perm = await Geolocator.requestPermission();
        CrashReporter.info('location_pinger:ensurePerm.AFTER_requestPermission');
      } on MissingPluginException catch (e, s) {
        CrashReporter.report(e, s, context: 'location_pinger:requestPermission.MissingPlugin');
        return false;
      } on PlatformException catch (e, s) {
        CrashReporter.report(e, s, context: 'location_pinger:requestPermission.PlatformException');
        return false;
      } catch (e, s) {
        CrashReporter.report(e, s, context: 'location_pinger:requestPermission.unknown');
        return false;
      }
    }

    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  static Future<void> _pingOnce() async {
    try {
      final p = await PersonaStore().active();
      if (p == null) return;
      Position pos;
      try {
        CrashReporter.info('location_pinger:pingOnce.BEFORE_getCurrentPosition');
        pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.medium);
        CrashReporter.info('location_pinger:pingOnce.AFTER_getCurrentPosition');
      } on LocationServiceDisabledException catch (e, s) {
        CrashReporter.report(e, s, context: 'location_pinger:getCurrentPosition.LocationServiceDisabled');
        return;
      } on PermissionDeniedException catch (e, s) {
        CrashReporter.report(e, s, context: 'location_pinger:getCurrentPosition.PermissionDenied');
        return;
      } on MissingPluginException catch (e, s) {
        CrashReporter.report(e, s, context: 'location_pinger:getCurrentPosition.MissingPlugin');
        return;
      } on PlatformException catch (e, s) {
        CrashReporter.report(e, s, context: 'location_pinger:getCurrentPosition.PlatformException');
        return;
      } catch (e, s) {
        CrashReporter.report(e, s, context: 'location_pinger:getCurrentPosition.unknown');
        return;
      }

      int h = 0xcbf29ce484222325 & 0x7fffffffffffffff;
      for (final code in p.id.codeUnits) {
        h ^= code;
        h = (h * 0x100000001b3) & 0x7fffffffffffffff;
      }
      try {
        await RoutinesClient().pushLocation(
          userId: h,
          lat: pos.latitude,
          lng: pos.longitude,
          accuracyM: pos.accuracy,
        );
      } catch (e, s) {
        CrashReporter.report(e, s, context: 'location_pinger:pushLocation');
      }
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'location_pinger:pingOnce.outer');
    }
  }
}
