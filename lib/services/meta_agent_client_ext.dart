import 'dart:convert';
import 'package:http/http.dart' as http;

import 'meta_agent_client.dart';

/// Onda 8 — REST helpers on top of MetaAgentClient.
/// These hit `https://ironedgeai.com/api/...` endpoints exposed by the
/// SALIX backend (tools backend, push register, health, smart_home, vehicle,
/// accessibility). All return raw JSON / DTO-friendly maps; service layer
/// does the rest. Auth is via session cookie (web) or bearer token (mobile)
/// — same as the streaming endpoint.
extension MetaAgentClientRest on MetaAgentClient {
  static const _base = MetaAgentClient.baseUrl;
  static final _http = http.Client();

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final r = await _http
        .post(Uri.parse('$_base$path'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(body))
        .timeout(timeout);
    final txt = r.body;
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw http.ClientException('HTTP ${r.statusCode}: $txt', Uri.parse('$_base$path'));
    }
    if (txt.isEmpty) return const {};
    final j = jsonDecode(txt);
    if (j is Map<String, dynamic>) return j;
    return {'data': j};
  }

  Future<Map<String, dynamic>> _get(String path,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final r = await _http.get(Uri.parse('$_base$path')).timeout(timeout);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw http.ClientException('HTTP ${r.statusCode}: ${r.body}', Uri.parse('$_base$path'));
    }
    if (r.body.isEmpty) return const {};
    final j = jsonDecode(r.body);
    if (j is Map<String, dynamic>) return j;
    return {'data': j};
  }

  // ---------- Push Notifications ----------
  Future<void> registerPushToken({required String token, required String platform}) async {
    await _post('/api/push/register', {'token': token, 'platform': platform});
  }

  // ---------- Health ----------
  Future<Map<String, dynamic>> getHealthSnapshot() async {
    return _get('/api/health/snapshot');
  }

  Future<void> logHealthEntry({required String kind, required double value, required DateTime at}) async {
    await _post('/api/health/log', {
      'kind': kind,
      'value': value,
      'at': at.toUtc().toIso8601String(),
    });
  }

  // ---------- Smart Home ----------
  Future<Map<String, dynamic>> smartHomeCommand({
    required String device,
    required String action,
    Object? value,
  }) async {
    return _post('/api/smart-home/command', {
      'device': device,
      'action': action,
      if (value != null) 'value': value,
    });
  }

  Future<List<Map<String, dynamic>>> smartHomeDevices() async {
    final j = await _get('/api/smart-home/devices');
    final raw = j['devices'];
    if (raw is List) {
      return raw.cast<Map>().map((e) => e.cast<String, dynamic>()).toList(growable: false);
    }
    return const [];
  }

  // ---------- Vehicle ----------
  Future<Map<String, dynamic>> carMaintenanceSchedule({
    required int km,
    required DateTime lastService,
  }) async {
    return _post('/api/vehicle/maintenance-schedule', {
      'km': km,
      'last_service': lastService.toUtc().toIso8601String(),
    });
  }

  Future<void> fuelLog({
    required double liters,
    required double pricePerLiter,
    required int odometerKm,
    String? station,
  }) async {
    await _post('/api/vehicle/fuel-log', {
      'liters': liters,
      'price_per_liter': pricePerLiter,
      'odometer_km': odometerKm,
      if (station != null) 'station': station,
    });
  }

  // ---------- Accessibility ----------
  Future<String> a11yScreenOcr(List<int> bytes) async {
    final r = await _post('/api/a11y/ocr', {
      'image_b64': base64Encode(bytes),
    });
    return (r['text'] ?? '').toString();
  }

  Future<String> a11yDescribeImage(List<int> bytes) async {
    final r = await _post('/api/a11y/describe', {
      'image_b64': base64Encode(bytes),
    });
    return (r['description'] ?? '').toString();
  }
}
