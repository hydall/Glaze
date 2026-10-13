import 'dart:convert';
import 'dart:typed_data';

import 'api/files_api.dart';

typedef PluginFileReader =
    Future<Uint8List?> Function(String pluginId, String path);

final _scriptSrc = RegExp(
  r'''<script\b([^>]*?)\bsrc\s*=\s*["']/plugins/([a-z0-9._-]+)/([^"']+)["']([^>]*)>\s*</script>''',
  caseSensitive: false,
);
final _stylesheet = RegExp(
  r'''<link\b[^>]*?\bhref\s*=\s*["']/plugins/([a-z0-9._-]+)/([^"']+\.css)["'][^>]*>''',
  caseSensitive: false,
);
final _assetRef = RegExp(r'''(["'(])/plugins/([a-z0-9._-]+)/([^"')\s]+)''');

/// Plugin frames have an opaque origin, so `/plugins/<id>/<path>` URLs
/// cannot be served to them. Package scripts and stylesheets are inlined and
/// other assets become data URLs, read from the installed packages.
Future<String> inlinePluginAssets(String html, PluginFileReader read) async {
  var out = await _replaceAsync(html, _scriptSrc, (m) async {
    final bytes = await read(m.group(2)!, Uri.decodeFull(m.group(3)!));
    if (bytes == null) {
      return '<script>console.error("[glaze] missing ${m.group(3)}")</script>';
    }
    final attrs = '${m.group(1)}${m.group(4)}'.replaceAll(
      RegExp(r'\b(async|defer)\b', caseSensitive: false),
      '',
    );
    final source = utf8
        .decode(bytes, allowMalformed: true)
        .replaceAll(RegExp('</script', caseSensitive: false), r'<\/script');
    return '<script$attrs>$source</script>';
  });
  out = await _replaceAsync(out, _stylesheet, (m) async {
    final bytes = await read(m.group(1)!, Uri.decodeFull(m.group(2)!));
    if (bytes == null) return '';
    final css = await inlinePluginAssets(
      utf8.decode(bytes, allowMalformed: true),
      read,
    );
    return '<style>$css</style>';
  });
  return _replaceAsync(out, _assetRef, (m) async {
    final path = Uri.decodeFull(m.group(3)!);
    final bytes = await read(m.group(2)!, path);
    if (bytes == null) return m.group(0)!;
    return '${m.group(1)}data:${pluginMimeType(path)};base64,${base64Encode(bytes)}';
  });
}

Future<String> _replaceAsync(
  String input,
  RegExp pattern,
  Future<String> Function(Match m) replace,
) async {
  final buffer = StringBuffer();
  var last = 0;
  for (final m in pattern.allMatches(input)) {
    buffer
      ..write(input.substring(last, m.start))
      ..write(await replace(m));
    last = m.end;
  }
  buffer.write(input.substring(last));
  return buffer.toString();
}
