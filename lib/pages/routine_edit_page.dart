// SALIX onda 4 — editor de Rotina

import 'package:flutter/material.dart';

import '../services/routines_client.dart';
import '../theme.dart';

class RoutineEditPage extends StatefulWidget {
  final Routine initial;
  final bool isNew;
  const RoutineEditPage(
      {super.key, required this.initial, required this.isNew});
  @override
  State<RoutineEditPage> createState() => _RoutineEditPageState();
}

class _RoutineEditPageState extends State<RoutineEditPage> {
  final _client = RoutinesClient();
  late TextEditingController _name;
  late String _triggerType;
  late Map<String, dynamic> _triggerConfig;
  late List<Map<String, dynamic>> _actions;
  late bool _enabled;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial.name);
    _triggerType = widget.initial.triggerType;
    _triggerConfig = Map<String, dynamic>.from(widget.initial.triggerConfig);
    _actions = widget.initial.actions
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    _enabled = widget.initial.enabled;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('dê um nome');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = widget.initial.copyWith(
        name: _name.text.trim(),
        triggerType: _triggerType,
        triggerConfig: _triggerConfig,
        actions: _actions,
        enabled: _enabled,
      );
      final saved = widget.isNew
          ? await _client.createRoutine(r)
          : await _client.updateRoutine(r);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      _snack('erro: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  // -------------------------------------------------------------- Add action

  Future<void> _addAction() async {
    final tool = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: IronTheme.bgPanel,
        title: const Text('Escolha a ação'),
        children: const [
          _ToolOption(value: 'open_app', label: 'Abrir app'),
          _ToolOption(value: 'open_url', label: 'Abrir URL'),
          _ToolOption(value: 'set_volume', label: 'Ajustar volume'),
          _ToolOption(value: 'mute', label: 'Silenciar'),
          _ToolOption(value: 'set_brightness', label: 'Ajustar brilho'),
          _ToolOption(value: 'flashlight', label: 'Lanterna on/off'),
          _ToolOption(value: 'vibrate', label: 'Vibrar'),
          _ToolOption(
              value: 'open_bluetooth_settings', label: 'Settings Bluetooth'),
          _ToolOption(value: 'open_wifi_settings', label: 'Settings Wifi'),
          _ToolOption(value: 'open_sound_settings', label: 'Settings Som/DND'),
          _ToolOption(
              value: 'smart_home_webhook', label: 'Smart Home webhook'),
          _ToolOption(
              value: 'send_notification', label: 'Notificação push'),
        ],
      ),
    );
    if (tool == null) return;
    setState(() => _actions.add({'tool': tool, 'args': _defaultArgs(tool)}));
  }

  Map<String, dynamic> _defaultArgs(String tool) {
    switch (tool) {
      case 'open_app':
        return {
          'app': 'youtube',
          'action': 'search',
          'data': {'query': ''}
        };
      case 'open_url':
        return {'url': 'https://'};
      case 'set_volume':
        return {'level': 0.5, 'category': 'media'};
      case 'mute':
        return {'category': 'media'};
      case 'set_brightness':
        return {'level': 0.5};
      case 'flashlight':
        return {'on': true};
      case 'vibrate':
        return {'ms': 300};
      case 'smart_home_webhook':
        return {'webhook_url': '', 'command': ''};
      case 'send_notification':
        return {'title': '', 'body': ''};
      default:
        return {};
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'NOVA ROTINA' : 'EDITAR ROTINA'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: IronTheme.cyan)),
            )
          else
            IconButton(
              onPressed: _save,
              icon: const Icon(Icons.save, color: IronTheme.cyan),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nome da rotina'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Ativa', style: TextStyle(color: IronTheme.fgDim)),
              const SizedBox(width: 8),
              Switch(
                value: _enabled,
                activeColor: IronTheme.cyan,
                onChanged: (v) => setState(() => _enabled = v),
              ),
            ],
          ),
          const Divider(),
          const Text('GATILHO',
              style: TextStyle(
                  color: IronTheme.cyan,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          DropdownButton<String>(
            value: _triggerType,
            isExpanded: true,
            dropdownColor: IronTheme.bgPanel,
            items: const [
              DropdownMenuItem(value: 'voice', child: Text('Frase de voz')),
              DropdownMenuItem(value: 'time', child: Text('Horário (cron)')),
              DropdownMenuItem(value: 'geo', child: Text('Geofence')),
              DropdownMenuItem(value: 'app_open', child: Text('App aberto')),
            ],
            onChanged: (v) => setState(() {
              _triggerType = v ?? 'voice';
              _triggerConfig = {};
            }),
          ),
          const SizedBox(height: 8),
          _TriggerEditor(
              type: _triggerType,
              config: _triggerConfig,
              onChange: (c) => setState(() => _triggerConfig = c)),
          const Divider(height: 32),
          Row(
            children: [
              const Text('AÇÕES',
                  style: TextStyle(
                      color: IronTheme.cyan,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w800)),
              const Spacer(),
              TextButton.icon(
                onPressed: _addAction,
                icon: const Icon(Icons.add, color: IronTheme.magenta),
                label: const Text('ADICIONAR'),
              ),
            ],
          ),
          if (_actions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Nenhuma ação ainda',
                  style: TextStyle(color: IronTheme.fgDim)),
            )
          else
            ...List.generate(_actions.length, (i) {
              return _ActionEditor(
                key: ValueKey(i),
                index: i,
                action: _actions[i],
                onChange: (a) => setState(() => _actions[i] = a),
                onDelete: () => setState(() => _actions.removeAt(i)),
                onUp: i == 0
                    ? null
                    : () => setState(() {
                          final t = _actions.removeAt(i);
                          _actions.insert(i - 1, t);
                        }),
                onDown: i == _actions.length - 1
                    ? null
                    : () => setState(() {
                          final t = _actions.removeAt(i);
                          _actions.insert(i + 1, t);
                        }),
              );
            }),
        ],
      ),
    );
  }
}

class _ToolOption extends StatelessWidget {
  final String value;
  final String label;
  const _ToolOption({required this.value, required this.label});
  @override
  Widget build(BuildContext context) {
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(context, value),
      child: Text(label),
    );
  }
}

class _TriggerEditor extends StatelessWidget {
  final String type;
  final Map<String, dynamic> config;
  final ValueChanged<Map<String, dynamic>> onChange;
  const _TriggerEditor({
    required this.type,
    required this.config,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    switch (type) {
      case 'voice':
        return TextFormField(
          initialValue: config['voice_phrase']?.toString() ?? '',
          decoration: const InputDecoration(
              labelText: 'Frase ("modo trabalho", "boa noite"...)'),
          onChanged: (v) => onChange({...config, 'voice_phrase': v}),
        );
      case 'time':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              initialValue: config['cron']?.toString() ?? '0 9 * * 1-5',
              decoration: const InputDecoration(
                  labelText: 'Cron (min hora dia mes diaSemana)'),
              onChanged: (v) => onChange({...config, 'cron': v}),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'ex: "0 9 * * 1-5" = seg-sex 9h  ·  "*/30 * * * *" = a cada 30min',
                style: TextStyle(color: IronTheme.fgDim, fontSize: 12),
              ),
            ),
          ],
        );
      case 'geo':
        return Column(
          children: [
            TextFormField(
              initialValue: config['geofence_id']?.toString() ?? '',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Geofence ID'),
              onChanged: (v) => onChange({
                ...config,
                'geofence_id': int.tryParse(v) ?? 0,
              }),
            ),
            const SizedBox(height: 6),
            DropdownButton<String>(
              value: config['edge']?.toString() ?? 'enter',
              isExpanded: true,
              dropdownColor: IronTheme.bgPanel,
              items: const [
                DropdownMenuItem(value: 'enter', child: Text('ao entrar')),
                DropdownMenuItem(value: 'exit', child: Text('ao sair')),
              ],
              onChanged: (v) =>
                  onChange({...config, 'edge': v ?? 'enter'}),
            ),
          ],
        );
      case 'app_open':
        return TextFormField(
          initialValue: config['package']?.toString() ?? '',
          decoration: const InputDecoration(
              labelText: 'Pacote Android (ex: com.spotify.music)'),
          onChanged: (v) => onChange({...config, 'package': v}),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class _ActionEditor extends StatelessWidget {
  final int index;
  final Map<String, dynamic> action;
  final ValueChanged<Map<String, dynamic>> onChange;
  final VoidCallback onDelete;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  const _ActionEditor({
    super.key,
    required this.index,
    required this.action,
    required this.onChange,
    required this.onDelete,
    required this.onUp,
    required this.onDown,
  });

  @override
  Widget build(BuildContext context) {
    final tool = action['tool']?.toString() ?? '';
    final args = (action['args'] is Map)
        ? Map<String, dynamic>.from(action['args'] as Map)
        : <String, dynamic>{};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: IronTheme.magenta.withOpacity(0.2),
                    border: Border.all(color: IronTheme.magenta),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('${index + 1} · $tool',
                      style: const TextStyle(
                          color: IronTheme.magenta,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
                const Spacer(),
                IconButton(
                    onPressed: onUp,
                    icon: const Icon(Icons.arrow_upward, size: 18)),
                IconButton(
                    onPressed: onDown,
                    icon: const Icon(Icons.arrow_downward, size: 18)),
                IconButton(
                    onPressed: onDelete,
                    icon: const Icon(Icons.close,
                        color: IronTheme.danger, size: 18)),
              ],
            ),
            const SizedBox(height: 4),
            ..._argsFields(tool, args),
          ],
        ),
      ),
    );
  }

  List<Widget> _argsFields(String tool, Map<String, dynamic> args) {
    Widget txt(String key, String label, {bool number = false}) {
      return TextFormField(
        initialValue: args[key]?.toString() ?? '',
        decoration: InputDecoration(labelText: label, isDense: true),
        keyboardType:
            number ? TextInputType.numberWithOptions(decimal: true) : null,
        onChanged: (v) {
          final newArgs = {...args};
          if (number) {
            newArgs[key] = double.tryParse(v) ?? 0;
          } else {
            newArgs[key] = v;
          }
          onChange({...action, 'args': newArgs});
        },
      );
    }

    switch (tool) {
      case 'open_app':
        final data = (args['data'] is Map)
            ? Map<String, dynamic>.from(args['data'] as Map)
            : <String, dynamic>{};
        return [
          DropdownButtonFormField<String>(
            value: args['app']?.toString() ?? 'youtube',
            decoration: const InputDecoration(
                labelText: 'App', isDense: true),
            dropdownColor: IronTheme.bgPanel,
            items: const [
              DropdownMenuItem(value: 'youtube', child: Text('YouTube')),
              DropdownMenuItem(value: 'spotify', child: Text('Spotify')),
              DropdownMenuItem(value: 'whatsapp', child: Text('WhatsApp')),
              DropdownMenuItem(value: 'maps', child: Text('Maps')),
              DropdownMenuItem(value: 'tel', child: Text('Telefone')),
              DropdownMenuItem(value: 'sms', child: Text('SMS')),
              DropdownMenuItem(value: 'email', child: Text('Email')),
              DropdownMenuItem(value: 'browser', child: Text('Browser')),
            ],
            onChanged: (v) => onChange(
                {...action, 'args': {...args, 'app': v ?? 'youtube'}}),
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: args['action']?.toString() ?? 'search',
            decoration: const InputDecoration(
                labelText: 'Ação (search/watch/send/call/...)',
                isDense: true),
            onChanged: (v) => onChange(
                {...action, 'args': {...args, 'action': v}}),
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: data['query']?.toString() ??
                data['phone']?.toString() ??
                data['number']?.toString() ??
                data['url']?.toString() ??
                data['video_id']?.toString() ??
                '',
            decoration: const InputDecoration(
                labelText:
                    'Dado principal (query / phone / number / url / video_id)',
                isDense: true),
            onChanged: (v) {
              final app = args['app']?.toString() ?? 'youtube';
              final newData = <String, dynamic>{};
              if (app == 'tel' || app == 'sms') {
                newData['number'] = v;
              } else if (app == 'whatsapp') {
                newData['phone'] = v;
              } else if (app == 'browser') {
                newData['url'] = v;
              } else {
                newData['query'] = v;
              }
              onChange({
                ...action,
                'args': {...args, 'data': newData}
              });
            },
          ),
        ];
      case 'open_url':
        return [txt('url', 'URL')];
      case 'set_volume':
        return [
          txt('level', 'Nível 0..1', number: true),
          DropdownButtonFormField<String>(
            value: args['category']?.toString() ?? 'media',
            decoration:
                const InputDecoration(labelText: 'Categoria', isDense: true),
            dropdownColor: IronTheme.bgPanel,
            items: const [
              DropdownMenuItem(value: 'media', child: Text('Mídia')),
              DropdownMenuItem(value: 'ringtone', child: Text('Toque')),
              DropdownMenuItem(
                  value: 'notification', child: Text('Notificação')),
              DropdownMenuItem(value: 'system', child: Text('Sistema')),
              DropdownMenuItem(value: 'voice', child: Text('Chamada')),
            ],
            onChanged: (v) => onChange(
                {...action, 'args': {...args, 'category': v ?? 'media'}}),
          ),
        ];
      case 'mute':
        return [
          DropdownButtonFormField<String>(
            value: args['category']?.toString() ?? 'media',
            decoration:
                const InputDecoration(labelText: 'Categoria', isDense: true),
            dropdownColor: IronTheme.bgPanel,
            items: const [
              DropdownMenuItem(value: 'media', child: Text('Mídia')),
              DropdownMenuItem(value: 'ringtone', child: Text('Toque')),
              DropdownMenuItem(
                  value: 'notification', child: Text('Notificação')),
            ],
            onChanged: (v) => onChange(
                {...action, 'args': {...args, 'category': v ?? 'media'}}),
          ),
        ];
      case 'set_brightness':
        return [txt('level', 'Brilho 0..1', number: true)];
      case 'flashlight':
        return [
          DropdownButtonFormField<String>(
            value: (args['on'] == true || args['on']?.toString() == 'true')
                ? 'on'
                : 'off',
            decoration:
                const InputDecoration(labelText: 'Lanterna', isDense: true),
            dropdownColor: IronTheme.bgPanel,
            items: const [
              DropdownMenuItem(value: 'on', child: Text('Ligar')),
              DropdownMenuItem(value: 'off', child: Text('Desligar')),
            ],
            onChanged: (v) => onChange(
                {...action, 'args': {...args, 'on': v == 'on'}}),
          ),
        ];
      case 'vibrate':
        return [txt('ms', 'Duração (ms)', number: true)];
      case 'smart_home_webhook':
        return [
          txt('webhook_url', 'Webhook URL'),
          txt('command', 'Comando'),
        ];
      case 'send_notification':
        return [
          txt('title', 'Título'),
          txt('body', 'Corpo'),
        ];
      default:
        return const [];
    }
  }
}
