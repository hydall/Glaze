import 'dart:convert';

import 'type_converters.dart';

mixin AuthorsNoteHelper on TypeConverters {
  String? extractExtensionsJson(Map<String, dynamic> char) {
    final extensions = char['extensions'] ?? char['data']?['extensions'];
    if (extensions is Map<String, dynamic> && extensions.isNotEmpty) {
      extensions.remove('gallery');
      if (extensions.isNotEmpty) return jsonEncode(extensions);
    }
    return null;
  }

  String? encodeAuthorsNote(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) {
      if (raw.isEmpty) return null;
      return jsonEncode({
        'content': raw,
        'role': 'system',
        'insertionMode': 'relative',
        'depth': 0,
        'enabled': true,
      });
    }
    if (raw is Map) {
      final content = raw['content'] is String ? raw['content'] as String : '';
      if (content.isEmpty) return null;
      return jsonEncode({
        'content': content,
        'role': raw['role'] is String ? raw['role'] as String : 'system',
        'insertionMode': (raw['insertion_mode'] is String
                    ? raw['insertion_mode'] as String
                    : null) ??
            (raw['insertionMode'] is String
                    ? raw['insertionMode'] as String
                    : null) ??
            'relative',
        'depth': toInt(raw['depth']) ?? 0,
        'enabled': raw['enabled'] is bool ? raw['enabled'] as bool : true,
      });
    }
    return null;
  }
}
