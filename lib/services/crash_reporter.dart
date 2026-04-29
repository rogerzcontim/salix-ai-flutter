// CrashReporter — captura erros Flutter/Zone e envia pra https://salix-ai.com/api/_crash.
//
// Princípios:
//   - NUNCA pode causar crash recursivo. Tudo em try/catch.
//   - Se a rede estiver fora, mantém na fila in-memory e re-tenta em init/report.
//   - Plugin calls (PackageInfo) são opcionais: se falhar, segue com 'unknown'.
//   - v2.0.0+21: aceita flag isInfo pra telemetria (passos antes/depois de
//     plugin nativo) sem poluir contagem real de crashes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class CrashReporter {
  static const _endpoint = 'https://salix-ai.com/api/_crash';
  static String? _version;
  static String? _device;
  static final List<Map<String, dynamic>> _pending = <Map<String, dynamic>>[];
  static bool _initialized = false;

  static Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      _version = 'unknown';
    }
    try {
      _device =
          '${Platform.operatingSystem}/${Platform.operatingSystemVersion}';
    } catch (_) {
      _device = 'unknown';
    }
    _initialized = true;
    // Tenta drenar fila acumulada antes do init (caso report() tenha sido chamado).
    unawaited(_flushPending());
  }

  /// Reporta um erro/crash. Se [isInfo]=true, marca como telemetria
  /// (não-fatal) — o backend pode filtrar isso na query.
  static Future<void> report(
    Object error,
    StackTrace? stack, {
    String? context,
    bool isInfo = false,
  }) async {
    try {
      final payload = <String, dynamic>{
        'v': _version ?? 'unknown',
        'device': _device ?? 'unknown',
        'msg': error.toString(),
        'stack': stack?.toString() ?? '',
        'context': context ?? '',
        'level': isInfo ? 'info' : 'error',
        'ts': DateTime.now().toIso8601String(),
      };
      debugPrint('[CrashReporter:${isInfo ? "info" : "error"}] $context: $error');
      _pending.add(payload);
      unawaited(_flushPending());
    } catch (e) {
      // Ultima linha de defesa — nunca deixa o reporter quebrar o app.
      debugPrint('[CrashReporter] internal error: $e');
    }
  }

  /// Atalho semântico pra registrar telemetria (passo BEFORE_X / AFTER_X).
  static Future<void> info(String context, {String message = 'step'}) async {
    return report(message, null, context: context, isInfo: true);
  }

  static Future<void> _flushPending() async {
    if (_pending.isEmpty) return;
    final list = List<Map<String, dynamic>>.from(_pending);
    for (final p in list) {
      try {
        final r = await http
            .post(
              Uri.parse(_endpoint),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode(p),
            )
            .timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          _pending.remove(p);
        }
      } catch (_) {
        // Rede fora — mantém na fila pra próxima.
      }
    }
  }

  static bool get isInitialized => _initialized;
}
