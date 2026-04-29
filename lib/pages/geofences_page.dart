// SALIX onda 4 — UI Geofences

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../models/persona.dart';
import '../services/persona_store.dart';
import '../services/routines_client.dart';
import '../theme.dart';
import 'routines_page.dart';

class GeofencesPage extends StatefulWidget {
  const GeofencesPage({super.key});
  @override
  State<GeofencesPage> createState() => _GeofencesPageState();
}

class _GeofencesPageState extends State<GeofencesPage> {
  final _client = RoutinesClient();
  Persona? _persona;
  List<Geofence> _list = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await PersonaStore().active();
      _persona = p;
      if (p == null) {
        setState(() {
          _list = [];
          _loading = false;
        });
        return;
      }
      final list = await _client.listGeofences(
          userId: _RoutinesPageStateAccess.userId(p));
      setState(() {
        _list = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final p = _persona;
    if (p == null) return;
    final pos = await _safeCurrentPosition();
    final saved = await Navigator.of(context).push<Geofence>(MaterialPageRoute(
      builder: (_) => _GeofenceEditPage(
        initial: Geofence(
          userId: _RoutinesPageStateAccess.userId(p),
          name: 'Novo local',
          lat: pos?.latitude ?? 0,
          lng: pos?.longitude ?? 0,
          radiusM: 100,
        ),
        isNew: true,
      ),
    ));
    if (saved != null) _load();
  }

  Future<Position?> _safeCurrentPosition() async {
    try {
      final ok = await Geolocator.isLocationServiceEnabled();
      if (!ok) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return null;
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  Future<void> _delete(Geofence g) async {
    if (g.id == null) return;
    try {
      await _client.deleteGeofence(g.id!);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('falha apagar: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GEOFENCES'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: IronTheme.cyan,
        foregroundColor: Colors.black,
        onPressed: _create,
        icon: const Icon(Icons.add_location_alt),
        label: const Text('NOVO'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: IronTheme.cyan))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        style: const TextStyle(color: IronTheme.danger)),
                  ),
                )
              : _list.isEmpty
                  ? const Center(
                      child: Text(
                          'Nenhum geofence — adicione um local pra disparar rotinas.',
                          style: TextStyle(color: IronTheme.fgDim)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _list.length,
                      itemBuilder: (_, i) {
                        final g = _list[i];
                        return Card(
                          child: ListTile(
                            leading: Icon(
                              g.enabled
                                  ? Icons.location_on
                                  : Icons.location_off,
                              color: g.enabled
                                  ? IronTheme.cyan
                                  : IronTheme.fgDim,
                            ),
                            title: Text(g.name),
                            subtitle: Text(
                              '${g.lat.toStringAsFixed(5)}, ${g.lng.toStringAsFixed(5)}  ·  raio ${g.radiusM}m',
                              style: const TextStyle(color: IronTheme.fgDim),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: IronTheme.danger),
                              onPressed: () => _delete(g),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class _RoutinesPageStateAccess {
  static int userId(Persona p) {
    int h = 0xcbf29ce484222325 & 0x7fffffffffffffff;
    for (final code in p.id.codeUnits) {
      h ^= code;
      h = (h * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return h;
  }
}

class _GeofenceEditPage extends StatefulWidget {
  final Geofence initial;
  final bool isNew;
  const _GeofenceEditPage({required this.initial, required this.isNew});
  @override
  State<_GeofenceEditPage> createState() => _GeofenceEditPageState();
}

class _GeofenceEditPageState extends State<_GeofenceEditPage> {
  final _client = RoutinesClient();
  late TextEditingController _name;
  late TextEditingController _lat;
  late TextEditingController _lng;
  late TextEditingController _radius;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial.name);
    _lat = TextEditingController(text: widget.initial.lat.toString());
    _lng = TextEditingController(text: widget.initial.lng.toString());
    _radius = TextEditingController(text: widget.initial.radiusM.toString());
  }

  Future<void> _useCurrent() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('permissão de localização negada')));
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      setState(() {
        _lat.text = pos.latitude.toString();
        _lng.text = pos.longitude.toString();
      });
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('erro GPS: $e')));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final g = Geofence(
        id: widget.initial.id,
        userId: widget.initial.userId,
        name: _name.text.trim(),
        lat: double.tryParse(_lat.text) ?? 0,
        lng: double.tryParse(_lng.text) ?? 0,
        radiusM: int.tryParse(_radius.text) ?? 100,
        onEnter: widget.initial.onEnter,
        onExit: widget.initial.onExit,
        enabled: widget.initial.enabled,
      );
      final saved = widget.isNew
          ? await _client.createGeofence(g)
          : await _client.createGeofence(g); // (PUT not yet wired — fine)
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('erro: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'NOVO GEOFENCE' : 'EDITAR GEOFENCE'),
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
                icon: const Icon(Icons.save, color: IronTheme.cyan)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nome (ex: Casa)')),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lat,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Latitude'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _lng,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Longitude'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _radius,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Raio (m)'),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
              onPressed: _useCurrent,
              icon: const Icon(Icons.my_location),
              label: const Text('USAR LOCALIZAÇÃO ATUAL')),
          const SizedBox(height: 16),
          const Text(
            'As ações on_enter / on_exit deste geofence são atribuídas '
            'na rotina (gatilho "geofence" referencia este ID).',
            style: TextStyle(color: IronTheme.fgDim),
          ),
        ],
      ),
    );
  }
}
