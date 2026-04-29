import 'package:flutter/material.dart';

import '../theme.dart';

/// v1.7.0+18 — Catálogo de capacidades técnicas (tools server-side).
///
/// Mostra ao usuário tudo que o SALIX consegue fazer via tool_call no
/// meta-adapter `:9270`. Não chama as tools direto: o usuário pede em
/// linguagem natural no chat e o LLM (OSS gpt-oss-120b) escolhe quais
/// tools usar.
///
/// Acessível via Settings → "Capacidades SALIX".
class ToolsCatalogPage extends StatelessWidget {
  const ToolsCatalogPage({super.key});

  static final List<_ToolCategory> _categories = [
    _ToolCategory(
      title: 'Análise visual',
      icon: Icons.image_search,
      color: IronTheme.cyan,
      tools: const [
        _Tool('analyze_region', 'Recorta uma região da imagem e descreve com Llama 4 Scout'),
        _Tool('ocr_region', 'OCR (Tesseract) de uma região específica'),
        _Tool('plant_id', 'Identifica espécie de planta a partir de foto'),
        _Tool('bird_id', 'Identifica pássaro por imagem'),
        _Tool('landmark_id', 'Reconhece pontos turísticos / monumentos'),
        _Tool('whiteboard_to_md', 'Converte foto de whiteboard em markdown'),
        _Tool('code_from_image', 'Extrai código de screenshot e roda formatter'),
        _Tool('face_enroll', 'Cadastra um rosto na galeria privada (LGPD)'),
        _Tool('face_match', 'Procura match contra galeria privada'),
        _Tool('analyze_food_photo', 'Estima calorias / macros do prato fotografado'),
        _Tool('a11y_describe', 'Descreve cena pra acessibilidade (visão reduzida)'),
      ],
    ),
    _ToolCategory(
      title: 'Brasil / Geo / Finanças',
      icon: Icons.account_balance,
      color: IronTheme.magenta,
      tools: const [
        _Tool('weather', 'Previsão do tempo por cidade ou coordenadas'),
        _Tool('query_cep', 'Consulta endereço por CEP (ViaCEP)'),
        _Tool('query_cnpj', 'Razão social + situação cadastral'),
        _Tool('calculate_inss', 'Cálculo INSS por faixa salarial'),
        _Tool('calculate_irpf', 'Imposto de renda devido por base'),
        _Tool('parse_pix_qr', 'Lê QR Code Pix e extrai chave + valor'),
        _Tool('parse_nfe', 'Decodifica XML de Nota Fiscal eletrônica'),
        _Tool('parse_boleto', 'Lê linha digitável e extrai dados'),
        _Tool('bcb_rates', 'Taxas Selic / IPCA / dólar BCB'),
        _Tool('gas_price_nearby', 'Preço médio combustível em raio'),
        _Tool('query_b3_stock', 'Cotação ação B3 + variação dia'),
        _Tool('currency_convert', 'Converte moedas (taxa do dia)'),
      ],
    ),
    _ToolCategory(
      title: 'Produtividade',
      icon: Icons.work_outline,
      color: IronTheme.cyan,
      tools: const [
        _Tool('send_whatsapp_link', 'Gera wa.me/<num>?text=... e abre'),
        _Tool('notion_create_page', 'Cria página no Notion via API'),
        _Tool('obsidian_append_note', 'Anexa texto numa nota Obsidian via local REST'),
        _Tool('start_pomodoro', 'Inicia ciclo 25/5 com notificação'),
        _Tool('diff_documents', 'Compara dois textos / arquivos'),
        _Tool('create_event', 'Cria evento de calendário (.ics ou Google)'),
        _Tool('summarize_youtube', 'Baixa transcript YT e resume'),
        _Tool('summarize_podcast', 'Whisper + summarizer pra podcasts'),
        _Tool('generate_flashcards', 'Cria flashcards Anki a partir de texto'),
        _Tool('generate_quiz', 'Gera quiz multiple-choice de tópico'),
        _Tool('meeting_summary', 'Transcreve áudio + extrai action items'),
      ],
    ),
    _ToolCategory(
      title: 'Saúde + casa inteligente',
      icon: Icons.favorite_outline,
      color: IronTheme.magenta,
      tools: const [
        _Tool('health_log', 'Registra peso/PA/glicose/sintoma no histórico'),
        _Tool('smart_home_command', 'Webhook pra Home Assistant / Tuya / etc'),
        _Tool('vehicle_maintenance', 'Lembra revisão / km / IPVA / seguro'),
        _Tool('medication_check_interaction', 'Avisa interações entre remédios'),
      ],
    ),
    _ToolCategory(
      title: 'Memória RAG (seus documentos)',
      icon: Icons.memory,
      color: IronTheme.cyan,
      tools: const [
        _Tool('rag_index', 'Indexa um documento na base privada do usuário'),
        _Tool('rag_query', 'Busca semântica nos documentos indexados'),
      ],
    ),
    _ToolCategory(
      title: 'Email / Documentos',
      icon: Icons.email_outlined,
      color: IronTheme.magenta,
      tools: const [
        _Tool('send_email', 'Envia email via Resend (SMTP gerenciado)'),
        _Tool('create_xlsx', 'Gera planilha Excel com fórmulas'),
        _Tool('create_pdf', 'Renderiza PDF a partir de markdown / HTML'),
        _Tool('web_search', 'Busca DuckDuckGo + extrai snippets'),
      ],
    ),
    _ToolCategory(
      title: 'Código',
      icon: Icons.code,
      color: IronTheme.cyan,
      tools: const [
        _Tool('create_program', 'Compila programa em 8 langs (cross-compile)'),
        _Tool('run_code', 'Executa Python / Node em sandbox firejail'),
      ],
    ),
    _ToolCategory(
      title: 'Voz',
      icon: Icons.record_voice_over,
      color: IronTheme.magenta,
      tools: const [
        _Tool('tts', 'Síntese voz premium XTTS-v2 (clonagem)'),
        _Tool('transcribe_audio', 'Whisper large-v3 transcrição'),
      ],
    ),
    _ToolCategory(
      title: 'Lazer',
      icon: Icons.celebration,
      color: IronTheme.cyan,
      tools: const [
        _Tool('generate_recipe', 'Receita a partir de ingredientes + restrições'),
        _Tool('story_writer', 'Conto / capítulo curto sob demanda'),
        _Tool('recommend_music', 'Sugere músicas por mood / artista similar'),
        _Tool('recommend_movie', 'Filmes por gênero / nota IMDb'),
        _Tool('recommend_reading', 'Livros / artigos por interesse'),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final totalTools =
        _categories.fold<int>(0, (sum, c) => sum + c.tools.length);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Capacidades SALIX'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            color: IronTheme.bgPanel,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$totalTools tools disponíveis',
                    style: const TextStyle(
                      color: IronTheme.cyan,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'SALIX (gpt-oss-120b) escolhe automaticamente quais tools '
                    'usar baseado no que você pede no chat. Você não precisa '
                    'invocar diretamente — pergunte em português normal.',
                    style: TextStyle(
                        color: IronTheme.fgDim, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Exemplos:\n'
                    '"Qual o CEP da rua X?"  →  query_cep\n'
                    '"Manda email pro João" →  send_email\n'
                    '"Que planta é essa?" (foto) →  plant_id\n'
                    '"Resume esse vídeo do YouTube" →  summarize_youtube',
                    style: TextStyle(
                        color: IronTheme.fgBright,
                        fontSize: 12,
                        height: 1.5,
                        fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          ..._categories.map((c) => _CategoryCard(c)),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Lista parcial — meta-adapter expande continuamente. '
              'A versão server-side é a fonte da verdade.',
              style: TextStyle(color: IronTheme.fgDim, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolCategory {
  final String title;
  final IconData icon;
  final Color color;
  final List<_Tool> tools;
  _ToolCategory({
    required this.title,
    required this.icon,
    required this.color,
    required this.tools,
  });
}

class _Tool {
  final String name;
  final String desc;
  const _Tool(this.name, this.desc);
}

class _CategoryCard extends StatelessWidget {
  final _ToolCategory cat;
  const _CategoryCard(this.cat);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        leading: Icon(cat.icon, color: cat.color),
        title: Text(cat.title,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${cat.tools.length} tools',
            style: const TextStyle(color: IronTheme.fgDim, fontSize: 12)),
        childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: cat.tools.map((t) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.bolt, size: 14, color: cat.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.name,
                        style: const TextStyle(
                          color: IronTheme.fgBright,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.desc,
                        style: const TextStyle(
                            color: IronTheme.fgDim, fontSize: 12, height: 1.3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
