import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../plugin_api.dart';
import 'files_api.dart';

/// Upper bound on references accepted from one plugin call. The provider's
/// own cap still applies later; this only keeps a bad list from downloading
/// and decoding forever.
const int _maxPluginImageReferences = 10;

/// Turns the `referenceImages` / `characters` option of
/// `glaze.images.generate` into the flat maps the chat image pipeline uses.
///
/// Entries may be strings (`data:` URLs, plugin `files/...` paths, HTTP(S)
/// URLs, or bare base64) or maps with `url` / `data` / `image` and an optional
/// `name` / `description`. Downloads go through the plugin's own network
/// policy and request log, so a plugin cannot use this to reach a host it
/// could not reach itself.
Future<List<Map<String, String>>> resolvePluginImageReferences(
  PluginCall call,
  Object? raw,
) async {
  if (raw is! List || raw.isEmpty) return const [];

  final out = <Map<String, String>>[];
  final seenImages = <String>{};
  final seenSources = <String>{};

  for (final item in raw) {
    if (out.length >= _maxPluginImageReferences) break;
    final source = _sourceOf(item);
    if (source == null) continue;
    if (source.value.isNotEmpty && !seenSources.add(source.value)) continue;

    final resolved = await _resolve(call, source);
    if (resolved == null) continue;
    if (!seenImages.add(resolved['image']!)) continue;
    out.add(resolved);
  }
  return out;
}

typedef _ReferenceSource = ({String value, String name, String description});

_ReferenceSource? _sourceOf(Object? item) {
  if (item is String) {
    final value = item.trim();
    if (value.isEmpty) return null;
    return (value: value, name: '', description: '');
  }
  if (item is! Map) return null;

  final map = Map<Object?, Object?>.from(item);
  String text(Object? key) =>
      map[key] is String ? (map[key] as String).trim() : '';

  String firstText(List<String> keys) {
    for (final key in keys) {
      final value = text(key);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  final value = firstText([
    'url',
    'src',
    'image_url',
    'dataUrl',
    'data_url',
    'data',
    'image',
  ]);
  if (value.isEmpty) return null;

  final name = _oneLine(firstText(['name', 'label', 'id']));
  final description = _oneLine(
    firstText(['description', 'caption', 'label']).isEmpty
        ? name
        : firstText(['description', 'caption', 'label']),
  );
  return (
    value: value,
    name: name,
    description: description.isEmpty ? name : description,
  );
}

Future<Map<String, String>?> _resolve(
  PluginCall call,
  _ReferenceSource source,
) async {
  final value = source.value;
  try {
    if (value.startsWith('data:')) {
      final data = UriData.parse(value);
      return _fromBytes(
        data.contentAsBytes(),
        name: source.name,
        description: source.description,
      );
    }
    if (value.startsWith('files/')) {
      final bytes = await readPluginFile(call, value);
      return _fromBytes(
        bytes,
        name: source.name,
        description: source.description,
      );
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      final bytes = await fetchForPlugin(call, value);
      return _fromBytes(
        bytes,
        name: source.name,
        description: source.description,
      );
    }
    // A bare base64 reference, as some Tavo plugins store pasted avatars.
    final bytes = base64Decode(value);
    return _fromBytes(
      bytes,
      name: source.name,
      description: source.description,
    );
  } catch (e) {
    // One unreadable avatar must not stop the picture: the rest still go.
    debugPrint('[plugin image ref] skipped $value: $e');
    return null;
  }
}

Map<String, String>? _fromBytes(
  Uint8List bytes, {
  required String name,
  required String description,
}) {
  if (bytes.isEmpty) return null;
  final mime = _imageMime(bytes);
  if (mime == null) return null;
  final cleanName = _oneLine(name).isEmpty ? 'reference' : _oneLine(name);
  final cleanDescription = _oneLine(description).isEmpty
      ? cleanName
      : _oneLine(description);
  return {
    'name': cleanName,
    'image': base64Encode(bytes),
    'mime': mime,
    'description': cleanDescription,
    'source': 'additional',
  };
}

String _oneLine(String value) =>
    value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();

String? _imageMime(Uint8List bytes) {
  if (bytes.length > 3 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return 'image/jpeg';
  }
  if (bytes.length > 11 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  if (bytes.length > 3 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'image/gif';
  }
  return null;
}
