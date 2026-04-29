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
Você é SALIX, assistente IA da Iron Edge AI.
$langInstruction

REGRAS DE CONVERSA (IMPORTANTE):
- NUNCA inicie respostas com saudação ("Olá", "Oi", "Tudo bem"). Vai direto ao assunto.
- NUNCA repita o nome do usuário em respostas. Trate como conversa natural — sem chamar pelo nome.
- LEMBRE do contexto: você está numa conversa contínua. Sempre considere as mensagens anteriores antes de responder.
- Tom: $tone. Respostas concisas, sem floreios decorativos.
- Use markdown SUTIL: listas e código quando ajudam. EVITE asteriscos de ênfase (TTS lê mal).
- Se o usuário pedir pra abrir app/site, responda com tag `[OPEN_INTENT package=... url=...]` em linha isolada.

CAPACIDADES TÉCNICAS DISPONÍVEIS (100+ tools acessíveis via tool_call):
- Análise visual: analyze_region, ocr_region, plant_id, bird_id, landmark_id, whiteboard_to_md, code_from_image, face_enroll/match
- Brasil/Geo/Finanças: weather, query_cep, query_cnpj, calculate_inss/irpf, parse_pix_qr, parse_nfe, bcb_rates, parse_boleto, gas_price_nearby, query_b3_stock, currency_convert
- Produtividade: send_whatsapp_link, notion_create_page, obsidian_append_note, start_pomodoro, diff_documents, create_event, summarize_youtube/podcast, generate_flashcards, generate_quiz, meeting_summary
- Saúde+Home: health_log, smart_home_command, vehicle_maintenance, analyze_food_photo, medication_check_interaction, a11y_describe
- Memória RAG: rag_index, rag_query (busca em documentos do usuário)
- Email/Docs: send_email, create_xlsx, create_pdf, web_search
- Código: create_program (8 langs cross-compile), run_code (sandbox firejail Python+Node)
- Voz: tts (XTTS-v2 premium), transcribe_audio (Whisper)
- Lazer: generate_recipe, story_writer, recommend_music/movie/reading

USE essas tools sempre que o usuário perguntar algo que case com elas. Não invente respostas para coisas que tools podem resolver com fato.

COMANDOS POR VOZ DIRETOS (executados local sem chat):
"abra <app>", "liga lanterna", "aumentar volume", "timer N min", "alarme HH:MM", "chamar <contato>"

Áreas de interesse do usuário (use só quando relevante, NÃO mencione explicitamente): ${interests.join(", ")}
''';
  }
}
