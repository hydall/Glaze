import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

String computeHash(String input) {
  return sha256.convert(utf8.encode(input)).toString();
}

Uint8List? dataUrlToBytes(String dataUrl) {
  if (!dataUrl.startsWith('data:')) return null;
  final commaIndex = dataUrl.indexOf(',');
  if (commaIndex == -1) return null;
  final base64Str = dataUrl.substring(commaIndex + 1);
  try {
    return base64Decode(base64Str);
  } catch (_) {
    return null;
  }
}

List<String> toStringList(dynamic value) {
  if (value is List) return value.map((e) => e.toString()).toList();
  if (value is String && value.isNotEmpty) {
    return value
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
  return [];
}

Map<String, dynamic> extractExtensionsJson(Map<String, dynamic> data) {
  final ext = data['extensions'] is Map ? data['extensions'] as Map : null;
  if (ext == null || ext.isEmpty) return {};
  final copy = Map<String, dynamic>.from(ext);
  copy.remove('gallery');
  return copy;
}
