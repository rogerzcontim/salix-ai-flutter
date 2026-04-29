import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/persona.dart';
import '../services/persona_store.dart';
import '../services/push_notifications.dart';
import '../services/theme_controller.dart';
import '../services/wake_word.dart';
import '../theme.dart';
import 'device_controls_page.dart';
import 'geofences_page.dart';
import 'onboarding_page.dart';
import 'routines_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _store = PersonaStore();
  final _wake = WakeWordService();
  List<Persona> _personas = [];
  String? _activeId;
  bool _wakeEnabled = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadWakeEnabled();
  }

  Future<void> _loadWakeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _wakeEnabled = prefs.getBool('wake_word.enabled') ?? false;
    });
  }

  Future<void> _toggleWake(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wake_word.enabled', v);
    setState(() => _wakeEnabled = v);
    if (v) {
      await _wake.start(onDetected: () async {});
    } else {
      await _wake.stop();
    }
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
          const SizedBox(height: 24),
          const Divider(),
          const Text('AUTOMAÇÃO',
              style: TextStyle(
                  color: IronTheme.cyan,
                  fontSize: 14,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_awesome,
                  color: IronTheme.magenta),
              title: const Text('Rotinas'),
              subtitle: const Text(
                'Frase de voz, horário, geofence ou app open → ações',
                style: TextStyle(color: IronTheme.fgDim),
              ),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const RoutinesPage())),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.place, color: IronTheme.magenta),
              title: const Text('Geofences'),
              subtitle: const Text(
                'Locais que disparam rotinas ao entrar/sair',
                style: TextStyle(color: IronTheme.fgDim),
              ),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const GeofencesPage())),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.tune, color: IronTheme.magenta),
              title: const Text('Controles do device'),
              subtitle: const Text(
                'Volume, brilho, lanterna, vibração, BT/Wifi',
                style: TextStyle(color: IronTheme.fgDim),
              ),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const DeviceControlsPage())),
            ),
          ),
          // Onda 3 — wake word "Oi SALIX"
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.mic_none, color: IronTheme.magenta),
              title: const Text('Wake word "Oi SALIX"'),
              subtitle: Text(
                _wake.supported
                    ? 'Escuta sempre ativa em background. Pausa <15% bateria.'
                    : 'Indisponível no iOS — use Siri Shortcut.',
                style: const TextStyle(color: IronTheme.fgDim),
              ),
              value: _wakeEnabled && _wake.supported,
              activeColor: IronTheme.cyan,
              onChanged: _wake.supported ? _toggleWake : null,
            ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const Text('APARÊNCIA',
              style: TextStyle(
                  color: IronTheme.cyan,
                  fontSize: 14,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.light_mode, color: IronTheme.magenta),
              title: const Text('Tema claro'),
              subtitle: const Text(
                'Alterna entre dark (default) e light. Persiste entre sessões.',
                style: TextStyle(color: IronTheme.fgDim),
              ),
              value: ref.watch(themeModeProvider) == ThemeMode.light,
              activeColor: IronTheme.cyan,
              onChanged: (v) async {
                await ref
                    .read(themeModeProvider.notifier)
                    .set(v ? ThemeMode.light : ThemeMode.dark);
              },
            ),
          ),

          const SizedBox(height: 24),
          const Divider(),
          const Text('NOTIFICAÇÕES',
              style: TextStyle(
                  color: IronTheme.cyan,
                  fontSize: 14,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          FutureBuilder<bool>(
            future: PushNotificationsService.instance.isEnabled(),
            builder: (ctx, snap) {
              final enabled = snap.data ?? true;
              return Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.notifications_active,
                      color: IronTheme.magenta),
                  title: const Text('Push notifications'),
                  subtitle: const Text(
                    'Receba avisos quando uma tarefa longa terminar (FCM).',
                    style: TextStyle(color: IronTheme.fgDim),
                  ),
                  value: enabled,
                  activeColor: IronTheme.cyan,
                  onChanged: (v) async {
                    await PushNotificationsService.instance.setEnabled(v);
                    setState(() {});
                  },
                ),
              );
            },
          ),

          const SizedBox(height: 30),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('SALIX AI Personal'),
            subtitle: const Text(
                'v1.4.0+15  •  Onda 8: saúde + casa + veículo + iOS + tema light + PWA + push',
                style: TextStyle(color: IronTheme.fgDim)),
          ),
        ],
      ),
    );
  }
}
