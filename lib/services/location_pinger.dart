// SALIX onda 4 — pinger de localização foreground
//
// Quando o app está aberto, faz POST /api/routines/geofences/ping a cada
// LOCATION_INTERVAL pra que o daemon avalie geofence enter/exit.
// Background tracking real (foreground service Android) fica para uma
// segunda etapa quando publicarmos o app fora do Play Store.

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'persona_store.dart';
import 'routines_client.dart';

class LocationPinger {
  static const Duration _interval = Duration(seconds: 60);
  static StreamSubscription<Position>? _sub;
  static Timer? _timer;

  static Future<void> start() async {
    if (_timer != null) return;
    final hasPerm = await _ensurePermission();
    if (!hasPerm) return;
    _timer = Timer.periodic(_interval, (_) => _pingOnce());
    // ping immediately
    unawaited(_pingOnce());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
  }

  static Future<bool> _ensurePermission() async {
    try {
      final ok = await Geolocator.isLocationServiceEnabled();
      if (!ok) return false;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      return perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _pingOnce() async {
    try {
      final p = await PersonaStore().active();
      if (p == null) return;
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium);
      int h = 0xcbf29ce484222325 & 0x7fffffffffffffff;
      for (final code in p.id.codeUnits) {
        h ^= code;
        h = (h * 0x100000001b3) & 0x7fffffffffffffff;
      }
      await RoutinesClient().pushLocation(
        userId: h,
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyM: pos.accuracy,
      );
    } catch (_) {
      // best-effort
    }
  }
}
