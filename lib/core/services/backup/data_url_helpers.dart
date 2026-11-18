import 'dart:typed_data';

import 'package:path/path.dart' as p;

mixin DataUrlHelpers {
  Uint8List? dataUrlToBytes(String dataUrl) {
    final commaIndex = dataUrl.indexOf(',');
    if (commaIndex == -1) return null;
    final base64Str = dataUrl.substring(commaIndex + 1);
    try {
      return Uint8List.fromList(
          Uri.parse('data:;base64,$base64Str').data!.contentAsBytes());
    } catch (_) {
      return null;
    }
  }

  String dataUrlMime(String dataUrl) {
    final end = dataUrl.indexOf(';');
    if (end == -1) return '';
    return dataUrl.substring(5, end);
  }

  String extFromEntry(Map<String, dynamic>? entry) {
    final path = entry?['imagePath'] as String?;
    if (path != null) {
      final ext = p.extension(path).replaceFirst('.', '');
      if (ext.isNotEmpty) return ext;
    }
    return 'png';
  }
}
