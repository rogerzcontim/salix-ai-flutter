import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'pages/chat_page.dart';
import 'pages/onboarding_page.dart';
import 'services/persona_store.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: IronTheme.bgDark,
    statusBarIconBrightness: Brightness.light,
  ));
  // Best-effort mic permission ahead of first STT call.
  Permission.microphone.request();
  runApp(const ProviderScope(child: SalixApp()));
}

class SalixApp extends StatelessWidget {
  const SalixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SALIX AI',
      debugShowCheckedModeBanner: false,
      theme: IronTheme.build(),
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
