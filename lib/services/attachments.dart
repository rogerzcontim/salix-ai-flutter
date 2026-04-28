import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// Thin facade over file_picker + image_picker so the chat page doesn't
/// need to know about plugin specifics.
class AttachmentsService {
  final ImagePicker _imagePicker = ImagePicker();

  /// Opens the document picker. Returns a local file path or null if the user
  /// cancelled. Filtered to common doc types we know how to extract.
  Future<String?> pickDocument() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'pdf', 'docx', 'xlsx', 'txt', 'csv',
        'png', 'jpg', 'jpeg',
      ],
      withData: false,
      allowMultiple: false,
    );
    if (res == null || res.files.isEmpty) return null;
    final path = res.files.single.path;
    if (path == null) return null;
    if (!await File(path).exists()) return null;
    return path;
  }

  /// Opens the camera and returns the captured photo path, or null if
  /// permission was denied or the user backed out.
  Future<String?> capturePhoto() async {
    final cam = await Permission.camera.request();
    if (!cam.isGranted) return null;
    final XFile? shot = await _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 2400,
      maxHeight: 2400,
    );
    return shot?.path;
  }

  /// Opens the gallery and returns the picked image path.
  Future<String?> pickImage() async {
    final XFile? shot = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    return shot?.path;
  }
}
