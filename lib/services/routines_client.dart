// SALIX onda 4 — cliente HTTP do daemon salix-routines-runner :9298
//
// Faz CRUD em rotinas (IFTTT-like) e geofences. Trigger types:
//   voice    {voice_phrase, lang}
//   time     {cron}            (ex: "0 9 * * 1" = toda segunda 9h)
//   geo      {geofence_id, edge: "enter"|"exit"}
//   app_open {package}
//
// Actions é uma lista ordenada de objetos {tool, args} interpretados pelo
// runner. Tools whitelisted (server-side):
//   open_app, set_volume, set_brightness, flashlight, vibrate,
//   open_url, smart_home_webhook, send_notification, run_meta_agent.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String kRoutinesBase = 'https://ironedgeai.com/api/routines';

class Routine {
  final int? id;
  final int userId;
  final String name;
  final String triggerType;
  final Map<String, dynamic> triggerConfig;
  final List<Map<String, dynamic>> actions;
  final bool enabled;

  Routine({
    this.id,
    required this.userId,
    required this.name,
    required this.triggerType,
    required this.triggerConfig,
    required this.actions,
    this.enabled = true,
  });

  factory Routine.fromJson(Map<String, dynamic> j) => Routine(
        id: j['id'] as int?,
        userId: j['user_id'] as int? ?? 0,
        name: j['name']?.toString() ?? '',
        triggerType: j['trigger_type']?.toString() ?? 'voice',
        triggerConfig: (j['trigger_config'] is Map)
            ? Map<String, dynamic>.from(j['trigger_config'] as Map)
            : <String, dynamic>{},
        actions: (j['actions'] is List)
            ? List<Map<String, dynamic>>.from(
                (j['actions'] as List).map((e) => Map<String, dynamic>.from(e)))
            : <Map<String, dynamic>>[],
        enabled: j['enabled'] != false,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'user_id': userId,
        'name': name,
        'trigger_type': triggerType,
        'trigger_config': triggerConfig,
        'actions': actions,
        'enabled': enabled,
      };

  Routine copyWith({
    int? id,
    int? userId,
    String? name,
    String? triggerType,
    Map<String, dynamic>? triggerConfig,
    List<Map<String, dynamic>>? actions,
    bool? enabled,
  }) =>
      Routine(
        id: id ?? this.id,
        userId: userId ?? this.userId,
        name: name ?? this.name,
        triggerType: triggerType ?? this.triggerType,
        triggerConfig: triggerConfig ?? this.triggerConfig,
        actions: actions ?? this.actions,
        enabled: enabled ?? this.enabled,
      );
}

class Geofence {
  final int? id;
  final int userId;
  final String name;
  final double lat;
  final double lng;
  final int radiusM;
  final List<Map<String, dynamic>> onEnter;
  final List<Map<String, dynamic>> onExit;
  final bool enabled;

  Geofence({
    this.id,
    required this.userId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.radiusM,
    this.onEnter = const [],
    this.onExit = const [],
    this.enabled = true,
  });

  factory Geofence.fromJson(Map<String, dynamic> j) => Geofence(
        id: j['id'] as int?,
        userId: j['user_id'] as int? ?? 0,
        name: j['name']?.toString() ?? '',
        lat: (j['lat'] as num?)?.toDouble() ?? 0,
        lng: (j['lng'] as num?)?.toDouble() ?? 0,
        radiusM: (j['radius_m'] as num?)?.toInt() ?? 100,
        onEnter: (j['on_enter'] is List)
            ? List<Map<String, dynamic>>.from(
                (j['on_enter'] as List).map((e) => Map<String, dynamic>.from(e)))
            : const [],
        onExit: (j['on_exit'] is List)
            ? List<Map<String, dynamic>>.from(
                (j['on_exit'] as List).map((e) => Map<String, dynamic>.from(e)))
            : const [],
        enabled: j['enabled'] != false,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'user_id': userId,
        'name': name,
        'lat': lat,
        'lng': lng,
        'radius_m': radiusM,
        'on_enter': onEnter,
        'on_exit': onExit,
        'enabled': enabled,
      };
}

class RoutinesClient {
  final String base;
  RoutinesClient({this.base = kRoutinesBase});

  Future<String?> _token() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('salix_auth_token');
  }

  Map<String, String> _headers([String? token]) => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  // ----------------------------------------------------------- Routines CRUD

  Future<List<Routine>> listRoutines({int? userId}) async {
    final tok = await _token();
    final qs = userId != null ? '?user_id=$userId' : '';
    final r = await http.get(Uri.parse('$base/routines$qs'),
        headers: _headers(tok));
    if (r.statusCode != 200) {
      throw Exception('list routines HTTP ${r.statusCode}');
    }
    final j = jsonDecode(r.body);
    if (j is Map && j['routines'] is List) {
      return (j['routines'] as List)
          .map((e) => Routine.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    if (j is List) {
      return j.map((e) => Routine.fromJson(Map<String, dynamic>.from(e))).toList();
    }
    return [];
  }

  Future<Routine> createRoutine(Routine r) async {
    final tok = await _token();
    final res = await http.post(Uri.parse('$base/routines'),
        headers: _headers(tok), body: jsonEncode(r.toJson()));
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('create routine HTTP ${res.statusCode}: ${res.body}');
    }
    return Routine.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<Routine> updateRoutine(Routine r) async {
    if (r.id == null) throw ArgumentError('id null');
    final tok = await _token();
    final res = await http.put(Uri.parse('$base/routines/${r.id}'),
        headers: _headers(tok), body: jsonEncode(r.toJson()));
    if (res.statusCode != 200) {
      throw Exception('update routine HTTP ${res.statusCode}: ${res.body}');
    }
    return Routine.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> deleteRoutine(int id) async {
    final tok = await _token();
    final res = await http.delete(Uri.parse('$base/routines/$id'),
        headers: _headers(tok));
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw Exception('delete routine HTTP ${res.statusCode}');
    }
  }

  Future<void> triggerRoutine(int id) async {
    final tok = await _token();
    final res = await http.post(Uri.parse('$base/routines/$id/trigger'),
        headers: _headers(tok));
    if (res.statusCode != 200) {
      throw Exception('trigger routine HTTP ${res.statusCode}: ${res.body}');
    }
  }

  // ---------------------------------------------------------- Geofences CRUD

  Future<List<Geofence>> listGeofences({int? userId}) async {
    final tok = await _token();
    final qs = userId != null ? '?user_id=$userId' : '';
    final r = await http.get(Uri.parse('$base/geofences$qs'),
        headers: _headers(tok));
    if (r.statusCode != 200) {
      throw Exception('list geofences HTTP ${r.statusCode}');
    }
    final j = jsonDecode(r.body);
    if (j is Map && j['geofences'] is List) {
      return (j['geofences'] as List)
          .map((e) => Geofence.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    if (j is List) {
      return j.map((e) => Geofence.fromJson(Map<String, dynamic>.from(e))).toList();
    }
    return [];
  }

  Future<Geofence> createGeofence(Geofence g) async {
    final tok = await _token();
    final res = await http.post(Uri.parse('$base/geofences'),
        headers: _headers(tok), body: jsonEncode(g.toJson()));
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('create geofence HTTP ${res.statusCode}: ${res.body}');
    }
    return Geofence.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> deleteGeofence(int id) async {
    final tok = await _token();
    final res = await http.delete(Uri.parse('$base/geofences/$id'),
        headers: _headers(tok));
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw Exception('delete geofence HTTP ${res.statusCode}');
    }
  }

  /// Push the current device location so the runner can evaluate enter/exit.
  /// The runner debounces and persists last-known location per user.
  Future<void> pushLocation({
    required int userId,
    required double lat,
    required double lng,
    double? accuracyM,
  }) async {
    final tok = await _token();
    final res = await http.post(Uri.parse('$base/geofences/ping'),
        headers: _headers(tok),
        body: jsonEncode({
          'user_id': userId,
          'lat': lat,
          'lng': lng,
          if (accuracyM != null) 'accuracy_m': accuracyM,
          'ts': DateTime.now().toUtc().toIso8601String(),
        }));
    if (res.statusCode != 200) {
      throw Exception('ping HTTP ${res.statusCode}');
    }
  }
}
