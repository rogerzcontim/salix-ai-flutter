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

  /// v9.0.0+34: Dart-side singleton.
  ///
  /// Bug Roger 29/abr (Galaxy S24 Ultra v8.0.0+33): "quando ligei o wake
  /// de novo fechou o app sozinho". Root cause: chat_page.dart and
  /// settings_page.dart each held their own [WakeWordService()] instance
  /// (line 32 and line 31 respectively), so when the user toggled wake
  /// ON in settings, BOTH instances tried to subscribe to the EventChannel.
  /// Native side has only ONE [EventSink] slot
  /// ([WakeWordService.sink] in Kotlin), so the settings-page subscription
  /// overwrote chat-page's. When settings popped, [onCancel] nulled the
  /// sink while the native service was still emitting -- triggering an
  /// unhandled NPE on the Kotlin side that took down the process.
  ///
  /// With a singleton, both pages share the same [_sub] and the same
  /// [running] flag. Calling [start] when already running is a no-op
  /// (returns true).
  static final WakeWordService _instance = WakeWordService._internal();
  factory WakeWordService() => _instance;
  WakeWordService._internal();

  StreamSubscription? _sub;
  bool _running = false;
  final bool _supported = Platform.isAndroid; // iOS = false (limitação plataforma)

  /// v9.0.0+34: registered onDetected handlers, fan-out style. Both
  /// chat_page and settings_page may register handlers (settings registers
  /// an empty no-op just to start the service; chat registers the real
  /// callback). We invoke ALL of them on each detection.
  final List<Future<void> Function()> _onDetectedHandlers = [];
  final List<void Function(WakeWordEvent)> _onEventHandlers = [];

  bool get supported => _supported;
  bool get running => _running;

  /// Liga o foreground service e começa a escutar wake word "Oi SALIX".
  ///
  /// [onDetected] é chamado a cada detecção; o service continua
  /// escutando depois (chame [stop] para liberar o microfone).
  ///
  /// v9.0.0+34: idempotent. Multiple callers (chat_page, settings_page)
  /// can call [start] independently; subsequent calls just register
  /// additional handlers on the same singleton EventChannel subscription.
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

    // Register handlers FIRST so even if the service was already running,
    // the new handler wires up.
    _onDetectedHandlers.add(onDetected);
    if (onEvent != null) _onEventHandlers.add(onEvent);

    if (_running) return true;

    try {
      final ok = await _method.invokeMethod<bool>('start');
      _running = ok ?? false;
      if (!_running) {
        // Don't keep stale handlers if start failed.
        _onDetectedHandlers.remove(onDetected);
        if (onEvent != null) _onEventHandlers.remove(onEvent);
        return false;
      }

      // v9.0.0+34: SINGLE shared subscription. Native side has only one
      // EventSink slot; multiple Dart .listen() calls would clobber each
      // other on the Kotlin side and crash the process.
      _sub ??= _events.receiveBroadcastStream().listen((raw) async {
        if (raw is Map) {
          final ev = WakeWordEvent.fromMap(raw);
          // Fan out to all event handlers (defensive copy in case a
          // handler mutates the list).
          for (final h in List.of(_onEventHandlers)) {
            try { h(ev); } catch (_) {}
          }
          if (ev.type == 'detected') {
            for (final h in List.of(_onDetectedHandlers)) {
              try {
                await h();
              } catch (e, st) {
                if (kDebugMode) {
                  debugPrint('[wakeword] onDetected handler threw: $e\n$st');
                }
              }
            }
          }
        }
      }, onError: (e) {
        for (final h in List.of(_onEventHandlers)) {
          try { h(WakeWordEvent(type: 'error', message: '$e')); } catch (_) {}
        }
      });

      return true;
    } on PlatformException catch (e) {
      _running = false;
      _onDetectedHandlers.remove(onDetected);
      if (onEvent != null) _onEventHandlers.remove(onEvent);
      onEvent?.call(WakeWordEvent(
        type: 'error',
        message: 'PlatformException: ${e.code} ${e.message}',
      ));
      return false;
    } catch (e) {
      _running = false;
      _onDetectedHandlers.remove(onDetected);
      if (onEvent != null) _onEventHandlers.remove(onEvent);
      onEvent?.call(WakeWordEvent(type: 'error', message: '$e'));
      return false;
    }
  }

  /// Para o foreground service e libera o microfone.
  ///
  /// v9.0.0+34: clears ALL fan-out handlers and tears down the singleton
  /// EventChannel subscription. Only call this when the user explicitly
  /// disables wake word in settings (toggle OFF). chat_page.dispose()
  /// also calls this, but the runtime will tear down the whole process
  /// in that case anyway.
  Future<void> stop() async {
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    _running = false;
    _onDetectedHandlers.clear();
    _onEventHandlers.clear();
  }

  /// v10.0.0+35: PAUSE the wake-word AudioRecord temporarily so a foreground
  /// VoiceService.startListening() can grab the mic without competing for
  /// the AudioSource slot. Returns true if the native side acknowledged.
  ///
  /// Bug Roger 29/abr (Galaxy S24 Ultra): "nao esta permitindo gravar
  /// mensagem de voz". Root cause: WakeWordService holds an AudioRecord on
  /// VOICE_RECOGNITION; on Samsung One UI a second AudioRecord init for
  /// SpeechRecognizer fails silently (returns no result, no callback). We
  /// pause the wake word loop, let STT capture, then resume.
  Future<bool> pauseForForegroundMic() async {
    if (!_supported) return true;
    try {
      final r = await _method.invokeMethod<bool>('pauseForForegroundMic');
      return r ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('[wakeword] pauseForForegroundMic failed: $e');
      return false;
    }
  }

  /// v10.0.0+35: RESUME wake-word listening after a foreground STT session.
  /// Idempotent — safe to call even if pauseForForegroundMic() wasn't.
  Future<bool> resumeAfterForegroundMic() async {
    if (!_supported) return true;
    try {
      final r = await _method.invokeMethod<bool>('resumeAfterForegroundMic');
      return r ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('[wakeword] resumeAfterForegroundMic failed: $e');
      return false;
    }
  }

  /// v10.0.0+35: force-restart the FG service. Used by settings toggle when
  /// the Dart-side `running` flag may be stale (process was killed without
  /// the Dart layer noticing — happens on Galaxy S24 Doze). Calling this
  /// always invokes `stop` then `start`, regardless of [_running].
  Future<bool> forceRestart({
    required Future<void> Function() onDetected,
    void Function(WakeWordEvent)? onEvent,
  }) async {
    if (!_supported) return false;
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    _running = false;
    _onDetectedHandlers.clear();
    _onEventHandlers.clear();
    return await start(onDetected: onDetected, onEvent: onEvent);
  }

  /// Ajusta a sensitivity (0.0..1.0). 0.5 default. Aumentar = mais detecções
  /// (e mais falsos positivos).
  Future<void> setSensitivity(double s) async {
    if (!_supported) return;
    try {
      await _method.invokeMethod('setSensitivity', {'sensitivity': s.clamp(0.0, 1.0)});
    } catch (_) {}
  }

  // ---------- v4.1.0+29: Samsung Galaxy battery optimization helpers ----------

  /// Verifica se a app já está na lista "Sem restrições" (ignoring battery
  /// optimizations). Retorna true em iOS pra não bloquear lógica.
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_supported) return true;
    try {
      final r = await _method.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Pede pro Android abrir o dialog ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS.
  /// User aceita -> volta pro app -> chamamos isIgnoringBatteryOptimizations()
  /// pra confirmar. Em Samsung One UI o user cai em uma tela com toggle
  /// "Permitir atividade em segundo plano" ou similar.
  ///
  /// Retorna true se ao final está ignoring (já estava OU acabou de aceitar).
  Future<bool> requestIgnoreBatteryOpt() async {
    if (!_supported) return true;
    try {
      final already = await isIgnoringBatteryOptimizations();
      if (already) return true;
      await _method.invokeMethod('requestIgnoreBatteryOptimizations');
      // user vai pra Settings e volta — damos tempo pro foreground voltar
      await Future<void>.delayed(const Duration(seconds: 2));
      return await isIgnoringBatteryOptimizations();
    } catch (e) {
      if (kDebugMode) debugPrint('[wakeword] requestIgnoreBatteryOpt failed: $e');
      return false;
    }
  }

  /// Abre Configurações > Apps > SALIX AI (página de detalhes).
  /// Útil pra Samsung One UI onde Battery > Sem restrições só fica
  /// acessível por essa rota.
  Future<void> openAppDetailsSettings() async {
    if (!_supported) return;
    try {
      await _method.invokeMethod('openAppDetailsSettings');
    } catch (_) {}
  }

    /// Status atual: {running:bool, lowBattery:bool, model:String}
  Future<Map<String, dynamic>> status() async {
    if (!_supported) {
      return {'running': false, 'supported': false};
    }
    try {
      final m = await _method.invokeMethod<Map>('status');
      // v10.0.0+35: sync Dart-side flag with native ground truth so a stale
      // `_running` flag (after Samsung Doze kill) gets corrected.
      final native = Map<String, dynamic>.from(m ?? {});
      final r = native['running'];
      if (r is bool) _running = r;
      return native;
    } catch (_) {
      return {'running': _running, 'supported': true};
    }
  }
}
