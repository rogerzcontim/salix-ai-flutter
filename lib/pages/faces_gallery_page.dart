// SALIX Onda 5 — faces_gallery_page.dart
// Path inside Flutter project: lib/pages/faces_gallery_page.dart
//
// Privacy-first gallery: lists user's enrolled faces, lets them rename,
// delete (soft), or add a new face from camera/gallery. NEVER displays
// faces from other users — the daemon enforces the user_id filter.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/attachments.dart';
import '../services/upload_service.dart';
import '../theme.dart';
import 'region_selector_page.dart' show MultimodalApi;

class FacesGalleryPage extends StatefulWidget {
  const FacesGalleryPage({super.key});
  @override
  State<FacesGalleryPage> createState() => _FacesGalleryPageState();
}

class _FacesGalleryPageState extends State<FacesGalleryPage> {
  final _uploads = UploadService();
  final _attachments = AttachmentsService();
  bool _loading = true;
  bool _adding = false;
  List<_Face> _faces = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final r = await http.get(
        Uri.parse('${MultimodalApi.baseUrl}/api/tools/face_list'),
      ).timeout(const Duration(seconds: 30));
      final j = jsonDecode(r.body);
      if (j is Map && j['ok'] == true && j['faces'] is List) {
        _faces = (j['faces'] as List)
            .map((e) => _Face.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addFromCamera() async {
    if (_adding) return;
    final path = await _attachments.capturePhoto();
    if (path == null) return;
    await _enrollFromPath(path);
  }

  Future<void> _addFromGallery() async {
    if (_adding) return;
    final path = await _attachments.pickImage();
    if (path == null) return;
    await _enrollFromPath(path);
  }

  Future<void> _enrollFromPath(String path) async {
    final name = await _askName();
    if (name == null || name.trim().isEmpty) return;
    setState(() => _adding = true);
    try {
      final up = await _uploads.upload(path: path, kind: 'image');
      final r = await http.post(
        Uri.parse('${MultimodalApi.baseUrl}/api/tools/face_enroll'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'file_id': up.fileId, 'name': name.trim()}),
      ).timeout(const Duration(seconds: 60));
      final j = jsonDecode(r.body);
      if (j is Map && j['ok'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('"$name" adicionado(a) à galeria.')),
          );
        }
      } else {
        final err = (j is Map ? (j['error'] ?? 'falha') : 'falha').toString();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Erro: $err')),
          );
        }
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<String?> _askName() async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IronTheme.bgPanel,
        title: const Text('Quem é esse rosto?',
            style: TextStyle(color: IronTheme.fgBright)),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Ex: Maria, filho Pedro…',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('Salvar')),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(_Face f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IronTheme.bgPanel,
        title: Text('Apagar "${f.name}"?',
            style: const TextStyle(color: IronTheme.fgBright)),
        content: const Text(
            'O rosto será removido da sua galeria privada. Pode adicionar de novo depois.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: IronTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apagar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await http.post(
        Uri.parse('${MultimodalApi.baseUrl}/api/tools/face_delete'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'id': f.id}),
      );
      await _refresh();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Galeria de rostos'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: IronTheme.cyan))
          : _faces.isEmpty
              ? _emptyState()
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _faces.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _faceTile(_faces[i]),
                ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: IronTheme.cyan,
        foregroundColor: Colors.black,
        icon: _adding
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: Colors.black))
            : const Icon(Icons.person_add),
        label: const Text('Adicionar'),
        onPressed: _adding ? null : _showAddSheet,
      ),
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.face, size: 80, color: IronTheme.fgDim),
              SizedBox(height: 16),
              Text('Sua galeria está vazia.',
                  style:
                      TextStyle(color: IronTheme.fgBright, fontSize: 18)),
              SizedBox(height: 8),
              Text(
                'Toque em "Adicionar" pra cadastrar um rosto. Cada cadastro fica privado e visível só pra você.',
                textAlign: TextAlign.center,
                style: TextStyle(color: IronTheme.fgDim),
              ),
            ],
          ),
        ),
      );

  Widget _faceTile(_Face f) => Container(
        decoration: BoxDecoration(
          color: IronTheme.bgElev,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: IronTheme.cyan.withOpacity(0.3)),
        ),
        child: ListTile(
          leading: ClipOval(
            child: SizedBox(
              width: 48,
              height: 48,
              child: f.photoUrl.isNotEmpty
                  ? Image.network(
                      f.photoUrl.startsWith('http')
                          ? f.photoUrl
                          : '${MultimodalApi.baseUrl}${f.photoUrl}',
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.person, color: IronTheme.cyan),
                    )
                  : const Icon(Icons.person, color: IronTheme.cyan),
            ),
          ),
          title: Text(f.name,
              style: const TextStyle(color: IronTheme.fgBright)),
          subtitle: Text('Adicionado(a) ${_fmtDate(f.createdAt)}',
              style: const TextStyle(color: IronTheme.fgDim, fontSize: 12)),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, color: IronTheme.danger),
            onPressed: () => _confirmDelete(f),
          ),
        ),
      );

  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: IronTheme.bgPanel,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: IronTheme.cyan),
              title: const Text('Tirar foto agora'),
              onTap: () {
                Navigator.pop(ctx);
                _addFromCamera();
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: IronTheme.cyan),
              title: const Text('Escolher da galeria'),
              onTap: () {
                Navigator.pop(ctx);
                _addFromGallery();
              },
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtDate(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inDays == 0) return 'hoje';
  if (diff.inDays == 1) return 'ontem';
  if (diff.inDays < 30) return '${diff.inDays}d atrás';
  return '${d.day}/${d.month}/${d.year}';
}

class _Face {
  final int id;
  final String name;
  final String photoUrl;
  final DateTime createdAt;
  _Face({
    required this.id,
    required this.name,
    required this.photoUrl,
    required this.createdAt,
  });
  factory _Face.fromJson(Map<String, dynamic> j) => _Face(
        id: (j['id'] is int)
            ? j['id'] as int
            : int.tryParse(j['id'].toString()) ?? 0,
        name: (j['name'] ?? '').toString(),
        photoUrl: (j['photo_url'] ?? '').toString(),
        createdAt:
            DateTime.tryParse((j['created_at'] ?? '').toString()) ??
                DateTime.now(),
      );
}
