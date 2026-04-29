// SALIX onda 4 — UI Rotinas (IFTTT-like)

import 'package:flutter/material.dart';

import '../models/persona.dart';
import '../services/action_executor.dart';
import '../services/persona_store.dart';
import '../services/routines_client.dart';
import '../theme.dart';
import 'routine_edit_page.dart';

class RoutinesPage extends StatefulWidget {
  const RoutinesPage({super.key});
  @override
  State<RoutinesPage> createState() => _RoutinesPageState();
}

class _RoutinesPageState extends State<RoutinesPage> {
  final _client = RoutinesClient();
  Persona? _persona;
  List<Routine> _routines = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Persona id is a UUID string but the backend column is BIGINT — derive a
  /// stable 53-bit unsigned hash so the same device always maps to the same
  /// user_id.
  static int personaUserId(Persona p) {
    int h = 0xcbf29ce484222325 & 0x7fffffffffffffff;
    for (final code in p.id.codeUnits) {
      h ^= code;
      h = (h * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return h;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await PersonaStore().active();
      _persona = p;
      if (p == null) {
        setState(() {
          _routines = [];
          _loading = false;
        });
        return;
      }
      final list = await _client.listRoutines(userId: personaUserId(p));
      setState(() {
        _routines = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = 'falha ao carregar: $e';
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final p = _persona;
    if (p == null) return;
    final r = Routine(
      userId: personaUserId(p),
      name: 'Nova rotina',
      triggerType: 'voice',
      triggerConfig: {'voice_phrase': '', 'lang': p.voice},
      actions: [],
      enabled: true,
    );
    final saved = await Navigator.of(context).push<Routine>(MaterialPageRoute(
      builder: (_) => RoutineEditPage(initial: r, isNew: true),
    ));
    if (saved != null) _load();
  }

  Future<void> _edit(Routine r) async {
    final saved = await Navigator.of(context).push<Routine>(MaterialPageRoute(
      builder: (_) => RoutineEditPage(initial: r, isNew: false),
    ));
    if (saved != null) _load();
  }

  Future<void> _toggle(Routine r) async {
    try {
      await _client.updateRoutine(r.copyWith(enabled: !r.enabled));
      _load();
    } catch (e) {
      _snack('falha toggle: $e');
    }
  }

  Future<void> _delete(Routine r) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: IronTheme.bgPanel,
            title: const Text('Apagar rotina?'),
            content: Text('"${r.name}" será removida.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: IronTheme.danger),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Apagar'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || r.id == null) return;
    try {
      await _client.deleteRoutine(r.id!);
      _load();
    } catch (e) {
      _snack('falha apagar: $e');
    }
  }

  Future<void> _testNow(Routine r) async {
    final results = await ActionExecutor.runAll(r.actions);
    final okCount = results.where((x) => x.ok).length;
    _snack('Teste: $okCount/${results.length} ok');
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ROTINAS'),
        actions: [
          IconButton(
            tooltip: 'Recarregar',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: IronTheme.cyan,
        foregroundColor: Colors.black,
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('NOVA'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: IronTheme.cyan))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            color: IronTheme.danger, size: 32),
                        const SizedBox(height: 8),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: IronTheme.fgDim)),
                        const SizedBox(height: 12),
                        ElevatedButton(
                            onPressed: _load,
                            child: const Text('Tentar de novo')),
                      ],
                    ),
                  ),
                )
              : _routines.isEmpty
                  ? const _EmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _routines.length,
                      itemBuilder: (_, i) {
                        final r = _routines[i];
                        return _RoutineCard(
                          routine: r,
                          onTap: () => _edit(r),
                          onToggle: () => _toggle(r),
                          onDelete: () => _delete(r),
                          onTest: () => _testNow(r),
                        );
                      },
                    ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome,
                size: 48, color: IronTheme.magenta),
            const SizedBox(height: 12),
            const Text('Sem rotinas ainda',
                style: TextStyle(
                    color: IronTheme.cyan,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text(
              'Crie a primeira: "quando eu disser modo trabalho, '
              'silenciar notificações e abrir Trello".',
              textAlign: TextAlign.center,
              style: TextStyle(color: IronTheme.fgDim),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoutineCard extends StatelessWidget {
  final Routine routine;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onTest;
  const _RoutineCard({
    required this.routine,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
    required this.onTest,
  });

  IconData _triggerIcon() {
    switch (routine.triggerType) {
      case 'voice':
        return Icons.mic;
      case 'time':
        return Icons.schedule;
      case 'geo':
        return Icons.place;
      case 'app_open':
        return Icons.apps;
      default:
        return Icons.bolt;
    }
  }

  String _triggerSummary() {
    final c = routine.triggerConfig;
    switch (routine.triggerType) {
      case 'voice':
        final phrase = c['voice_phrase']?.toString() ?? '';
        return phrase.isEmpty ? 'sem frase' : '"$phrase"';
      case 'time':
        return c['cron']?.toString() ?? '?';
      case 'geo':
        final edge = c['edge']?.toString() ?? 'enter';
        return 'geofence ${c['geofence_id']} ($edge)';
      case 'app_open':
        return c['package']?.toString() ?? '?';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Icon(_triggerIcon(),
                  color:
                      routine.enabled ? IronTheme.cyan : IronTheme.fgDim),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(routine.name,
                        style: TextStyle(
                            color: routine.enabled
                                ? IronTheme.fgBright
                                : IronTheme.fgDim,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      '${routine.triggerType} · ${_triggerSummary()} · ${routine.actions.length} ações',
                      style: const TextStyle(
                          color: IronTheme.fgDim, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Testar agora',
                icon: const Icon(Icons.play_circle_outline,
                    color: IronTheme.magenta),
                onPressed: onTest,
              ),
              Switch(
                value: routine.enabled,
                activeColor: IronTheme.cyan,
                onChanged: (_) => onToggle(),
              ),
              IconButton(
                tooltip: 'Apagar',
                icon: const Icon(Icons.delete_outline,
                    color: IronTheme.danger),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
