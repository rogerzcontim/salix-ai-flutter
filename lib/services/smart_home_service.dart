import 'package:flutter/foundation.dart';

import 'meta_agent_client.dart';
import 'meta_agent_client_ext.dart';

/// Onda 8 — Smart Home abstraction.
///
/// Thin client for the backend `home_command` tool. The server holds OAuth
/// tokens for Google Home / Alexa / HomeKit and dispatches the actual call.
/// The Flutter app only ever talks to the SALIX backend, so credentials
/// never live on device.
class SmartHomeService {
  SmartHomeService._();
  static final instance = SmartHomeService._();

  Future<HomeCommandResult> command({
    required String device,
    required String action,
    Object? value,
  }) async {
    try {
      final res = await MetaAgentClient().smartHomeCommand(
        device: device,
        action: action,
        value: value,
      );
      return HomeCommandResult(ok: true, message: res['message']?.toString() ?? 'OK', raw: res);
    } catch (e) {
      if (kDebugMode) debugPrint('[smart_home] command error: $e');
      return HomeCommandResult(ok: false, message: e.toString());
    }
  }

  Future<List<HomeDevice>> listDevices() async {
    try {
      final raw = await MetaAgentClient().smartHomeDevices();
      return raw.map((e) => HomeDevice.fromJson(e)).toList(growable: false);
    } catch (e) {
      if (kDebugMode) debugPrint('[smart_home] list error: $e');
      return const [];
    }
  }
}

class HomeCommandResult {
  final bool ok;
  final String message;
  final Map<String, dynamic>? raw;
  HomeCommandResult({required this.ok, required this.message, this.raw});
}

class HomeDevice {
  final String id;
  final String name;
  final String type; // light|switch|thermostat|lock|...
  final String backend; // google_home|alexa|homekit
  final Map<String, dynamic> state;

  HomeDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.backend,
    required this.state,
  });

  factory HomeDevice.fromJson(Map<String, dynamic> j) => HomeDevice(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        type: j['type']?.toString() ?? 'unknown',
        backend: j['backend']?.toString() ?? 'unknown',
        state: (j['state'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}
