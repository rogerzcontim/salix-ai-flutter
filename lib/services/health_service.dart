import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'meta_agent_client.dart';
import 'meta_agent_client_ext.dart';

/// Onda 8 — Health Service.
///
/// On Android: bridges Health Connect via the `health` plugin (when added).
/// On iOS: bridges HealthKit via same plugin.
///
/// The `health` plugin is heavy and not yet in pubspec; the rest of the app
/// only talks to this service so we can swap implementations.
///
/// Until the plugin is wired, `getSnapshot()` returns whatever the user
/// already pushed manually plus a fallback empty snapshot. Backend tool
/// `get_health_data` is still callable from chat — server returns whatever
/// it has cached for the user (also Onda 8 endpoint).
class HealthService {
  HealthService._();
  static final instance = HealthService._();

  Future<HealthSnapshot> getSnapshot({Duration window = const Duration(days: 1)}) async {
    try {
      // Best-effort: ask for activity recognition / sensors permission.
      try { await Permission.activityRecognition.request(); } catch (_) {}
      try { await Permission.sensors.request(); } catch (_) {}

      // TODO(health): when `health` plugin is in pubspec:
      //   final h = HealthFactory(useHealthConnectIfAvailable: true);
      //   final types = [HealthDataType.STEPS, HealthDataType.HEART_RATE, ...];
      //   await h.requestAuthorization(types);
      //   final data = await h.getHealthDataFromTypes(start, now, types);
      //   return _mapToSnapshot(data);

      // Fallback: ask backend (server may have manual entries).
      final backend = await MetaAgentClient().getHealthSnapshot();
      return HealthSnapshot.fromJson(backend);
    } catch (e) {
      if (kDebugMode) debugPrint('[health] snapshot error: $e');
      return HealthSnapshot.empty();
    }
  }

  /// Manual entry (steps/weight/heart rate logged from chat or settings).
  Future<bool> logEntry({
    required String kind, // steps|sleep_min|heart_rate|weight_kg
    required double value,
    DateTime? at,
  }) async {
    try {
      await MetaAgentClient().logHealthEntry(kind: kind, value: value, at: at ?? DateTime.now());
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[health] log error: $e');
      return false;
    }
  }
}

class HealthSnapshot {
  final int? steps;
  final double? sleepHours;
  final int? heartRateBpm;
  final double? weightKg;
  final DateTime? at;

  HealthSnapshot({this.steps, this.sleepHours, this.heartRateBpm, this.weightKg, this.at});

  factory HealthSnapshot.empty() => HealthSnapshot();

  factory HealthSnapshot.fromJson(Map<String, dynamic> j) {
    DateTime? at;
    final atRaw = j['at'];
    if (atRaw is String) {
      at = DateTime.tryParse(atRaw);
    }
    return HealthSnapshot(
      steps: (j['steps'] as num?)?.toInt(),
      sleepHours: (j['sleep_hours'] as num?)?.toDouble(),
      heartRateBpm: (j['heart_rate_bpm'] as num?)?.toInt(),
      weightKg: (j['weight_kg'] as num?)?.toDouble(),
      at: at,
    );
  }

  Map<String, dynamic> toJson() => {
        if (steps != null) 'steps': steps,
        if (sleepHours != null) 'sleep_hours': sleepHours,
        if (heartRateBpm != null) 'heart_rate_bpm': heartRateBpm,
        if (weightKg != null) 'weight_kg': weightKg,
        if (at != null) 'at': at!.toIso8601String(),
      };
}
