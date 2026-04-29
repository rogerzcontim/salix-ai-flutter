// SALIX onda 4 — UI Geofences
// v2.0.0+21: chamadas Geolocator wrappadas em try/catch específico +
// CrashReporter (mesma estratégia do location_pinger).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:geolocator/geolocator.dart';

import '../models/persona.dart';
import '../services/crash_reporter.dart';
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
      bool ok = false;
      try {
        ok = await Geolocator.isLocationServiceEnabled();
      } on MissingPluginException catch (e, s) {
        CrashReporter.report(e, s, context: 'geofences_page:isLocSvcEnabled.MissingPlugin');
        return null;
      } on PlatformException catch (e, s) {
        CrashReporter.report(e, s, context: 'geofences_page:isLocSvcEnabled.PlatformException');
        return null;
      }
      if (!ok) return null;

      LocationPermission perm = LocationPermission.denied;
      try {
        perm = await Geolocator.checkPermission();
      } on MissingPluginException catch (e, s) {
        CrashReporter.report(e, s, context: 'geofences_page:checkPerm.MissingPlugin');
        return null;
      } on PlatformException catch (e, s) {
        CrashReporter.report(e, s, context: 'geofences_page:checkPerm.PlatformException');
        return null;
      }
      if (perm == LocationPermission.denied) {
        try {
          perm = await Geolocator.requestPermission();
        } on MissingPluginException catch (e, s) {
          CrashReporter.report(e, s, context: 'geofences_page:reqPerm.MissingPlugin');
          return null;
        } on PlatformException catch (e, s) {
          CrashReporter.report(e, s, context: 'geofences_page:reqPerm.PlatformException');
          return null;
        }
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return null;
      try {
        return await Geolocator.getCurrentPosition();
      } on PlatformException catch (e, s) {
        CrashReporter.report(e, s, context: 'geofences_page:getPos.PlatformException');
        return null;
      } on MissingPluginException catch (e, s) {
        CrashReporter.report(e, s, context: 'geofences_page:getPos.MissingPlugin');
        return null;
      } catch (e, s) {
        CrashReporter.report(e, s, context: 'geofences_page:getPos.unknown');
        return null;
      }
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'geofences_page:safeCurrentPosition.outer');
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
    const denyMsg =
        'Permita localização em Configurações > Apps > SALIX > Permissões';
    try {
      // Check if location services enabled.
      bool svc = false;
      try {
        svc = await Geolocator.isLocationServiceEnabled();
      } on MissingPluginException catch (e, s) {
        CrashReporter.report(e, s,
            context: 'geofences_edit:isLocSvcEnabled.MissingPlugin');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Plugin de localização indisponível — reinstale o app')));
        }
        return;
      } on PlatformException catch (e, s) {
        CrashReporter.report(e, s,
            context: 'geofences_edit:isLocSvcEnabled.PlatformException');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('erro serviço localização: ${e.message}')));
        }
        return;
      }
      if (!svc) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Ative o GPS do aparelho e tente novamente')));
        }
        return;
      }

      LocationPermission perm = LocationPermission.denied;
      try {
        perm = await Geolocator.checkPermission();
      } on MissingPluginException catch (e, s) {
        CrashReporter.report(e, s,
            context: 'geofences_edit:checkPerm.MissingPlugin');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Plugin de localização indisponível — reinstale o app')));
        }
        return;
      } on PlatformException catch (e, s) {
        CrashReporter.report(e, s,
            context: 'geofences_edit:checkPerm.PlatformException');
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(denyMsg)));
        }
        return;
      }
      if (perm == LocationPermission.denied) {
        try {
          perm = await Geolocator.requestPermission();
        } on MissingPluginException catch (e, s) {
          CrashReporter.report(e, s,
              context: 'geofences_edit:reqPerm.MissingPlugin');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'Plugin de localização indisponível — reinstale o app')));
          }
          return;
        } on PlatformException catch (e, s) {
          CrashReporter.report(e, s,
              context: 'geofences_edit:reqPerm.PlatformException');
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(denyMsg)));
          }
          return;
        }
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(denyMsg)));
        }
        return;
      }

      Position pos;
      try {
        pos = await Geolocator.getCurrentPosition();
      } on MissingPluginException catch (e, s) {
        CrashReporter.report(e, s,
            context: 'geofences_edit:getPos.MissingPlugin');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Plugin de localização indisponível — reinstale o app')));
        }
        return;
      } on PlatformException catch (e, s) {
        CrashReporter.report(e, s,
            context: 'geofences_edit:getPos.PlatformException');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('erro GPS: ${e.message}')));
        }
        return;
      }
      setState(() {
        _lat.text = pos.latitude.toString();
        _lng.text = pos.longitude.toString();
      });
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'geofences_edit:useCurrent.outer');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('erro GPS: $e')));
      }
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
