import 'dart:convert';

/// User persona — saved per-user in SharedPreferences.
class Persona {
  final String id;          // uuid
  final String displayName; // shown in UI
  final String voice;       // pt-BR | en-US | it-IT (canonical lang code)
  final String voiceGender; // feminina | masculina
  final String tone;        // amigo | técnico | mestre | mentor
  final String backend;     // salix | oss | auto
  final List<String> interests;
  final String avatarEmoji;

  Persona({
    required this.id,
    required this.displayName,
    required this.voice,
    this.voiceGender = 'feminina',
    required this.tone,
    required this.backend,
    required this.interests,
    required this.avatarEmoji,
  });

  Persona copyWith({
    String? displayName,
    String? voice,
    String? voiceGender,
    String? tone,
    String? backend,
    List<String>? interests,
    String? avatarEmoji,
  }) =>
      Persona(
        id: id,
        displayName: displayName ?? this.displayName,
        voice: voice ?? this.voice,
        voiceGender: voiceGender ?? this.voiceGender,
        tone: tone ?? this.tone,
        backend: backend ?? this.backend,
        interests: interests ?? this.interests,
        avatarEmoji: avatarEmoji ?? this.avatarEmoji,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'voice': voice,
        'voiceGender': voiceGender,
        'tone': tone,
        'backend': backend,
        'interests': interests,
        'avatarEmoji': avatarEmoji,
      };

  factory Persona.fromJson(Map<String, dynamic> j) => Persona(
        id: j['id'] ?? '',
        displayName: j['displayName'] ?? 'Você',
        voice: j['voice'] ?? 'pt-BR',
        voiceGender: j['voiceGender'] ?? 'feminina',
        tone: j['tone'] ?? 'amigo',
        backend: j['backend'] ?? 'auto',
        interests: (j['interests'] as List?)?.cast<String>() ?? const [],
        avatarEmoji: j['avatarEmoji'] ?? '🤖',
      );

  String toRaw() => jsonEncode(toJson());
  static Persona fromRaw(String raw) =>
      Persona.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  /// Human-readable language label.
  String get languageLabel {
    switch (voice) {
      case 'en-US':
        return 'English (US)';
      case 'it-IT':
        return 'Italiano';
      default:
        return 'Português (BR)';
    }
  }

  /// System prompt — instructs SALIX to reply in the user's chosen language and
  /// keeps spoken-friendly markdown rules.
  String systemPrompt() {
    String langInstruction;
    switch (voice) {
      case 'en-US':
        langInstruction =
            'Always reply in clear US English unless the user speaks another language first.';
        break;
      case 'it-IT':
        langInstruction =
            'Rispondi sempre in italiano chiaro a meno che l\'utente non scriva in un\'altra lingua.';
        break;
      default:
        langInstruction =
            'Sempre responda em português do Brasil, a menos que o usuário fale em outra língua.';
    }
    return '''
Você é SALIX, assistente IA pessoal cyberpunk do projeto Iron Edge AI.
$langInstruction
Persona configurada:
- Nome do usuário: $displayName
- Tom: $tone
- Idioma da voz: $languageLabel ($voiceGender)
- Interesses: ${interests.join(", ")}
Responda direto, sem floreios. Use markdown apenas quando ajudar a leitura.
Se o usuário pedir para abrir app, ferramenta ou site, responda com a tag
[OPEN_INTENT package=... url=...] em uma linha isolada para o cliente
disparar o intent Android.
''';
  }
}
