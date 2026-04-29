// SALIX AI — long-term memory management page (Wave 1 / C5)
//
// Lists facts SALIX has stored about the user across conversations. Lets the
// user edit (tap a card) or delete (swipe / trash icon) anything they don't
// want remembered. This is privacy-first: the user owns their memory.
//
// Data is fetched from a hosted endpoint (https://salix-ai.com/api/memories)
// when the user is signed in to the web companion. On the bare APK (anonymous,
// no account), the page falls back to a local SharedPreferences-backed list so
// at least manual notes can be stored.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

class MemoriesPage extends StatefulWidget {
  const MemoriesPage({super.key});

  @override
  State<MemoriesPage> createState() => _MemoriesPageState();
}

class _MemoriesPageState extends State<MemoriesPage> {
  static const _localKey = 'memories.local.v1';

  bool _loading = true;
  List<_Memory> _items = [];
  bool _useRemote = false; // best-effort; falls back to local

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    // Try remote first (will return 401 if user has no salix-ai.com session).
    try {
      final r = await http.get(
        Uri.parse('https://salix-ai.com/api/memories'),
        headers: {'Accept': 'application/json'},
      );
      if (r.statusCode == 200) {
        final list = jsonDecode(r.body) as List<dynamic>;
        _items = list
            .whereType<Map<String, dynamic>>()
            .map(_Memory.fromRemote)
            .toList();
        _useRemote = true;
        setState(() => _loading = false);
        return;
      }
    } catch (_) {/* fallthrough to local */}

    _useRemote = false;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _items = list
            .whereType<Map<String, dynamic>>()
            .map(_Memory.fromLocal)
            .toList();
      } catch (_) {
        _items = [];
      }
    } else {
      _items = [];
    }
    setState(() => _loading = false);
  }

  Future<void> _saveLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localKey,
        jsonEncode(_items.map((e) => e.toLocal()).toList(growable: false)));
  }

  Future<void> _add() async {
    final res = await showDialog<_MemoryDraft>(
      context: context,
      builder: (_) => const _EditDialog(),
    );
    if (res == null) return;
    if (_useRemote) {
      try {
        final r = await http.post(
          Uri.parse('https://salix-ai.com/api/memories'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'fact': res.fact, 'category': res.category}),
        );
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          setState(() => _items.insert(
              0,
              _Memory(
                id: j['id'] as int? ?? 0,
                fact: res.fact,
                category: res.category,
                createdAt: DateTime.now(),
              )));
          return;
        }
      } catch (_) {/* fallthrough */}
    }
    setState(() => _items.insert(
        0,
        _Memory(
          id: DateTime.now().microsecondsSinceEpoch,
          fact: res.fact,
          category: res.category,
          createdAt: DateTime.now(),
        )));
    await _saveLocal();
  }

  Future<void> _edit(_Memory m) async {
    final res = await showDialog<_MemoryDraft>(
      context: context,
      builder: (_) => _EditDialog(initial: m),
    );
    if (res == null) return;
    if (_useRemote) {
      try {
        await http.patch(
          Uri.parse('https://salix-ai.com/api/memories/${m.id}'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'fact': res.fact, 'category': res.category}),
        );
      } catch (_) {}
    }
    setState(() {
      final idx = _items.indexWhere((e) => e.id == m.id);
      if (idx >= 0) {
        _items[idx] = _Memory(
            id: m.id,
            fact: res.fact,
            category: res.category,
            createdAt: m.createdAt);
      }
    });
    if (!_useRemote) await _saveLocal();
  }

  Future<void> _delete(_Memory m) async {
    if (_useRemote) {
      try {
        await http.delete(Uri.parse('https://salix-ai.com/api/memories/${m.id}'));
      } catch (_) {}
    }
    setState(() => _items.removeWhere((e) => e.id == m.id));
    if (!_useRemote) await _saveLocal();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minhas memórias'),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        backgroundColor: IronTheme.cyan,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('Adicionar'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: IronTheme.cyan))
          : _items.isEmpty
              ? _EmptyState(useRemote: _useRemote)
              : Column(
                  children: [
                    if (!_useRemote)
                      Container(
                        width: double.infinity,
                        color: IronTheme.bgPanel,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: const Text(
                          'Modo local (sem conta salix-ai.com). Memórias ficam só neste celular.',
                          style:
                              TextStyle(color: IronTheme.fgDim, fontSize: 12),
                        ),
                      ),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemCount: _items.length,
                        itemBuilder: (_, i) {
                          final m = _items[i];
                          return Dismissible(
                            key: ValueKey('mem-${m.id}'),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              color: IronTheme.danger.withOpacity(0.6),
                              child: const Icon(Icons.delete, color: Colors.white),
                            ),
                            onDismissed: (_) => _delete(m),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => _edit(m),
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: IronTheme.bgElev,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: IronTheme.cyan.withOpacity(0.3)),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: _categoryColor(m.category)
                                            .withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        m.category,
                                        style: TextStyle(
                                          color: _categoryColor(m.category),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        m.fact,
                                        style: const TextStyle(
                                            color: IronTheme.fgBright,
                                            fontSize: 14),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Excluir',
                                      icon: const Icon(Icons.delete_outline,
                                          size: 18),
                                      onPressed: () => _delete(m),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }

  Color _categoryColor(String cat) {
    switch (cat) {
      case 'profile':
        return IronTheme.cyan;
      case 'preference':
        return IronTheme.magenta;
      case 'goal':
        return Colors.amber;
      case 'trade':
        return Colors.greenAccent;
      case 'code':
        return Colors.orangeAccent;
      default:
        return IronTheme.fgDim;
    }
  }
}

class _EmptyState extends StatelessWidget {
  final bool useRemote;
  const _EmptyState({required this.useRemote});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.psychology_outlined,
                size: 64, color: IronTheme.cyan),
            const SizedBox(height: 16),
            const Text('Nenhuma memória ainda',
                style: TextStyle(
                    color: IronTheme.fgBright,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              useRemote
                  ? 'Conforme você conversa, SALIX vai gravar fatos importantes sobre você aqui. Você pode editar ou apagar qualquer um.'
                  : 'Adicione fatos manualmente sobre você (profissão, preferências, objetivos). SALIX vai usar pra te tratar melhor.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: IronTheme.fgDim, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _Memory {
  final int id;
  final String fact;
  final String category;
  final DateTime createdAt;
  _Memory({
    required this.id,
    required this.fact,
    required this.category,
    required this.createdAt,
  });

  factory _Memory.fromRemote(Map<String, dynamic> j) => _Memory(
        id: (j['id'] as num?)?.toInt() ?? 0,
        fact: j['fact']?.toString() ?? '',
        category: j['category']?.toString() ?? 'general',
        createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '') ??
            DateTime.now(),
      );

  factory _Memory.fromLocal(Map<String, dynamic> j) => _Memory(
        id: (j['id'] as num?)?.toInt() ?? 0,
        fact: j['fact']?.toString() ?? '',
        category: j['category']?.toString() ?? 'general',
        createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '') ??
            DateTime.now(),
      );

  Map<String, dynamic> toLocal() => {
        'id': id,
        'fact': fact,
        'category': category,
        'created_at': createdAt.toIso8601String(),
      };
}

class _MemoryDraft {
  final String fact;
  final String category;
  _MemoryDraft({required this.fact, required this.category});
}

class _EditDialog extends StatefulWidget {
  final _Memory? initial;
  const _EditDialog({this.initial});
  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final TextEditingController _factCtl;
  String _cat = 'general';

  @override
  void initState() {
    super.initState();
    _factCtl = TextEditingController(text: widget.initial?.fact ?? '');
    _cat = widget.initial?.category ?? 'general';
  }

  @override
  void dispose() {
    _factCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: IronTheme.bgPanel,
      title: Text(widget.initial == null ? 'Nova memória' : 'Editar memória'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _factCtl,
              minLines: 2,
              maxLines: 4,
              maxLength: 240,
              decoration: const InputDecoration(
                labelText: 'Fato',
                hintText: 'ex: trabalha com Go, prefere respostas curtas',
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _cat,
              decoration: const InputDecoration(labelText: 'Categoria'),
              items: const [
                DropdownMenuItem(value: 'general', child: Text('Geral')),
                DropdownMenuItem(value: 'profile', child: Text('Perfil')),
                DropdownMenuItem(value: 'preference', child: Text('Preferência')),
                DropdownMenuItem(value: 'goal', child: Text('Objetivo')),
                DropdownMenuItem(value: 'trade', child: Text('Trading')),
                DropdownMenuItem(value: 'code', child: Text('Código')),
              ],
              onChanged: (v) => setState(() => _cat = v ?? 'general'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final fact = _factCtl.text.trim();
            if (fact.length < 4) return;
            Navigator.of(context).pop(_MemoryDraft(fact: fact, category: _cat));
          },
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}
