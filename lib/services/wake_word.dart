// lib/services/wake_word.dart
//
// Onda 3 — Wake word "Oi SALIX" (Android-only por enquanto)
//
// Estratégia:
//   - Usamos o canal nativo (MethodChannel) `salix.wake_word` que conversa
//     com o Foreground Service Kotlin (`WakeWordService.kt`).
//   - O serviço nativo carrega o modelo Picovoice Porcupine custom
//     ("Oi SALIX" treinado no console Picovoice) e fica escutando em
//     background mesmo com app minimizado / tela apagada.
//   - Quando detecta wake word, envia evento via EventChannel
//     `salix.wake_word.events` -> Dart aciona STT (VoiceService já existente).
//
// Battery aware:
//   - Pausa automaticamente se nível bateria < 15% (lado nativo lê
//     BatteryManager). Aqui só lemos `state.lowBattery` pra UI.
//
// iOS:
//   - Plugin Picovoice Porcupine FUNCIONA em iOS, mas BackgroundAudio é
//     limitado (Apple não permite always-listening custom). Documentamos
//     como Siri Shortcut fallback no `docs/ios_wake_word_fallback.md`.
//   - Aqui detectamos plataforma e simplesmente desativamos no iOS.
//
// Permissões necessárias (já no AndroidManifest):
//   - RECORD_AUDIO
//   - FOREGROUND_SERVICE
//   - FOREGROUND_SERVICE_MICROPHONE (Android 14+)
//   - WAKE_LOCK
//
// Uso (em chat_page.dart ou onde a voz já é instanciada):
//
//   final ww = WakeWordService();
//   await ww.start(
//     onDetected: () async {
//       await voice.startListening(
//         onPartial: (p) => ...,
//         onFinal: (f) => sendQuery(f),
//       );
//     },
//   );
//

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WakeWordEvent {
  final String type; // "detected" | "started" | "stopped" | "error" | "battery_pause"
  final String? message;
  final double? confidence;
  WakeWordEvent({required this.type, this.message, this.confidence});

  factory WakeWordEvent.fromMap(Map<dynamic, dynamic> m) => WakeWordEvent(
        type: (m['type'] ?? 'unknown') as String,
        message: m['message'] as String?,
        confidence: (m['confidence'] is num)
            ? (m['confidence'] as num).toDouble()
            : null,
      );
}

class WakeWordService {
  static const MethodChannel _method = MethodChannel('salix.wake_word');
  static const EventChannel  _events = EventChannel('salix.wake_word.events');

  StreamSubscription? _sub;
  bool _running = false;
  bool _supported = Platform.isAndroid; // iOS = false (limitação plataforma)

  bool get supported => _supported;
  bool get running => _running;

  /// Liga o foreground service e começa a escutar wake word "Oi SALIX".
  ///
  /// [onDetected] é chamado UMA VEZ a cada detecção; depois do callback,
  /// o service continua escutando (mas pode-se chamar [stop()] dentro do
  /// callback se quiser ouvir só uma vez).
  Future<bool> start({
    required Future<void> Function() onDetected,
    void Function(WakeWordEvent)? onEvent,
  }) async {
    if (!_supported) {
      onEvent?.call(WakeWordEvent(
        type: 'unsupported',
        message: 'Wake word disponível apenas no Android. iOS use Siri Shortcut.',
      ));
      return false;
    }
    if (_running) return true;

    try {
      final ok = await _method.invokeMethod<bool>('start');
      _running = ok ?? false;
      if (!_running) return false;

      _sub = _events.receiveBroadcastStream().listen((raw) async {
        if (raw is Map) {
          final ev = WakeWordEvent.fromMap(raw);
          onEvent?.call(ev);
          if (ev.type == 'detected') {
            try {
              await onDetected();
            } catch (e, st) {
              if (kDebugMode) {
                debugPrint('[wakeword] onDetected threw: $e\n$st');
              }
            }
          }
        }
      }, onError: (e) {
        onEvent?.call(WakeWordEvent(type: 'error', message: '$e'));
      });

      return true;
    } on PlatformException catch (e) {
      _running = false;
      onEvent?.call(WakeWordEvent(
        type: 'error',
        message: 'PlatformException: ${e.code} ${e.message}',
      ));
      return false;
    } catch (e) {
      _running = false;
      onEvent?.call(WakeWordEvent(type: 'error', message: '$e'));
      return false;
    }
  }

  /// Para o foreground service e libera o microfone.
  Future<void> stop() async {
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
    await _sub?.cancel();
    _sub = null;
    _running = false;
  }

  /// Ajusta a sensitivity (0.0..1.0). 0.5 default. Aumentar = mais detecções
  /// (e mais falsos positivos).
  Future<void> setSensitivity(double s) async {
    if (!_supported) return;
    try {
      await _method.invokeMethod('setSensitivity', {'sensitivity': s.clamp(0.0, 1.0)});
    } catch (_) {}
  }

  /// Status atual: {running:bool, lowBattery:bool, model:String}
  Future<Map<String, dynamic>> status() async {
    if (!_supported) {
      return {'running': false, 'supported': false};
    }
    try {
      final m = await _method.invokeMethod<Map>('status');
      return Map<String, dynamic>.from(m ?? {});
    } catch (_) {
      return {'running': _running, 'supported': true};
    }
  }
}
