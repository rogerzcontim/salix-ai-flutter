import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'meta_agent_client.dart';
import 'meta_agent_client_ext.dart';

/// Onda 8 — Push notifications service.
///
/// Wraps `firebase_messaging` if available at runtime. The plugin is NOT
/// listed in pubspec yet (Firebase project setup still pending Roger
/// authorization). Until then, this service exposes a stable Dart API and
/// gracefully no-ops, so the rest of the app can call into it without
/// guarding every call site.
///
/// When the Firebase plugin is added (`firebase_core` + `firebase_messaging`),
/// implement the TODO blocks below — the public surface (init / token /
/// register / onMessage stream) does not change.
class PushNotificationsService {
  PushNotificationsService._();
  static final instance = PushNotificationsService._();

  static const _kFcmTokenKey = 'salix.fcm_token';
  static const _kFcmEnabledKey = 'salix.fcm_enabled';

  String? _cachedToken;
  bool _initialized = false;

  final _messagesCtl = StreamController<RemotePush>.broadcast();
  Stream<RemotePush> get onMessage => _messagesCtl.stream;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final p = await SharedPreferences.getInstance();
      _cachedToken = p.getString(_kFcmTokenKey);
      final enabled = p.getBool(_kFcmEnabledKey) ?? true;
      if (!enabled) return;

      // Request notification permission on Android 13+ / iOS.
      try { await Permission.notification.request(); } catch (_) {}

      // TODO(firebase): when firebase_messaging is added to pubspec, replace
      // the no-op below with:
      //   await Firebase.initializeApp();
      //   final fcm = FirebaseMessaging.instance;
      //   await fcm.requestPermission();
      //   final token = await fcm.getToken();
      //   await _registerToken(token);
      //   FirebaseMessaging.onMessage.listen((m) { _messagesCtl.add(...); });
      //   FirebaseMessaging.onMessageOpenedApp.listen(...);
      //   FirebaseMessaging.onBackgroundMessage(_bgHandler);
      //
      // For now we are wired but inactive — server side can already accept
      // tokens via /api/push/register.
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[push] init error: $e\n$st');
      }
    }
  }

  Future<void> setEnabled(bool enabled) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kFcmEnabledKey, enabled);
  }

  Future<bool> isEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kFcmEnabledKey) ?? true;
  }

  String? get token => _cachedToken;

  /// Send the device token to the SALIX backend so the server can address
  /// pushes via FCM. Idempotent — safe to call repeatedly.
  Future<void> _registerToken(String? token) async {
    if (token == null || token.isEmpty) return;
    _cachedToken = token;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kFcmTokenKey, token);
    try {
      await MetaAgentClient().registerPushToken(token: token, platform: 'android');
    } catch (e) {
      if (kDebugMode) debugPrint('[push] register token failed: $e');
    }
  }
}

/// Lightweight DTO for push messages so the rest of the app does not need
/// to import firebase_messaging types.
class RemotePush {
  final String? title;
  final String? body;
  final Map<String, dynamic> data;
  RemotePush({this.title, this.body, this.data = const {}});
}
