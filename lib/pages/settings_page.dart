import 'package:flutter/material.dart';

import '../models/persona.dart';
import '../services/persona_store.dart';
import '../theme.dart';
import 'onboarding_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _store = PersonaStore();
  List<Persona> _personas = [];
  String? _activeId;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final all = await _store.list();
    final active = await _store.active();
    setState(() {
      _personas = all;
      _activeId = active?.id;
    });
  }

  Future<void> _editTone(Persona p) async {
    String tone = p.tone;
    String backend = p.backend;
    String voice = p.voice;
    String voiceGender = p.voiceGender;
    const voiceLabels = {
      'pt-BR': 'Português (BR) 🇧🇷',
      'en-US': 'English (US) 🇺🇸',
      'it-IT': 'Italiano 🇮🇹',
    };
    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: IronTheme.bgPanel,
          title: Text('Editar ${p.displayName}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Idioma da voz',
                      style: TextStyle(color: IronTheme.fgDim)),
                ),
                ...['pt-BR', 'en-US', 'it-IT'].map((v) =>
                    RadioListTile<String>(
                      value: v,
                      groupValue: voice,
                      onChanged: (x) => setS(() => voice = x!),
                      title: Text(voiceLabels[v] ?? v),
                      activeColor: IronTheme.cyan,
                      dense: true,
                    )),
                const Divider(),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Gênero da voz',
                      style: TextStyle(color: IronTheme.fgDim)),
                ),
                ...['feminina', 'masculina'].map((g) =>
                    RadioListTile<String>(
                      value: g,
                      groupValue: voiceGender,
                      onChanged: (x) => setS(() => voiceGender = x!),
                      title: Text(g[0].toUpperCase() + g.substring(1)),
                      activeColor: IronTheme.cyan,
                      dense: true,
                    )),
                const Divider(),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Tom', style: TextStyle(color: IronTheme.fgDim)),
                ),
                ...['amigo', 'técnico', 'mestre', 'mentor'].map((t) =>
                    RadioListTile<String>(
                      value: t,
                      groupValue: tone,
                      onChanged: (v) => setS(() => tone = v!),
                      title: Text(t),
                      activeColor: IronTheme.cyan,
                      dense: true,
                    )),
                const Divider(),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Backend',
                      style: TextStyle(color: IronTheme.fgDim)),
                ),
                ...['salix', 'oss', 'auto'].map((b) =>
                    RadioListTile<String>(
                      value: b,
                      groupValue: backend,
                      onChanged: (v) => setS(() => backend = v!),
                      title: Text(b.toUpperCase()),
                      activeColor: IronTheme.cyan,
                      dense: true,
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: () async {
                await _store.update(p.copyWith(
                  tone: tone,
                  backend: backend,
                  voice: voice,
                  voiceGender: voiceGender,
                ));
                if (ctx.mounted) Navigator.pop(ctx);
                _refresh();
              },
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CONFIGURAÇÕES')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const Text('Usuários (multi-persona)',
              style: TextStyle(
                  color: IronTheme.cyan,
                  fontSize: 14,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          ..._personas.map((p) => Card(
                child: ListTile(
                  leading: Text(p.avatarEmoji,
                      style: const TextStyle(fontSize: 26)),
                  title: Text(p.displayName),
                  subtitle: Text(
                    'voz ${p.voice} (${p.voiceGender})  •  tom ${p.tone}  •  backend ${p.backend}',
                    style: const TextStyle(color: IronTheme.fgDim),
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      if (p.id == _activeId)
                        const Icon(Icons.check_circle,
                            color: IronTheme.ok)
                      else
                        IconButton(
                          icon: const Icon(Icons.radio_button_off),
                          onPressed: () async {
                            await _store.setActive(p.id);
                            _refresh();
                          },
                        ),
                      IconButton(
                        icon: const Icon(Icons.edit,
                            color: IronTheme.magenta),
                        onPressed: () => _editTone(p),
                      ),
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const OnboardingPage()));
            },
            icon: const Icon(Icons.person_add),
            label: const Text('NOVO USUÁRIO'),
          ),
          const SizedBox(height: 30),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('SALIX AI Personal'),
            subtitle: const Text(
                'v1.3.0  •  voz humana Edge TTS  •  PT-BR / EN / IT  •  cyberpunk neon',
                style: TextStyle(color: IronTheme.fgDim)),
          ),
        ],
      ),
    );
  }
}
