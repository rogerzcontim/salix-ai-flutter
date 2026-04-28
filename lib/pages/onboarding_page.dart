import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/persona_store.dart';
import '../theme.dart';
import 'chat_page.dart';

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});
  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _pageController = PageController();
  int _step = 0;

  final _name = TextEditingController();
  String _voice = 'pt-BR';
  String _voiceGender = 'feminina';
  String _tone = 'amigo';
  String _backend = 'auto';
  final Set<String> _interests = {};
  String _avatar = '🤖';

  static const _voices = ['pt-BR', 'en-US', 'it-IT'];
  static const _genders = ['feminina', 'masculina'];
  static const _voiceLabels = {
    'pt-BR': 'Português (BR) 🇧🇷',
    'en-US': 'English (US) 🇺🇸',
    'it-IT': 'Italiano 🇮🇹',
  };
  static const _tones = ['amigo', 'técnico', 'mestre', 'mentor'];
  static const _backends = ['salix', 'oss', 'auto'];
  static const _allInterests = [
    'trading',
    'iron edge',
    'B3',
    'crypto',
    'desenvolvimento',
    'estudos',
    'vinhos',
    'idiomas',
    'saúde',
    'produtividade',
  ];
  static const _avatars = ['🤖', '🦊', '🐺', '🐉', '🦅', '🧠', '⚡', '🌌'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(
              value: (_step + 1) / 5,
              color: IronTheme.cyan,
              backgroundColor: IronTheme.bgPanel,
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _stepName(),
                  _stepVoice(),
                  _stepTone(),
                  _stepBackend(),
                  _stepInterests(),
                ],
              ),
            ),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _stepName() => _StepShell(
        title: 'Como vou te chamar?',
        subtitle: 'Vou usar isso pra personalizar tudo.',
        child: Column(
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Seu nome'),
            ),
            const SizedBox(height: 20),
            const Text('Avatar', style: TextStyle(color: IronTheme.fgDim)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              children: _avatars
                  .map((a) => GestureDetector(
                        onTap: () => setState(() => _avatar = a),
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: IronTheme.bgPanel,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: a == _avatar
                                    ? IronTheme.cyan
                                    : const Color(0x4400FFFF),
                                width: a == _avatar ? 2 : 1),
                          ),
                          alignment: Alignment.center,
                          child: Text(a, style: const TextStyle(fontSize: 28)),
                        ),
                      ))
                  .toList(),
            ),
          ],
        ),
      );

  Widget _stepVoice() => _StepShell(
        title: 'Idioma e voz',
        subtitle: 'Escolha o idioma e o gênero da voz (Edge TTS humana).',
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 4, bottom: 4),
                child: Text('Idioma',
                    style: TextStyle(color: IronTheme.fgDim, fontSize: 13)),
              ),
            ),
            ..._voices.map((v) => RadioListTile<String>(
                  value: v,
                  groupValue: _voice,
                  onChanged: (x) => setState(() => _voice = x!),
                  title: Text(_voiceLabels[v] ?? v),
                  activeColor: IronTheme.cyan,
                  dense: true,
                )),
            const Divider(),
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 4, bottom: 4),
                child: Text('Gênero da voz',
                    style: TextStyle(color: IronTheme.fgDim, fontSize: 13)),
              ),
            ),
            ..._genders.map((g) => RadioListTile<String>(
                  value: g,
                  groupValue: _voiceGender,
                  onChanged: (x) => setState(() => _voiceGender = x!),
                  title: Text(g[0].toUpperCase() + g.substring(1)),
                  activeColor: IronTheme.cyan,
                  dense: true,
                )),
          ],
        ),
      );

  Widget _stepTone() => _StepShell(
        title: 'Tom de fala',
        subtitle: 'Como SALIX deve responder.',
        child: Column(
          children: _tones
              .map((t) => RadioListTile<String>(
                    value: t,
                    groupValue: _tone,
                    onChanged: (x) => setState(() => _tone = x!),
                    title: Text(t),
                    activeColor: IronTheme.cyan,
                  ))
              .toList(),
        ),
      );

  Widget _stepBackend() => _StepShell(
        title: 'Modelo padrão',
        subtitle:
            'SALIX é a IA própria em treinamento. OSS é gpt-oss-120b (rápido). Auto deixa o roteador escolher.',
        child: Column(
          children: _backends
              .map((b) => RadioListTile<String>(
                    value: b,
                    groupValue: _backend,
                    onChanged: (x) => setState(() => _backend = x!),
                    title: Text(b.toUpperCase()),
                    subtitle: Text(_backendDesc(b),
                        style: const TextStyle(color: IronTheme.fgDim)),
                    activeColor: IronTheme.cyan,
                  ))
              .toList(),
        ),
      );

  String _backendDesc(String b) => switch (b) {
        'salix' => 'IA proprietária em treinamento (mais lenta, especialista IronEdge)',
        'oss' => 'gpt-oss-120b — 1500 tok/s, multipropósito',
        _ => 'roteador escolhe baseado na pergunta',
      };

  Widget _stepInterests() => _StepShell(
        title: 'O que te interessa?',
        subtitle: 'Escolha quantos quiser.',
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: _allInterests.map((i) {
            final on = _interests.contains(i);
            return ChoiceChip(
              label: Text(i),
              selected: on,
              selectedColor: IronTheme.cyan.withOpacity(0.25),
              backgroundColor: IronTheme.bgPanel,
              labelStyle: TextStyle(
                color: on ? IronTheme.cyan : IronTheme.fgBright,
              ),
              side: BorderSide(
                  color: on
                      ? IronTheme.cyan
                      : const Color(0x4400FFFF)),
              onSelected: (_) => setState(() {
                if (on) {
                  _interests.remove(i);
                } else {
                  _interests.add(i);
                }
              }),
            );
          }).toList(),
        ),
      );

  Widget _bottomBar() {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          if (_step > 0)
            TextButton(
              onPressed: () {
                setState(() => _step--);
                _pageController.previousPage(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOut);
              },
              child: const Text('Voltar'),
            ),
          const Spacer(),
          ElevatedButton(
            onPressed: _canAdvance() ? _advance : null,
            child: Text(_step == 4 ? 'COMEÇAR' : 'Próximo'),
          ),
        ],
      ),
    );
  }

  bool _canAdvance() {
    if (_step == 0) return _name.text.trim().isNotEmpty;
    return true;
  }

  Future<void> _advance() async {
    if (_step < 4) {
      setState(() => _step++);
      _pageController.nextPage(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut);
      return;
    }
    final store = PersonaStore();
    await store.create(
      displayName: _name.text.trim(),
      voice: _voice,
      voiceGender: _voiceGender,
      tone: _tone,
      backend: _backend,
      interests: _interests.toList(),
      avatarEmoji: _avatar,
    );
    await store.setOnboarded();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ChatPage()));
  }
}

class _StepShell extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  const _StepShell(
      {required this.title, required this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 36, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NeonGlow(
            color: IronTheme.cyan,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: IronTheme.bgPanel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: IronTheme.cyan),
              ),
              child: const Text('SALIX AI',
                  style: TextStyle(
                      color: IronTheme.cyan,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(height: 22),
          Text(title,
              style: const TextStyle(
                  color: IronTheme.fgBright,
                  fontSize: 28,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(subtitle,
              style: const TextStyle(color: IronTheme.fgDim, fontSize: 14)),
          const SizedBox(height: 28),
          child,
        ],
      ),
    );
  }
}
