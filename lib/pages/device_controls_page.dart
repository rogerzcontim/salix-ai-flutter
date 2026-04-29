// SALIX onda 4 — UI manual dos controles nativos
//
// Tela de "playground": sliders de volume/brilho, toggles, botão lanterna,
// vibração com presets. Útil pro Roger validar que cada permissão funcionou
// no device antes de criar uma rotina.

import 'package:flutter/material.dart';

import '../services/device_control.dart';
import '../theme.dart';

class DeviceControlsPage extends StatefulWidget {
  const DeviceControlsPage({super.key});
  @override
  State<DeviceControlsPage> createState() => _DeviceControlsPageState();
}

class _DeviceControlsPageState extends State<DeviceControlsPage> {
  double _vol = 0.5;
  double _brightness = 0.5;
  bool _torch = false;
  String _last = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final v = await DeviceControl.getVolume();
    final b = await DeviceControl.getBrightness();
    setState(() {
      _vol = (v.value as num?)?.toDouble() ?? _vol;
      _brightness = (b.value as num?)?.toDouble() ?? _brightness;
    });
  }

  void _show(DeviceActionResult r) {
    setState(() => _last = r.message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(r.message),
        backgroundColor: r.ok ? IronTheme.bgElev : IronTheme.danger,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CONTROLES DO DEVICE')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('VOLUME (mídia)'),
          Slider(
            value: _vol,
            activeColor: IronTheme.cyan,
            onChanged: (v) => setState(() => _vol = v),
            onChangeEnd: (v) async {
              final r = await DeviceControl.setVolume(v);
              _show(r);
            },
          ),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                onPressed: () async => _show(await DeviceControl.mute()),
                child: const Text('Mute'),
              ),
              ElevatedButton(
                onPressed: () async =>
                    _show(await DeviceControl.setVolume(1.0)),
                child: const Text('Máx'),
              ),
              ElevatedButton(
                onPressed: () async => _show(
                    await DeviceControl.openSoundSettings()),
                child: const Text('Settings Som'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _section('BRILHO'),
          Slider(
            value: _brightness,
            activeColor: IronTheme.cyan,
            onChanged: (v) => setState(() => _brightness = v),
            onChangeEnd: (v) async {
              final r = await DeviceControl.setBrightness(v);
              _show(r);
            },
          ),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                onPressed: () async =>
                    _show(await DeviceControl.setBrightness(0.1)),
                child: const Text('Mín'),
              ),
              ElevatedButton(
                onPressed: () async =>
                    _show(await DeviceControl.setBrightness(1.0)),
                child: const Text('Máx'),
              ),
              ElevatedButton(
                onPressed: () async =>
                    _show(await DeviceControl.resetBrightness()),
                child: const Text('Auto'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _section('LANTERNA'),
          SwitchListTile(
            title: Text(_torch ? 'Ligada' : 'Desligada'),
            value: _torch,
            activeColor: IronTheme.cyan,
            onChanged: (v) async {
              final r = await DeviceControl.setFlashlight(v);
              if (r.ok) setState(() => _torch = v);
              _show(r);
            },
          ),
          const SizedBox(height: 20),
          _section('VIBRAÇÃO'),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                onPressed: () async =>
                    _show(await DeviceControl.vibrate(ms: 200)),
                child: const Text('Curta'),
              ),
              ElevatedButton(
                onPressed: () async =>
                    _show(await DeviceControl.vibrate(ms: 600)),
                child: const Text('Longa'),
              ),
              ElevatedButton(
                onPressed: () async => _show(await DeviceControl.vibratePattern(
                    [0, 100, 50, 100, 50, 100])),
                child: const Text('Padrão'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _section('CONECTIVIDADE'),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.bluetooth),
                onPressed: () async =>
                    _show(await DeviceControl.openBluetoothSettings()),
                label: const Text('Bluetooth'),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.wifi),
                onPressed: () async =>
                    _show(await DeviceControl.openWifiSettings()),
                label: const Text('Wifi'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_last.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('último: $_last',
                  style: const TextStyle(color: IronTheme.fgDim)),
            ),
          const Divider(),
          const Text(
            'iOS: brilho funciona; volume é read-only; Bluetooth/Wifi/lanterna '
            'limitados pela plataforma.',
            style: TextStyle(color: IronTheme.fgDim, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _section(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 4, top: 4),
        child: Text(s,
            style: const TextStyle(
                color: IronTheme.cyan,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w800)),
      );
}
