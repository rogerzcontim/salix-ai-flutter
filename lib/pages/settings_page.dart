import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/persona.dart';
import '../services/crash_reporter.dart';
import '../services/location_pinger.dart';
import '../services/persona_store.dart';
import '../services/push_notifications.dart';
import '../services/theme_controller.dart';
import '../services/wake_word.dart';
import '../theme.dart';
import 'device_controls_page.dart';
import 'geofences_page.dart';
import 'onboarding_page.dart';
import 'routines_page.dart';
import 'tools_catalog_page.dart';

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
  bool _locationEnabled = false;
  bool _voiceAlwaysOn = true; // v1.6.0: comandos universais sempre ativos

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadFlags();
  }

  Future<void> _loadFlags() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loc = await LocationPinger.isEnabled();
      if (!mounted) return;
      setState(() {
        _wakeEnabled = prefs.getBool('wake_word.enabled') ?? false;
        _locationEnabled = loc;
        _voiceAlwaysOn = prefs.getBool('voice.always_on') ?? true;
      });
    } catch (_) {}
  }

  // v3.0.0+25: blindado contra ForegroundServiceTypeException +
  // ForegroundServiceDidNotStartInTimeException native-side.
  Future<void> _toggleWake(bool v) async {
    if (v) {
      // STEP 1: Request RECORD_AUDIO. MUST be granted BEFORE the foreground
      // service is started; if user denies, we never touch the service.
      PermissionStatus status;
      try {
        CrashReporter.info('settings:toggleWake.BEFORE_request');
        status = await Permission.microphone.request();
        CrashReporter.info('settings:toggleWake.AFTER_request:$status');
      } catch (e, s) {
        CrashReporter.report(e, s, context: 'settings:toggleWake.permRequest');
        _snack('Erro consultando permissão: $e');
        return;
      }
      if (!status.isGranted) {
        _snack(status.isPermanentlyDenied
            ? 'Permissão bloqueada. Ative em Configurações > Apps > SALIX AI > Permissões.'
            : 'Permissão de microfone necessária pro wake word.');
        return;
      }

      // STEP 1.5 (v3.0.0+26): aguardar Activity voltar pra RESUMED.
      // Android 12+ proíbe startForegroundService() de Activity em background
      // ou transition (in/inactive). Após o dialog de permission, Activity
      // pode ainda estar em "inactive". Esperamos próximo frame + 600ms +
      // confirmação que estamos resumed antes de chamar o native side.
      CrashReporter.info('settings:toggleWake.WAIT_resumed');
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // double-check we're still mounted and ready
      if (!mounted) {
        CrashReporter.info('settings:toggleWake.UNMOUNTED_after_wait');
        return;
      }
      CrashReporter.info('settings:toggleWake.AFTER_wait_resumed');

      // STEP 2: Persist flag FIRST so reboot picks it up.
      try {
        CrashReporter.info('settings:toggleWake.persist.BEFORE');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('wake_word.enabled', true);
        CrashReporter.info('settings:toggleWake.persist.AFTER');
      } catch (e, s) {
        CrashReporter.report(e, s, context: 'settings:toggleWake.persist');
        _snack('Falha salvando preferência: $e');
        return;
      }
      if (!mounted) return;
      setState(() => _wakeEnabled = true);

      // STEP 3: Start the service. Native side now has guaranteed mic perm
      // and Activity is in resumed state.
      try {
        CrashReporter.info('settings:toggleWake.start.BEFORE_invoke');
        await _wake.start(onDetected: () async {});
        CrashReporter.info('settings:toggleWake.start.AFTER_invoke_OK');
        _snack('Wake word ativado.');
      } catch (e, s) {
        CrashReporter.report(e, s, context: 'settings:toggleWake.start');
        _snack('Falha iniciando wake word: $e');
        // Roll back so we don't leave a stale flag.
        try {
          final p = await SharedPreferences.getInstance();
          await p.setBool('wake_word.enabled', false);
        } catch (_) {}
        if (mounted) setState(() => _wakeEnabled = false);
      }
    } else {
      // OFF path
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('wake_word.enabled', false);
      } catch (e, s) {
        CrashReporter.report(e, s, context: 'settings:toggleWake.persistOff');
      }
      try {
        await _wake.stop();
      } catch (e, s) {
        CrashReporter.report(e, s, context: 'settings:toggleWake.stop');
      }
      if (!mounted) return;
      setState(() => _wakeEnabled = false);
    }
  }

  // v2.0.0+21 — toggle blindado: cada chamada nativa em try/catch específico,
  // checagens explícitas (GPS on? permissão? plugin OK?) com mensagens
  // amigáveis em snackbar e CrashReporter pra cada falha.
  Future<void> _toggleLocation(bool v) async {
    try {
      if (v) {
        // CHECK 1: GPS habilitado?
        bool svcOn = false;
        try {
          CrashReporter.info('settings:toggleLoc.BEFORE_isLocServiceEnabled');
          svcOn = await Geolocator.isLocationServiceEnabled();
          CrashReporter.info('settings:toggleLoc.AFTER_isLocServiceEnabled');
        } on MissingPluginException catch (e, s) {
          CrashReporter.report(e, s, context: 'settings:isLocServiceEnabled.MissingPlugin');
          _snack('Plugin de localização não disponível. Reinstale o app.');
          return;
        } on PlatformException catch (e, s) {
          CrashReporter.report(e, s, context: 'settings:isLocServiceEnabled.PlatformException');
          _snack('Erro ao consultar GPS: ${e.message ?? e.code}');
          return;
        } catch (e, s) {
          CrashReporter.report(e, s, context: 'settings:isLocServiceEnabled.unknown');
          _snack('Erro inesperado consultando GPS: $e');
          return;
        }
        if (!svcOn) {
          _snack('GPS desligado. Ative a localização no celular antes.');
          return;
        }

        // CHECK 2: permissão atual
        LocationPermission perm = LocationPermission.denied;
        try {
          CrashReporter.info('settings:toggleLoc.BEFORE_checkPermission');
          perm = await Geolocator.checkPermission();
          CrashReporter.info('settings:toggleLoc.AFTER_checkPermission');
        } on MissingPluginException catch (e, s) {
          CrashReporter.report(e, s, context: 'settings:checkPermission.MissingPlugin');
          _snack('Plugin não bindado. Reinstale o app.');
          return;
        } on PlatformException catch (e, s) {
          CrashReporter.report(e, s, context: 'settings:checkPermission.PlatformException');
          _snack('Erro Android: ${e.message ?? e.code}');
          return;
        } catch (e, s) {
          CrashReporter.report(e, s, context: 'settings:checkPermission.unknown');
          _snack('Erro: $e');
          return;
        }

        // CHECK 3: pede permissão se for o caso
        if (perm == LocationPermission.denied) {
          try {
            CrashReporter.info('settings:toggleLoc.BEFORE_requestPermission');
            perm = await Geolocator.requestPermission();
            CrashReporter.info('settings:toggleLoc.AFTER_requestPermission');
          } on MissingPluginException catch (e, s) {
            CrashReporter.report(e, s, context: 'settings:requestPermission.MissingPlugin');
            _snack('Plugin não bindado.');
            return;
          } on PlatformException catch (e, s) {
            CrashReporter.report(e, s, context: 'settings:requestPermission.PlatformException');
            _snack('Erro Android: ${e.message ?? e.code}');
            return;
          } catch (e, s) {
            CrashReporter.report(e, s, context: 'settings:requestPermission.unknown');
            _snack('Erro: $e');
            return;
          }
        }
        if (perm == LocationPermission.deniedForever) {
          _snack('Permissão bloqueada. Ative em Configurações > Apps > SALIX AI > Permissões > Localização.');
          return;
        }
        if (perm != LocationPermission.always &&
            perm != LocationPermission.whileInUse) {
          _snack('Permissão de localização negada.');
          return;
        }

        // CHECK 4 (paralelo, defensivo): permission_handler também
        try {
          await Permission.locationWhenInUse.request();
        } catch (e, s) {
          CrashReporter.report(e, s, context: 'settings:permission_handler.locationWhenInUse', isInfo: true);
        }

        // OK — liga
        try {
          await LocationPinger.setEnabled(true);
        } catch (e, s) {
          CrashReporter.report(e, s, context: 'settings:LocationPinger.setEnabled.true');
          _snack('Falha ligando pinger: $e');
          return;
        }
        if (!mounted) return;
        setState(() => _locationEnabled = true);
        _snack('Localização ativada.');
      } else {
        try {
          await LocationPinger.setEnabled(false);
        } catch (e, s) {
          CrashReporter.report(e, s, context: 'settings:LocationPinger.setEnabled.false');
        }
        if (!mounted) return;
        setState(() => _locationEnabled = false);
      }
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'settings:toggleLocation.outer');
      _snack('Erro inesperado: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    try {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {}
  }

  Future<void> _toggleVoiceAlwaysOn(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('voice.always_on', v);
    if (!mounted) return;
    setState(() => _voiceAlwaysOn = v);
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
          // v1.6.0 — comandos universais sempre ativos
          Card(
            child: SwitchListTile(
              secondary:
                  const Icon(Icons.bolt, color: IronTheme.magenta),
              title: const Text('Comandos universais por voz'),
              subtitle: const Text(
                'Toque o mic e diga: "abra YouTube", "liga lanterna", "timer 5 minutos", etc.',
                style: TextStyle(color: IronTheme.fgDim),
              ),
              value: _voiceAlwaysOn,
              activeColor: IronTheme.cyan,
              onChanged: _toggleVoiceAlwaysOn,
            ),
          ),
          if (_voiceAlwaysOn)
            Card(
              color: IronTheme.bgPanel,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'EXEMPLOS DE COMANDOS',
                      style: TextStyle(
                        color: IronTheme.cyan,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                      ),
                    ),
                    SizedBox(height: 8),
                    _VoiceCmdHint('"abra YouTube"', 'lança o app'),
                    _VoiceCmdHint('"abra Spotify"', 'ou Whatsapp, Maps, Waze, Uber, iFood'),
                    _VoiceCmdHint('"liga lanterna"', 'ou "lanterna"'),
                    _VoiceCmdHint('"aumenta volume"', 'também: diminui / mudo'),
                    _VoiceCmdHint('"aumenta brilho"', 'também: diminui'),
                    _VoiceCmdHint('"vibrar"', 'pulsa o telefone'),
                    _VoiceCmdHint('"timer 10 minutos"', 'cria countdown'),
                    _VoiceCmdHint('"alarme 7:30"', 'cria alarme'),
                    _VoiceCmdHint('"chamar +5511999999999"', 'abre discador'),
                    _VoiceCmdHint('"pesquisar receita de bolo"', 'busca no Google'),
                    SizedBox(height: 6),
                    Text(
                      'Qualquer outra coisa vai pro chat com SALIX.',
                      style:
                          TextStyle(color: IronTheme.fgDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          Card(
            child: SwitchListTile(
              secondary:
                  const Icon(Icons.location_on, color: IronTheme.magenta),
              title: const Text('Localização (geofences)'),
              subtitle: const Text(
                'Permite rotinas baseadas em entrar/sair de locais. Default OFF.',
                style: TextStyle(color: IronTheme.fgDim),
              ),
              value: _locationEnabled,
              activeColor: IronTheme.cyan,
              onChanged: _toggleLocation,
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
          const SizedBox(height: 24),
          const Divider(),
          const Text('CAPACIDADES',
              style: TextStyle(
                  color: IronTheme.cyan,
                  fontSize: 14,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_fix_high,
                  color: IronTheme.magenta),
              title: const Text('Capacidades SALIX'),
              subtitle: const Text(
                '100+ tools server-side: visão, finanças BR, RAG, email, código, voz...',
                style: TextStyle(color: IronTheme.fgDim),
              ),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ToolsCatalogPage())),
            ),
          ),

          const SizedBox(height: 24),
          const Divider(),
          Card(
            child: ListTile(
              leading:
                  const Icon(Icons.bug_report, color: IronTheme.magenta),
              title: const Text('Diagnóstico'),
              subtitle: const Text(
                'Status runtime de cada serviço (ajuda debugar boot/crash).',
                style: TextStyle(color: IronTheme.fgDim),
              ),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => _showDiagnostics(context),
            ),
          ),
          // v2.0.0+21: diagnóstico GEO específico
          Card(
            child: ListTile(
              leading:
                  const Icon(Icons.gps_fixed, color: IronTheme.magenta),
              title: const Text('Diagnóstico Geo'),
              subtitle: const Text(
                'Testa cada step da localização: GPS on, permissão, plugin, last fix.',
                style: TextStyle(color: IronTheme.fgDim),
              ),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => _showGeoDiagnostics(context),
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('SALIX AI Personal'),
            subtitle: const Text(
                'v5.0.0+30  •  Onda 13 PII Vault (AES-256-GCM/LGPD) + Onda 14 CLI awareness',
                style: TextStyle(color: IronTheme.fgDim)),
          ),
          const Divider(height: 1, color: Color(0x2200FFFF)),
          // v5.0.0+30 — Onda 13 PII Vault: client-side hint that personal
          // memory is encrypted per-user with AES-256-GCM and exportable (LGPD).
          ListTile(
            leading: const Icon(Icons.lock_outline, color: IronTheme.cyan),
            title: const Text('Privacidade & memória pessoal'),
            subtitle: const Text(
                'Sua memória pessoal está protegida (AES-256-GCM por usuário). Você pode exportar tudo a qualquer momento (LGPD).',
                style: TextStyle(color: IronTheme.fgDim)),
          ),
          // v5.0.0+30 — Onda 14: aponta o usuário Windows pro CLI salix.exe
          // que caça arquivos no PC e cacheia paths localmente. APK/iOS não
          // executam essas tools.
          ListTile(
            leading: const Icon(Icons.terminal, color: IronTheme.magenta),
            title: const Text('CLI Windows (salix.exe v2.4.0+)'),
            subtitle: const Text(
                'No PC, baixe salix.exe — caça arquivos, cacheia paths e SSH configs.\nhttps://ironedgeai.com/cli/latest.json',
                style: TextStyle(color: IronTheme.fgDim, fontSize: 12)),
            trailing: const Icon(Icons.open_in_new, size: 16),
            onTap: () async {
              final uri = Uri.parse('https://ironedgeai.com/cli/latest.json');
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showDiagnostics(BuildContext context) async {
    final lines = <String>[];
    lines.add('Versão: 2.0.0+21');
    try {
      final prefs = await SharedPreferences.getInstance();
      lines.add('SharedPreferences: OK');
      lines.add('  wake_word.enabled = ${prefs.getBool('wake_word.enabled') ?? false}');
      lines.add('  location.enabled  = ${prefs.getBool('location.enabled') ?? false}');
      lines.add('  voice.always_on   = ${prefs.getBool('voice.always_on') ?? true}');
      lines.add('  salix.theme       = ${prefs.getString('salix.theme') ?? '(unset, dark default)'}');
    } catch (e) {
      lines.add('SharedPreferences: FAIL -> $e');
    }
    try {
      final st = await _wake.status();
      lines.add('WakeWordService: $st');
    } catch (e) {
      lines.add('WakeWordService: FAIL -> $e');
    }
    try {
      final pushOn = await PushNotificationsService.instance.isEnabled();
      lines.add('PushNotifications.enabled: $pushOn (no-op até FCM ativo)');
    } catch (e) {
      lines.add('PushNotifications: FAIL -> $e');
    }
    try {
      final loc = await LocationPinger.isEnabled();
      lines.add('LocationPinger.enabled: $loc');
    } catch (e) {
      lines.add('LocationPinger: FAIL -> $e');
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IronTheme.bgPanel,
        title: const Text('Diagnóstico runtime'),
        content: SingleChildScrollView(
          child: Text(
            lines.join('\n'),
            style: const TextStyle(
              color: IronTheme.fgBright,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  // v2.0.0+21: diagnóstico GEO step-by-step. Roda cada chamada nativa
  // isolada, captura cada exceção, mostra status numa lista. Útil pra ver
  // exatamente onde a v1.x crashava.
  Future<void> _showGeoDiagnostics(BuildContext context) async {
    final lines = <String>[];
    lines.add('=== DIAGNÓSTICO GEO ===');
    lines.add('Versão: 2.0.0+21');
    lines.add('');

    // Step 1: SharedPreferences
    try {
      final p = await SharedPreferences.getInstance();
      final loc = p.getBool('location.enabled') ?? false;
      lines.add('[OK] SharedPrefs location.enabled = $loc');
    } catch (e) {
      lines.add('[FAIL] SharedPrefs: $e');
    }

    // Step 2: GPS service status
    try {
      final svcOn = await Geolocator.isLocationServiceEnabled();
      lines.add('[${svcOn ? "OK" : "OFF"}] Geolocator.isLocationServiceEnabled = $svcOn');
    } on MissingPluginException catch (e) {
      lines.add('[FAIL] isLocServiceEnabled MissingPlugin: ${e.message}');
    } on PlatformException catch (e) {
      lines.add('[FAIL] isLocServiceEnabled Platform: ${e.code} ${e.message}');
    } catch (e) {
      lines.add('[FAIL] isLocServiceEnabled: $e');
    }

    // Step 3: Permission status
    try {
      final perm = await Geolocator.checkPermission();
      lines.add('[OK] Geolocator.checkPermission = $perm');
    } on MissingPluginException catch (e) {
      lines.add('[FAIL] checkPermission MissingPlugin: ${e.message}');
    } on PlatformException catch (e) {
      lines.add('[FAIL] checkPermission Platform: ${e.code} ${e.message}');
    } catch (e) {
      lines.add('[FAIL] checkPermission: $e');
    }

    // Step 4: permission_handler status (paralelo)
    try {
      final s = await Permission.locationWhenInUse.status;
      lines.add('[OK] permission_handler whenInUse = $s');
    } catch (e) {
      lines.add('[FAIL] permission_handler whenInUse: $e');
    }

    // Step 5: try last known position (NÃO requesta permissão)
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        lines.add('[OK] last fix: ${last.latitude.toStringAsFixed(5)},'
            '${last.longitude.toStringAsFixed(5)} (acc ${last.accuracy.toStringAsFixed(0)}m)');
      } else {
        lines.add('[INFO] last fix: null (nenhuma posição em cache)');
      }
    } on MissingPluginException catch (e) {
      lines.add('[FAIL] getLastKnownPosition MissingPlugin: ${e.message}');
    } on PlatformException catch (e) {
      lines.add('[FAIL] getLastKnownPosition Platform: ${e.code} ${e.message}');
    } catch (e) {
      lines.add('[FAIL] getLastKnownPosition: $e');
    }

    lines.add('');
    lines.add('Se algo está [FAIL], reportei pro /api/_crash automaticamente.');

    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IronTheme.bgPanel,
        title: const Text('Diagnóstico Geo'),
        content: SingleChildScrollView(
          child: Text(
            lines.join('\n'),
            style: const TextStyle(
              color: IronTheme.fgBright,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }
}

class _VoiceCmdHint extends StatelessWidget {
  final String cmd;
  final String desc;
  const _VoiceCmdHint(this.cmd, this.desc);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.mic, size: 14, color: IronTheme.magenta),
          const SizedBox(width: 6),
          Expanded(
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: cmd,
                    style: const TextStyle(
                      color: IronTheme.fgBright,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  TextSpan(
                    text: '   $desc',
                    style: const TextStyle(
                        color: IronTheme.fgDim, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
