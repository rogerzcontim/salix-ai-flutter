// SALIX onda 4 — adapter fino: action runner local
//
// Compatibilidade: todo o código novo deve usar [RoutineEngine] direto. Esta
// classe permanece como wrapper para a tela "Rotinas" (botão Testar agora) e
// para outros chamadores antigos.

import 'routine_engine.dart';

class ActionResult {
  final String tool;
  final bool ok;
  final String message;
  ActionResult(this.tool, this.ok, this.message);

  factory ActionResult.from(RoutineActionLog log) =>
      ActionResult(log.tool, log.ok, log.message);
}

class ActionExecutor {
  static Future<List<ActionResult>> runAll(
      List<Map<String, dynamic>> actions) async {
    final logs = await RoutineEngine.runActions(actions);
    return logs.map(ActionResult.from).toList(growable: false);
  }

  static Future<ActionResult> runOne(
      String tool, Map<String, dynamic> args) async {
    final r = await RoutineEngine.runOne(tool, args);
    return ActionResult(tool, r.ok, r.message);
  }
}
