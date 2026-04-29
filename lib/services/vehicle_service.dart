import 'package:flutter/foundation.dart';
import 'meta_agent_client.dart';
import 'meta_agent_client_ext.dart';

/// Onda 8 — Vehicle Service.
///
/// Thin client for backend tools `car_maintenance_schedule`, `fuel_log`,
/// `find_parking`, `obd_diagnostic`. Storage and any external API keys
/// live server-side.
class VehicleService {
  VehicleService._();
  static final instance = VehicleService._();

  Future<MaintenanceSchedule?> maintenanceSchedule({
    required int km,
    required DateTime lastService,
  }) async {
    try {
      final res = await MetaAgentClient().carMaintenanceSchedule(
        km: km,
        lastService: lastService,
      );
      return MaintenanceSchedule.fromJson(res);
    } catch (e) {
      if (kDebugMode) debugPrint('[vehicle] schedule error: $e');
      return null;
    }
  }

  Future<bool> fuelLog({
    required double liters,
    required double pricePerLiter,
    required int odometerKm,
    String? station,
  }) async {
    try {
      await MetaAgentClient().fuelLog(
        liters: liters,
        pricePerLiter: pricePerLiter,
        odometerKm: odometerKm,
        station: station,
      );
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[vehicle] fuel_log error: $e');
      return false;
    }
  }
}

class MaintenanceSchedule {
  final List<MaintenanceItem> due;
  MaintenanceSchedule(this.due);

  factory MaintenanceSchedule.fromJson(Map<String, dynamic> j) {
    final items = (j['items'] as List?) ?? const [];
    return MaintenanceSchedule(
      items
          .cast<Map>()
          .map((e) => MaintenanceItem.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}

class MaintenanceItem {
  final String name;
  final int dueAtKm;
  final DateTime? dueAtDate;
  final String? note;
  MaintenanceItem({required this.name, required this.dueAtKm, this.dueAtDate, this.note});

  factory MaintenanceItem.fromJson(Map<String, dynamic> j) {
    DateTime? d;
    final raw = j['due_at_date'];
    if (raw is String) d = DateTime.tryParse(raw);
    return MaintenanceItem(
      name: j['name']?.toString() ?? '',
      dueAtKm: (j['due_at_km'] as num?)?.toInt() ?? 0,
      dueAtDate: d,
      note: j['note']?.toString(),
    );
  }
}
