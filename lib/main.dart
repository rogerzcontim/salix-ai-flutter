// v3.0.0+25 — BOOT RESILIENTE + LIFECYCLE OBSERVER + WAKE/GEO BLINDADO.
//
// Filosofia:
//   - O app NUNCA pode fechar silenciosamente. Sempre alguma UI.
//   - Qualquer erro (Flutter, Zone, PlatformDispatcher, build) é capturado,
//     reportado pra https://salix-ai.com/api/_crash, e mostrado em _CrashScreen.
//   - Plugin calls (PackageInfo, SharedPreferences) são feitos APÓS primeiro
//     frame, em try/catch, com fallback pra OnboardingPage.
//   - Sem chamadas síncronas a plugin antes de runApp.
//   - v3.0.0+25: lifecycle observer registra `paused/detached/inactive` em
//     CrashReporter.info pra detectar SIGKILL nativo (sintoma do crash do
//     wake word/geo: app vira detached sem stack Dart). Isso fornece
//     telemetria do tipo "app foi morto pelo OS" que o /api/_crash recebe
//     no NEXT boot via fila in-memory persistida.
//   - v3.0.0+25: foreground service do wake word agora chama startForeground
//     ANTES de checar permission, evitando o ANR de 5s que matava o app
//     silenciosamente.
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/chat_page.dart';
import 'pages/onboarding_page.dart';
import 'services/chat_stream_keepalive.dart';
import 'services/crash_reporter.dart';
import 'services/persona_store.dart';
import 'theme.dart';

void main() {
  // Captura de erros Flutter (asserts, build errors, render errors).
  FlutterError.onError = (FlutterErrorDetails details) {
    try {
      CrashReporter.report(
        details.exception,
        details.stack,
        context: 'FlutterError',
      );
    } catch (_) {}
    debugPrint('[FlutterError] ${details.exception}');
  };

  // v2.0.0+21: PlatformDispatcher.onError pega erros de plugin/ffi/isolate
  // que escapam do FlutterError.onError (caso clássico de PlatformException
  // de plugin nativo lançada em handler de callback nativo).
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    try {
      CrashReporter.report(error, stack, context: 'PlatformDispatcher');
    } catch (_) {}
    debugPrint('[PlatformDispatcher] $error');
    return true; // engole — já reportamos
  };

  // Zone guard pra erros assíncronos não capturados.
  runZonedGuarded(() async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
    } catch (e, s) {
      // Se nem ensureInitialized passar, mostra crash screen.
      runApp(_CrashApp(e.toString(), s.toString()));
      return;
    }
    // Inicializa CrashReporter — não pode quebrar o boot.
    try {
      await CrashReporter.init();
    } catch (_) {}
    // v3.0.0+25: lifecycle observer pra detectar SIGKILL nativo
    try {
      WidgetsBinding.instance.addObserver(_LifecycleAuditor());
    } catch (_) {}
    // v7.0.0+32: sobe FG service ChatStreamService em modo persistente.
    // Best-effort — se falhar (Android antigo, OEM chato), seguimos sem.
    // O servico ja existe se BootReceiver tiver subido depois de reboot;
    // chamar de novo eh idempotente (acao ACTION_START_PERSISTENT).
    try {
      // ignore: discarded_futures
      ChatStreamKeepalive().ensurePersistent();
    } catch (e) {
      debugPrint('[main] ensurePersistent failed: $e');
    }
    runApp(const ProviderScope(child: SalixAppLazy()));
  }, (error, stack) {
    try {
      CrashReporter.report(error, stack, context: 'ZoneError');
    } catch (_) {}
    debugPrint('[ZoneError] $error');
    // Não substituímos o app aqui — onError do Flutter já cuida do UI.
  });
}

/// SalixAppLazy: monta MaterialApp + try/catch envolvendo o root.
/// Se o build do _AppRouter falhar, mostra _CrashScreen ao invés de fechar.
class SalixAppLazy extends StatelessWidget {
  const SalixAppLazy({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SALIX AI',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: _safeTheme(),
      darkTheme: _safeTheme(),
      home: Builder(
        builder: (ctx) {
          try {
            return const _AppRouter();
          } catch (e, s) {
            CrashReporter.report(e, s, context: 'SalixAppLazy.build');
            return _CrashScreen(e.toString(), s.toString());
          }
        },
      ),
    );
  }

  ThemeData _safeTheme() {
    try {
      return IronTheme.build(light: false);
    } catch (_) {
      return ThemeData.dark();
    }
  }
}

/// _AppRouter: faz onboarding-vs-chat lookup APÓS primeiro frame, em try/catch.
class _AppRouter extends StatefulWidget {
  const _AppRouter();
  @override
  State<_AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<_AppRouter> {
  Widget? _content;
  String? _error;
  String? _stack;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootRoute());
  }

  Future<void> _bootRoute() async {
    try {
      final route = await _resolveRoute();
      if (mounted) setState(() => _content = route);
    } catch (e, s) {
      CrashReporter.report(e, s, context: '_bootRoute');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _stack = s.toString();
        });
      }
    }
  }

  Future<Widget> _resolveRoute() async {
    bool onboarded = false;
    try {
      final store = PersonaStore();
      onboarded = await store.isOnboarded();
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'PersonaStore.isOnboarded');
      // Fallback: primeira execução / shared_prefs corrompido → onboarding.
      onboarded = false;
    }

    if (!onboarded) {
      try {
        return const OnboardingPage();
      } catch (e, s) {
        CrashReporter.report(e, s, context: 'OnboardingPage build');
        rethrow;
      }
    }
    try {
      return const ChatPage();
    } catch (e, s) {
      CrashReporter.report(e, s, context: 'ChatPage build');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _CrashScreen(_error!, _stack ?? '');
    }
    if (_content != null) return _content!;
    return const Scaffold(
      backgroundColor: Color(0xFF0A0A0F),
      body: Center(
        child: CircularProgressIndicator(color: Colors.cyanAccent),
      ),
    );
  }
}

/// _LifecycleAuditor: registra mudanças de estado do app pra que possamos
/// correlacionar SIGKILLs (Android matando o processo durante boot do
/// foreground service) com eventos antes da morte. Cada transição é
/// marcada como `info` no CrashReporter — não conta como crash, mas no
/// próximo boot viaja na mesma fila pra /api/_crash.
class _LifecycleAuditor extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    try {
      CrashReporter.info(
        'lifecycle:${state.name}',
        message: 'app state changed to ${state.name}',
      );
    } catch (_) {}
  }
}

/// _CrashApp: usado quando NEM `WidgetsFlutterBinding.ensureInitialized()` passou.
/// MaterialApp standalone.
class _CrashApp extends StatelessWidget {
  final String error;
  final String stack;
  const _CrashApp(this.error, this.stack);
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _CrashScreen(error, stack),
    );
  }
}

/// _CrashScreen: tela visível pro Roger fotografar.
/// Mostra error+stack, botão pra reenviar relatório.
class _CrashScreen extends StatelessWidget {
  final String error;
  final String stack;
  const _CrashScreen(this.error, this.stack);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'SALIX — crash detectado',
                style: TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Tire um print desta tela e mande pro suporte.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.15),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.6)),
                ),
                child: Text(
                  error,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Stack:',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: SingleChildScrollView(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    color: Colors.white.withOpacity(0.04),
                    child: Text(
                      stack,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: () {
                      CrashReporter.report(
                        error,
                        StackTrace.fromString(stack),
                        context: 'manual_resend',
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Relatório reenviado'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.send, size: 16),
                    label: const Text('Reenviar erro'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      // Tenta reentrar no app — útil se foi crash temporário.
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute<void>(
                          builder: (_) => const _AppRouter(),
                        ),
                        (_) => false,
                      );
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Tentar novamente'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Versão: 7.0.0+32  •  endpoint: salix-ai.com/api/_crash',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
