import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Onda 8 — Theme controller (dark default, light alternate).
/// Persisted in SharedPreferences under key `salix.theme`.
///
/// v1.8.0: load is now LAZY. Default = dark, no SharedPreferences call in
/// constructor. The first call to [ensureLoaded] (or any toggle) reads disk.
/// This avoids triggering shared_prefs plugin channel before runApp/first
/// frame is up, which was suspected of crashing the boot.
const _kThemeKey = 'salix.theme';

class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController() : super(ThemeMode.dark);

  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(_kThemeKey);
      if (v == 'light') {
        state = ThemeMode.light;
      } else {
        state = ThemeMode.dark;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[theme] load failed: $e');
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kThemeKey, mode == ThemeMode.light ? 'light' : 'dark');
    } catch (e) {
      if (kDebugMode) debugPrint('[theme] persist failed: $e');
    }
  }

  Future<void> toggle() async {
    await set(state == ThemeMode.light ? ThemeMode.dark : ThemeMode.light);
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>((ref) {
  return ThemeModeController();
});
