import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/persona.dart';

const _kPersonas = 'personas.v1';
const _kActive = 'persona.active';
const _kOnboarded = 'onboarded.v1';

class PersonaStore {
  static const _uuid = Uuid();

  Future<List<Persona>> list() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kPersonas);
    if (raw == null) return [];
    final arr = jsonDecode(raw) as List;
    return arr
        .cast<Map<String, dynamic>>()
        .map(Persona.fromJson)
        .toList(growable: false);
  }

  Future<void> save(List<Persona> ps) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kPersonas, jsonEncode(ps.map((e) => e.toJson()).toList()));
  }

  Future<Persona> create({
    required String displayName,
    required String voice,
    String voiceGender = 'feminina',
    required String tone,
    required String backend,
    required List<String> interests,
    String avatarEmoji = '🤖',
  }) async {
    final all = await list();
    final persona = Persona(
      id: _uuid.v4(),
      displayName: displayName,
      voice: voice,
      voiceGender: voiceGender,
      tone: tone,
      backend: backend,
      interests: interests,
      avatarEmoji: avatarEmoji,
    );
    all.add(persona);
    await save(all);
    await setActive(persona.id);
    return persona;
  }

  Future<void> setActive(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kActive, id);
  }

  Future<Persona?> active() async {
    final p = await SharedPreferences.getInstance();
    final id = p.getString(_kActive);
    if (id == null) return null;
    final all = await list();
    return all.where((e) => e.id == id).cast<Persona?>().firstWhere(
          (_) => true,
          orElse: () => null,
        );
  }

  Future<void> update(Persona persona) async {
    final all = await list();
    final idx = all.indexWhere((e) => e.id == persona.id);
    if (idx >= 0) {
      all[idx] = persona;
      await save(all);
    }
  }

  Future<bool> isOnboarded() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kOnboarded) ?? false;
  }

  Future<void> setOnboarded() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kOnboarded, true);
  }
}
