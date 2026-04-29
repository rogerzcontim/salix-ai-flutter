// SALIX Onda 5 — region_selector_page.dart
// Path inside Flutter project: lib/pages/region_selector_page.dart
//
// Drop-in screen that loads an uploaded image (by URL) and lets the user
// drag a rectangular region with a finger / mouse. Returns a Region
// (percentages 0..100) via Navigator.pop. The caller (ChatPage) wires the
// result into a /api/tools/analyze_region or /api/tools/ocr_region call.
//
// No new dependencies — uses dart:ui + GestureDetector + Image.network
// already in the pubspec.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../theme.dart';

class Region {
  final double xPct;
  final double yPct;
  final double wPct;
  final double hPct;
  const Region({
    required this.xPct,
    required this.yPct,
    required this.wPct,
    required this.hPct,
  });
  Map<String, dynamic> toJson() => {
        'x_pct': xPct,
        'y_pct': yPct,
        'w_pct': wPct,
        'h_pct': hPct,
      };
}

enum RegionAction { describe, ocr, plantId, birdId, landmarkId }

class RegionSelectorPage extends StatefulWidget {
  /// Absolute or relative URL of the uploaded image. The widget prepends
  /// `https://ironedgeai.com` when a relative path comes in (e.g. `/uploads/foo.jpg`).
  final String imageUrl;
  final String fileId;
  const RegionSelectorPage({
    super.key,
    required this.imageUrl,
    required this.fileId,
  });

  @override
  State<RegionSelectorPage> createState() => _RegionSelectorPageState();
}

class _RegionSelectorPageState extends State<RegionSelectorPage> {
  Offset? _start;
  Offset? _end;
  Size? _imageSize; // intrinsic size, used for aspect ratio
  final _question = TextEditingController(
    text: 'Descreva o que aparece nessa região.',
  );

  String _resolveUrl() {
    final u = widget.imageUrl;
    if (u.startsWith('http')) return u;
    return 'https://ironedgeai.com$u';
  }

  @override
  Widget build(BuildContext context) {
    final url = _resolveUrl();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Selecionar região'),
        actions: [
          IconButton(
            tooltip: 'Limpar seleção',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {
              _start = null;
              _end = null;
            }),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                return Center(
                  child: _ImageCanvas(
                    url: url,
                    constraints: constraints,
                    start: _start,
                    end: _end,
                    onIntrinsicSize: (s) {
                      if (_imageSize == null) {
                        setState(() => _imageSize = s);
                      }
                    },
                    onPanStart: (Offset p) =>
                        setState(() {
                          _start = p;
                          _end = p;
                        }),
                    onPanUpdate: (Offset p) =>
                        setState(() => _end = p),
                  ),
                );
              },
            ),
          ),
          _bottomBar(context),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext ctx) {
    final hasRegion = _start != null && _end != null && _start != _end;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        color: IronTheme.bgPanel,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _question,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'O que perguntar sobre a região…',
                hintStyle: const TextStyle(color: IronTheme.fgDim),
                filled: true,
                fillColor: IronTheme.bgElev,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _actionChip(ctx, 'Descrever', Icons.psychology,
                    RegionAction.describe, hasRegion),
                _actionChip(ctx, 'OCR (texto)', Icons.text_snippet,
                    RegionAction.ocr, hasRegion),
                _actionChip(ctx, 'Que planta?', Icons.local_florist,
                    RegionAction.plantId, true), // plant_id uses full image
                _actionChip(ctx, 'Que ave?', Icons.cruelty_free,
                    RegionAction.birdId, true),
                _actionChip(ctx, 'Que lugar?', Icons.place,
                    RegionAction.landmarkId, true),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionChip(BuildContext ctx, String label, IconData icon,
      RegionAction action, bool enabled) {
    return ActionChip(
      avatar: Icon(icon,
          size: 18,
          color: enabled ? IronTheme.cyan : IronTheme.fgDim),
      label: Text(label,
          style: TextStyle(
              color: enabled ? IronTheme.fgBright : IronTheme.fgDim)),
      backgroundColor:
          enabled ? IronTheme.bgElev : IronTheme.bgElev.withOpacity(0.3),
      side: BorderSide(
          color: enabled ? IronTheme.cyan : IronTheme.fgDim, width: 1),
      onPressed: enabled
          ? () {
              final r = _computePctRegion();
              Navigator.of(ctx).pop(_RegionSelectorResult(
                action: action,
                region: r,
                question: _question.text.trim(),
              ));
            }
          : null,
    );
  }

  /// Converts the canvas-space [_start, _end] rectangle into image-space
  /// percentages. Falls back to "full image" (0,0,100,100) when no
  /// selection exists, so plant/bird/landmark actions still work.
  Region? _computePctRegion() {
    if (_start == null || _end == null) {
      return const Region(xPct: 0, yPct: 0, wPct: 100, hPct: 100);
    }
    final s = _start!;
    final e = _end!;
    final left = math.min(s.dx, e.dx);
    final top = math.min(s.dy, e.dy);
    final right = math.max(s.dx, e.dx);
    final bottom = math.max(s.dy, e.dy);
    // _ImageCanvas reports coordinates already normalized to image space
    // (we pass 0..1 floats via the gesture callbacks).
    return Region(
      xPct: (left * 100).clamp(0, 100).toDouble(),
      yPct: (top * 100).clamp(0, 100).toDouble(),
      wPct: ((right - left) * 100).clamp(0, 100).toDouble(),
      hPct: ((bottom - top) * 100).clamp(0, 100).toDouble(),
    );
  }
}

/// What the page returns to the chat.
class _RegionSelectorResult {
  final RegionAction action;
  final Region? region;
  final String question;
  _RegionSelectorResult({
    required this.action,
    required this.region,
    required this.question,
  });
}

/// Image rendered to fit the available constraints, with an overlay rect
/// painted on top of it. All gesture coordinates are normalized to 0..1
/// in image space (so the parent can convert directly to percentages).
class _ImageCanvas extends StatefulWidget {
  final String url;
  final BoxConstraints constraints;
  final Offset? start;
  final Offset? end;
  final void Function(Size) onIntrinsicSize;
  final void Function(Offset) onPanStart;
  final void Function(Offset) onPanUpdate;
  const _ImageCanvas({
    required this.url,
    required this.constraints,
    required this.start,
    required this.end,
    required this.onIntrinsicSize,
    required this.onPanStart,
    required this.onPanUpdate,
  });

  @override
  State<_ImageCanvas> createState() => _ImageCanvasState();
}

class _ImageCanvasState extends State<_ImageCanvas> {
  Size? _imgSize;
  late Image _img;

  @override
  void initState() {
    super.initState();
    _img = Image.network(widget.url, fit: BoxFit.contain);
    final stream = _img.image.resolve(const ImageConfiguration());
    stream.addListener(ImageStreamListener((info, _) {
      if (!mounted) return;
      final s = Size(info.image.width.toDouble(), info.image.height.toDouble());
      setState(() => _imgSize = s);
      widget.onIntrinsicSize(s);
    }, onError: (e, st) {
      // image failed; nothing to do, GestureDetector still works on placeholder.
    }));
  }

  @override
  Widget build(BuildContext context) {
    final imgSize = _imgSize;
    if (imgSize == null) {
      return const SizedBox(
        width: 64,
        height: 64,
        child: CircularProgressIndicator(color: IronTheme.cyan),
      );
    }
    // Compute the size at which the image is rendered inside constraints
    // with BoxFit.contain.
    final cw = widget.constraints.maxWidth;
    final ch = widget.constraints.maxHeight;
    final imgAspect = imgSize.width / imgSize.height;
    final boxAspect = cw / ch;
    double rW, rH;
    if (imgAspect > boxAspect) {
      rW = cw;
      rH = cw / imgAspect;
    } else {
      rH = ch;
      rW = ch * imgAspect;
    }
    return SizedBox(
      width: rW,
      height: rH,
      child: GestureDetector(
        onPanStart: (d) => widget.onPanStart(_norm(d.localPosition, rW, rH)),
        onPanUpdate: (d) => widget.onPanUpdate(_norm(d.localPosition, rW, rH)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _img,
            CustomPaint(
              painter: _RegionPainter(
                start: widget.start,
                end: widget.end,
                renderW: rW,
                renderH: rH,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Offset _norm(Offset p, double w, double h) {
    return Offset(
      (p.dx / w).clamp(0.0, 1.0),
      (p.dy / h).clamp(0.0, 1.0),
    );
  }
}

class _RegionPainter extends CustomPainter {
  final Offset? start;
  final Offset? end;
  final double renderW;
  final double renderH;
  _RegionPainter({
    required this.start,
    required this.end,
    required this.renderW,
    required this.renderH,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (start == null || end == null) return;
    final s = Offset(start!.dx * renderW, start!.dy * renderH);
    final e = Offset(end!.dx * renderW, end!.dy * renderH);
    final r = Rect.fromPoints(s, e);
    // Dim outside.
    final dim = Paint()..color = const Color(0x80000000);
    final dimPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dimPath, dim);
    // Stroke the region.
    final stroke = Paint()
      ..color = IronTheme.cyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawRect(r, stroke);
    // Corner handles.
    final handle = Paint()..color = IronTheme.cyan;
    const hs = 6.0;
    for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawRect(Rect.fromCenter(center: c, width: hs, height: hs), handle);
    }
  }

  @override
  bool shouldRepaint(covariant _RegionPainter old) =>
      old.start != start || old.end != end;
}

// =====================================================================
// Public helper used by ChatPage.
// =====================================================================

/// Shows the region selector and dispatches the chosen action by calling
/// the matching /api/tools/* endpoint. Returns the assistant-friendly
/// summary string the chat should append, or null if the user backed out.
Future<MultimodalResult?> showRegionSelectorAndAct({
  required BuildContext context,
  required String imageUrl,
  required String fileId,
  String? authToken,
}) async {
  final result = await Navigator.of(context).push<_RegionSelectorResult>(
    MaterialPageRoute(
      builder: (_) => RegionSelectorPage(imageUrl: imageUrl, fileId: fileId),
    ),
  );
  if (result == null || result.region == null) return null;

  final api = MultimodalApi();
  switch (result.action) {
    case RegionAction.describe:
      return api.analyzeRegion(
        fileId: fileId,
        region: result.region!,
        question: result.question,
        authToken: authToken,
      );
    case RegionAction.ocr:
      return api.ocrRegion(
        fileId: fileId,
        region: result.region!,
        authToken: authToken,
      );
    case RegionAction.plantId:
      return api.plantId(fileId: fileId, authToken: authToken);
    case RegionAction.birdId:
      return api.birdId(fileId: fileId, authToken: authToken);
    case RegionAction.landmarkId:
      return api.landmarkId(fileId: fileId, authToken: authToken);
  }
}

// =====================================================================
// Thin client for Onda 5 endpoints. Mirrors UploadService style.
// =====================================================================

class MultimodalResult {
  final bool ok;
  final String? answer;
  final String? text; // for OCR
  final String? cropUrl;
  final String? error;
  final Map<String, dynamic> raw;
  MultimodalResult({
    required this.ok,
    this.answer,
    this.text,
    this.cropUrl,
    this.error,
    required this.raw,
  });

  /// Best human summary for chat injection.
  String summary() {
    if (!ok) return 'Erro: ${error ?? "desconhecido"}';
    if (text != null && text!.isNotEmpty) return 'Texto extraído:\n$text';
    if (answer != null && answer!.isNotEmpty) return answer!;
    return 'Operação concluída.';
  }
}

class MultimodalApi {
  static const baseUrl = 'https://ironedgeai.com';

  Future<MultimodalResult> _post(
    String path,
    Map<String, dynamic> body,
    String? authToken,
  ) async {
    final r = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: {
        'content-type': 'application/json',
        if (authToken != null) 'authorization': 'Bearer $authToken',
      },
      body: _encode(body),
    ).timeout(const Duration(seconds: 90));
    final j = _safeJson(r.body);
    return MultimodalResult(
      ok: (j['ok'] ?? false) == true,
      answer: j['answer']?.toString(),
      text: j['text']?.toString(),
      cropUrl: j['crop_url']?.toString(),
      error: j['error']?.toString(),
      raw: j,
    );
  }

  Future<MultimodalResult> analyzeRegion({
    required String fileId,
    required Region region,
    required String question,
    String? authToken,
  }) =>
      _post('/api/tools/analyze_region', {
        'file_id': fileId,
        'region': region.toJson(),
        'question': question,
      }, authToken);

  Future<MultimodalResult> ocrRegion({
    required String fileId,
    required Region region,
    String lang = 'por',
    String? authToken,
  }) =>
      _post('/api/tools/ocr_region', {
        'file_id': fileId,
        'region': region.toJson(),
        'lang': lang,
      }, authToken);

  Future<MultimodalResult> plantId({
    required String fileId,
    String? hint,
    String? authToken,
  }) =>
      _post('/api/tools/plant_id', {
        'file_id': fileId,
        if (hint != null) 'hint': hint,
      }, authToken);

  Future<MultimodalResult> birdId({
    required String fileId,
    String? hint,
    String? authToken,
  }) =>
      _post('/api/tools/bird_id', {
        'file_id': fileId,
        if (hint != null) 'hint': hint,
      }, authToken);

  Future<MultimodalResult> landmarkId({
    required String fileId,
    String? hint,
    String? authToken,
  }) =>
      _post('/api/tools/landmark_id', {
        'file_id': fileId,
        if (hint != null) 'hint': hint,
      }, authToken);

  Future<MultimodalResult> whiteboardToMd({
    required String fileId,
    String lang = 'por+eng',
    String? authToken,
  }) =>
      _post('/api/tools/whiteboard_to_md', {
        'file_id': fileId,
        'lang': lang,
      }, authToken);

  Future<MultimodalResult> codeFromImage({
    required String fileId,
    String? authToken,
  }) =>
      _post('/api/tools/code_from_image', {
        'file_id': fileId,
      }, authToken);

  Future<MultimodalResult> ragIndex({
    required String fileId,
    String? authToken,
  }) =>
      _post('/api/tools/rag_index', {
        'file_id': fileId,
      }, authToken);

  Future<MultimodalResult> ragQuery({
    required String fileId,
    required String question,
    int topK = 6,
    String? authToken,
  }) =>
      _post('/api/tools/rag_query', {
        'file_id': fileId,
        'question': question,
        'top_k': topK,
      }, authToken);
}

String _encode(Map<String, dynamic> m) => jsonEncode(m);

Map<String, dynamic> _safeJson(String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map<String, dynamic>) return j;
    if (j is Map) return Map<String, dynamic>.from(j);
  } catch (_) {}
  return {
    'ok': false,
    'error':
        'invalid response: ${body.length > 200 ? body.substring(0, 200) : body}',
  };
}
