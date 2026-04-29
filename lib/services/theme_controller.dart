import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Onda 8 — Theme controller (dark default, light alternate).
/// Persisted in SharedPreferences under key `salix.theme`.
const _kThemeKey = 'salix.theme';

class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController() : super(ThemeMode.dark) {
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kThemeKey);
    if (v == 'light') state = ThemeMode.light;
    else state = ThemeMode.dark;
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kThemeKey, mode == ThemeMode.light ? 'light' : 'dark');
  }

  Future<void> toggle() async {
    await set(state == ThemeMode.light ? ThemeMode.dark : ThemeMode.light);
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>((ref) {
  return ThemeModeController();
});
