// lib/pages/conversation_search_page.dart
//
// v7.0.0+32 — busca em todas as conversas salvas localmente.
//
// Roger 29/abr: "buscar alguma coisa que de uma conversa antiga".

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/conversation_db.dart';
import '../theme.dart';

class ConversationSearchPage extends StatefulWidget {
  /// If provided, the user-typed message is restricted to this persona;
  /// otherwise the search runs across all personas.
  final String? personaIdHint;

  const ConversationSearchPage({super.key, this.personaIdHint});

  @override
  State<ConversationSearchPage> createState() => _ConversationSearchPageState();
}

class _ConversationSearchPageState extends State<ConversationSearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Map<String, Object?>> _results = const [];
  bool _searching = false;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _runSearch);
  }

  Future<void> _runSearch() async {
    final q = _controller.text.trim();
    if (q == _lastQuery) return;
    _lastQuery = q;
    if (q.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final rows = await ConversationDb.instance.searchMessages(q, limit: 100);
      if (!mounted) return;
      setState(() {
        _results = rows;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _searching = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Falha na busca: $e')));
    }
  }

  String _snippet(String content, String query) {
    final lc = content.toLowerCase();
    final lq = query.toLowerCase();
    final idx = lc.indexOf(lq);
    if (idx < 0) {
      return content.length > 140 ? '${content.substring(0, 137)}...' : content;
    }
    final start = (idx - 40).clamp(0, content.length);
    final end = (idx + lq.length + 80).clamp(0, content.length);
    final pre = start > 0 ? '...' : '';
    final post = end < content.length ? '...' : '';
    return pre + content.substring(start, end) + post;
  }

  String _formatDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Buscar nas conversas…',
            hintStyle: TextStyle(color: IronTheme.fgDim),
            border: InputBorder.none,
          ),
          style: const TextStyle(color: IronTheme.fgBright, fontSize: 16),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              tooltip: 'Limpar',
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                _runSearch();
              },
            ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator(color: IronTheme.cyan));
    }
    if (_controller.text.trim().isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Digite uma palavra ou frase para procurar nas suas conversas salvas.',
            textAlign: TextAlign.center,
            style: TextStyle(color: IronTheme.fgDim),
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Text(
          'Nenhum resultado.',
          style: TextStyle(color: IronTheme.fgDim),
        ),
      );
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: Color(0x33FFFFFF)),
      itemBuilder: (_, i) {
        final r = _results[i];
        final content = (r['content'] as String?) ?? '';
        final role = (r['role'] as String?) ?? 'assistant';
        final title = (r['title'] as String?) ?? 'Conversa';
        final ts = (r['ts'] as int?) ?? 0;
        final convId = (r['conv_id'] as int?) ?? 0;
        final messageId = (r['msg_id'] as int?) ?? 0;
        final isUser = role == 'user';
        return ListTile(
          leading: Icon(
            isUser ? Icons.person : Icons.smart_toy_outlined,
            color: isUser ? IronTheme.cyan : IronTheme.magenta,
          ),
          title: Text(
            title.isEmpty ? 'Conversa' : title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: IronTheme.fgBright, fontSize: 14),
          ),
          subtitle: Text(
            _snippet(content, _controller.text.trim()),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: IronTheme.fgDim, fontSize: 13),
          ),
          trailing: Text(
            _formatDate(ts),
            style: const TextStyle(color: IronTheme.fgDim, fontSize: 11),
          ),
          onTap: () => Navigator.of(context).pop(ConversationOpenRequest(
            conversationId: convId,
            messageId: messageId,
          )),
        );
      },
    );
  }
}

/// Returned by [ConversationSearchPage] when the user taps a result. The
/// caller (chat_page) opens that conversation and scrolls to [messageId].
class ConversationOpenRequest {
  final int conversationId;
  final int messageId;
  ConversationOpenRequest({required this.conversationId, required this.messageId});
}
