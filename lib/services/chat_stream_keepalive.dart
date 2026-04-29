// lib/services/chat_stream_keepalive.dart
//
// v7.0.0+32 — Foreground service permanente "SALIX em segundo plano".
//
// Roger 29/abr (Galaxy S24 Ultra Samsung One UI):
// "Quando esta pensando para responder e a tela fecha, a SALIX manda
//  mensagem interrompendo, e interrompe a resposta. Tem que permanecer
//  ativo em segundo plano direto para nao acontecer isso."
//
// Mudanca v6 -> v7:
//   v6: subia FG service so durante _send(), para no finally{}.
//   v7: sobe na inicializacao do app (e em BOOT_COMPLETED) e nunca para,
//       garantindo que o processo SALIX nunca seja morto pelo OS — nem
//       quando o usuario tira o app da tela, nem quando a tela trava.
//
// API:
//   - ensurePersistent(): liga em modo persistente (idempotente).
//   - bumpStreaming(): mostra "SALIX esta respondendo..." na notif (notif
//     channel low-importance, sem som).
//   - bumpIdle(): volta a notif para "SALIX ativa em segundo plano".
//   - stop(): so chamado em logout/uninstall — nao usar em fluxo normal.
//
// O servico nativo (ChatStreamService.kt) retorna START_STICKY agora, e o
// BootReceiver (BOOT_COMPLETED) o reinicia apos reboot.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ChatStreamKeepalive {
  static const MethodChannel _method = MethodChannel('salix.chat_stream');

  static final ChatStreamKeepalive _instance = ChatStreamKeepalive._();
  factory ChatStreamKeepalive() => _instance;
  ChatStreamKeepalive._();

  bool _running = false;
  bool _persistent = false;
  bool get running => _running;
  bool get supported => Platform.isAndroid;

  /// v7: liga em modo persistente. Notif de baixa importancia "SALIX ativa
  /// em segundo plano". Idempotente.
  Future<bool> ensurePersistent() async {
    if (!supported) return true;
    try {
      final ok = await _method.invokeMethod<bool>('startPersistent');
      _running = ok ?? false;
      _persistent = _running;
      return _running;
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('[chat_stream] ensurePersistent failed: ${e.code} ${e.message}');
      }
      return false;
    } catch (e) {
      if (kDebugMode) debugPrint('[chat_stream] ensurePersistent failed: $e');
      return false;
    }
  }

  /// Atualiza a notif para "SALIX esta respondendo...". Usar quando
  /// _send() abre o stream.
  Future<void> bumpStreaming() async {
    if (!supported) return;
    try {
      await _method.invokeMethod('bumpStreaming');
    } catch (e) {
      if (kDebugMode) debugPrint('[chat_stream] bumpStreaming failed: $e');
    }
  }

  /// Volta a notif para "SALIX ativa em segundo plano". Usar no finally{}
  /// de _send().
  Future<void> bumpIdle() async {
    if (!supported) return;
    try {
      await _method.invokeMethod('bumpIdle');
    } catch (e) {
      if (kDebugMode) debugPrint('[chat_stream] bumpIdle failed: $e');
    }
  }

  /// LEGACY: alias de [ensurePersistent] para nao quebrar callers v6.
  Future<bool> start() => ensurePersistent();

  /// PARA o servico — so usar em logout / desinstalar / debug. Em fluxo
  /// normal NAO chame: o ponto da v7 eh ele ficar vivo direto.
  Future<void> stop() async {
    if (!supported) return;
    try {
      await _method.invokeMethod('stop');
    } catch (e) {
      if (kDebugMode) debugPrint('[chat_stream] stop failed: $e');
    } finally {
      _running = false;
      _persistent = false;
    }
  }

  /// Le o estado real do nativo (caso o OS tenha matado o servico).
  Future<bool> isRunning() async {
    if (!supported) return false;
    try {
      final m = await _method.invokeMethod<Map>('status');
      final r = (m?['running'] ?? false) == true;
      _running = r;
      return r;
    } catch (_) {
      return _running;
    }
  }

  bool get persistent => _persistent;
}
