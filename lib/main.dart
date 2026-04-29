import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'pages/chat_page.dart';
import 'pages/onboarding_page.dart';
import 'services/location_pinger.dart';
import 'services/persona_store.dart';
import 'services/push_notifications.dart';
import 'services/theme_controller.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: IronTheme.bgDark,
    statusBarIconBrightness: Brightness.light,
  ));
  // Best-effort mic permission ahead of first STT call.
  Permission.microphone.request();
  // Onda 4: location pinger foreground (silently no-ops without permission).
  LocationPinger.start();
  // Onda 8: push notifications init (best-effort, never blocks boot).
  // ignore: discarded_futures
  PushNotificationsService.instance.init();
  runApp(const ProviderScope(child: SalixApp()));
}

class SalixApp extends ConsumerWidget {
  const SalixApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'SALIX AI',
      debugShowCheckedModeBanner: false,
      theme: IronTheme.build(light: true),
      darkTheme: IronTheme.build(light: false),
      themeMode: mode,
      home: const _Boot(),
    );
  }
}

class _Boot extends StatefulWidget {
  const _Boot();
  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  @override
  void initState() {
    super.initState();
    _route();
  }

  Future<void> _route() async {
    final store = PersonaStore();
    final onboarded = await store.isOnboarded();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) =>
          onboarded ? const ChatPage() : const OnboardingPage(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator(color: IronTheme.cyan)),
    );
  }
}
