import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

/// Result of a successful upload to /api/tools/upload.
class UploadResult {
  final String fileId;
  final String url;
  final String extractedText;
  final String fileName;
  final int? pages;
  final String? mime;

  UploadResult({
    required this.fileId,
    required this.url,
    required this.extractedText,
    required this.fileName,
    this.pages,
    this.mime,
  });

  factory UploadResult.fromJson(Map<String, dynamic> j, {String? fallbackName}) {
    return UploadResult(
      fileId: (j['file_id'] ?? j['id'] ?? '').toString(),
      url: (j['url'] ?? '').toString(),
      extractedText: (j['extracted_text'] ?? j['text'] ?? '').toString(),
      fileName: (j['name'] ?? j['filename'] ?? fallbackName ?? 'arquivo').toString(),
      pages: (j['pages'] is int) ? j['pages'] as int : null,
      mime: j['mime']?.toString(),
    );
  }
}

/// Posts files (PDF/DOCX/XLSX/image) and camera captures to the server-side
/// extractor. Server handles parsing + Tesseract OCR for images.
class UploadService {
  static const baseUrl = 'https://ironedgeai.com';
  static const endpoint = '$baseUrl/api/tools/upload';

  /// [path] is a local file path. [kind] is a free hint for the server
  /// (`document` | `image`). Returns parsed [UploadResult] on HTTP 2xx.
  Future<UploadResult> upload({
    required String path,
    String kind = 'document',
    String? authToken,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('Arquivo não encontrado: $path');
    }
    final fileName = path.split(Platform.pathSeparator).last;
    final req = http.MultipartRequest('POST', Uri.parse(endpoint));
    if (authToken != null) {
      req.headers['Authorization'] = 'Bearer $authToken';
    }
    req.fields['kind'] = kind;
    req.fields['client'] = 'salix_ai_flutter/1.2.0';
    req.files.add(await http.MultipartFile.fromPath(
      'file',
      path,
      contentType: _guessContentType(fileName),
      filename: fileName,
    ));

    final streamed = await req.send().timeout(const Duration(seconds: 120));
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw Exception(
          'Upload falhou (HTTP ${streamed.statusCode}): ${body.length > 200 ? body.substring(0, 200) : body}');
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Resposta inválida do servidor: ${body.length > 120 ? body.substring(0, 120) : body}');
    }
    return UploadResult.fromJson(json, fallbackName: fileName);
  }

  MediaType? _guessContentType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return MediaType('application', 'pdf');
    if (lower.endsWith('.docx')) {
      return MediaType('application',
          'vnd.openxmlformats-officedocument.wordprocessingml.document');
    }
    if (lower.endsWith('.xlsx')) {
      return MediaType('application',
          'vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    }
    if (lower.endsWith('.png')) return MediaType('image', 'png');
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return MediaType('image', 'jpeg');
    }
    if (lower.endsWith('.txt')) return MediaType('text', 'plain');
    return null; // let http guess
  }
}
