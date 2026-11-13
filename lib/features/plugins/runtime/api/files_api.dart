import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../../core/utils/id_generator.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import '../plugin_file_store.dart';
import '../plugin_network.dart';
import '../plugin_request_capture.dart';

/// Per-file size cap for `glaze.files.save`.
const int kPluginFileMaxBytes = 32 * 1024 * 1024;

/// `glaze.files.*` (the plugin's own files) and the `localStorage` shim
/// (`storage.*`).
Map<String, PluginMethod> filesApi() => {
  'files.list': const PluginMethod(_list, permission: _p),
  'files.save': const PluginMethod(_save, permission: _p),
  'files.load': const PluginMethod(_load, permission: _p),
  'files.remove': const PluginMethod(_remove, permission: _p),
  'files.exists': const PluginMethod(_exists, permission: _p),
  'files.pick': const PluginMethod(_pick, permission: _p),
  'files.share': const PluginMethod(_share, permission: _p),
  'files.dataUrl': const PluginMethod(_dataUrl, permission: _p),
  'storage.set': const PluginMethod(_storageSet),
  'storage.remove': const PluginMethod(_storageRemove),
  'storage.clear': const PluginMethod(_storageClear),
};

const _p = PluginPermission.files;

const _mimeByExtension = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'svg': 'image/svg+xml',
  'mp3': 'audio/mpeg',
  'ogg': 'audio/ogg',
  'wav': 'audio/wav',
  'mp4': 'video/mp4',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'json': 'application/json',
  'jsonl': 'application/jsonl',
  'html': 'text/html',
  'htm': 'text/html',
  'css': 'text/css',
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'wasm': 'application/wasm',
  'woff2': 'font/woff2',
  'woff': 'font/woff',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'avif': 'image/avif',
  'ico': 'image/x-icon',
  'webm': 'video/webm',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
};

String pluginMimeType(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return _mimeByExtension[ext] ?? 'application/octet-stream';
}

String? _scopeOption(PluginCall c, int index) {
  final scope = c.mapArg(index)['scope'];
  return scope is String ? scope : null;
}

/// The file behind a name or virtual path in [c]'s plugin data.
({File file, String virtualPath}) pluginFile(
  PluginCall c,
  String nameOrPath, {
  String? scope,
}) => c.host
    .files(c.plugin.id)
    .resolve(nameOrPath, scope: scope, sessionId: c.host.sessionId);

/// Writes [bytes] into the plugin's files and describes the result.
Future<Map<String, Object?>> savePluginFile(
  PluginCall c,
  String name,
  List<int> bytes, {
  String? scope,
}) async {
  if (bytes.length > kPluginFileMaxBytes) {
    throw const PluginApiError('too_large', 'The file is too large');
  }
  final target = pluginFile(c, name, scope: scope);
  final store = c.host.files(c.plugin.id);
  final replaced = await target.file.exists() ? await target.file.length() : 0;
  if (await store.usedBytes() - replaced + bytes.length >
      PluginFileStore.maxFilesBytes) {
    throw const PluginApiError(
      'quota_exceeded',
      'The plugin has used up its file storage',
    );
  }
  await target.file.parent.create(recursive: true);
  await target.file.writeAsBytes(bytes, flush: true);
  return _describe(target.file, target.virtualPath);
}

/// Reads a plugin file by name or virtual path; throws when it is missing.
Future<Uint8List> readPluginFile(PluginCall c, String nameOrPath) async {
  final target = pluginFile(c, nameOrPath);
  if (!await target.file.exists()) {
    throw PluginApiError('not_found', 'No file $nameOrPath');
  }
  return target.file.readAsBytes();
}

/// A file-safe name for exports.
String safeFileName(String name, String fallback) {
  final cleaned = name
      .replaceAll(RegExp(r'[/\\?%*:|"<>]'), '-')
      .replaceAll('..', '-')
      .trim();
  return cleaned.isEmpty ? fallback : cleaned;
}

Future<Map<String, Object?>> _describe(File f, String virtualPath) async {
  final stat = await f.stat();
  final name = f.uri.pathSegments.last;
  return {
    'path': virtualPath,
    'name': name,
    'size': stat.size,
    'mimeType': pluginMimeType(name),
    'modifiedAt': stat.modified.toUtc().toIso8601String(),
  };
}

Future<Object?> _list(PluginCall c) async {
  final options = c.mapArg(0);
  final scope = options['scope'] is String
      ? options['scope'] as String
      : 'chat';
  final limit =
      (options['limit'] is num ? (options['limit'] as num).toInt() : 100).clamp(
        1,
        200,
      );
  final offset = int.tryParse('${options['cursor'] ?? 0}') ?? 0;
  final dir = c.host.files(c.plugin.id).scopeDir(scope, c.host.sessionId);
  if (!await dir.exists()) return {'files': <Object>[]};
  final entries = await dir.list().where((e) => e is File).cast<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final page = entries.skip(offset).take(limit);
  return {
    'files': [
      for (final f in page)
        await _describe(f, 'files/$scope/${f.uri.pathSegments.last}'),
    ],
    if (offset + limit < entries.length) 'nextCursor': '${offset + limit}',
  };
}

Future<Uint8List> decodePluginContent(
  PluginCall c,
  Object? content,
  String? encoding,
) async {
  if (content is List) return Uint8List.fromList(content.cast<int>());
  if (content is! String) {
    throw const PluginApiError(
      'invalid_arguments',
      'File content must be a string',
    );
  }
  switch (encoding) {
    case 'base64':
      return base64Decode(content);
    case 'dataUrl':
      return UriData.parse(content).contentAsBytes();
    case 'utf8':
      return utf8.encode(content);
  }
  if (content.startsWith('data:')) {
    return UriData.parse(content).contentAsBytes();
  }
  if (content.startsWith('http://') || content.startsWith('https://')) {
    return fetchForPlugin(c, content);
  }
  return utf8.encode(content);
}

/// Downloads [url] for the calling plugin, which needs internet access to
/// its host, and to every host a redirect leads to; each attempt goes into
/// the plugin's network log either way. Without local network access hosts
/// that are or resolve to local addresses are refused. The body is capped at
/// [kPluginFileMaxBytes] while it streams in. The download shows in the
/// chat's requests like the plugin's other requests.
Future<Uint8List> fetchForPlugin(PluginCall c, String url) async {
  final capture = pluginRequestContext(
    pluginId: c.plugin.id,
    sessionId: c.host.sessionId,
    requestId: 'download:${generateId()}',
    method: 'GET',
    url: Uri.tryParse(url),
  );
  recordPluginRequest(capture, method: 'GET', url: url, via: 'download');
  try {
    final (:bytes, :status, :type) = await _download(c, url);
    recordPluginResponse(
      capture,
      status: status,
      body: '[${type ?? 'data'}, ${bytes.length} bytes]',
    );
    return bytes;
  } on PluginApiError catch (e) {
    recordPluginResponse(capture, error: '${e.code}: ${e.message}');
    rethrow;
  } catch (e) {
    recordPluginResponse(capture, error: '$e');
    rethrow;
  }
}

Future<({Uint8List bytes, int status, String? type})> _download(
  PluginCall c,
  String url,
) async {
  var uri = Uri.tryParse(url);
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      followRedirects: false,
      validateStatus: (_) => true,
      responseType: ResponseType.stream,
    ),
  );
  try {
    for (var hop = 0; ; hop++) {
      if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
        throw const PluginApiError('invalid_arguments', 'Only http(s) URLs');
      }
      if (hop > 5) {
        throw const PluginApiError('network_error', 'Too many redirects');
      }
      await requirePluginHost(c, uri);
      final response = await dio.getUri<ResponseBody>(uri);
      final status = response.statusCode ?? 0;
      final location = response.headers.value('location');
      if (status >= 300 && status < 400 && location != null) {
        uri = uri.resolve(location);
        continue;
      }
      if (status < 200 || status >= 300) {
        throw PluginApiError('network_error', 'HTTP $status from ${uri.host}');
      }
      final declared = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (declared != null && declared > kPluginFileMaxBytes) {
        throw const PluginApiError('too_large', 'The file is too large');
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        out.add(chunk);
        if (out.length > kPluginFileMaxBytes) {
          throw const PluginApiError('too_large', 'The file is too large');
        }
      }
      return (
        bytes: out.takeBytes(),
        status: status,
        type: response.headers.value('content-type')?.split(';').first,
      );
    }
  } finally {
    // Also drops the bodies of redirects and refused responses.
    dio.close(force: true);
  }
}

/// Lets the calling plugin reach [uri]'s host, logging the attempt; throws
/// `permission_denied` when it may not.
Future<void> requirePluginHost(PluginCall c, Uri uri) async {
  final host = uri.host.toLowerCase();
  final allowed =
      c.plugin.allowsHost(host) &&
      (c.plugin.localNetwork || !await isLocalNetworkHost(host));
  c.host.networkUsed(c.plugin.id, host, blocked: !allowed);
  if (!allowed) {
    throw PluginApiError('permission_denied', 'The plugin may not reach $host');
  }
}

Future<Object?> _save(PluginCall c) async {
  final options = c.mapArg(2);
  final bytes = await decodePluginContent(
    c,
    c.arg(1),
    options['encoding'] as String?,
  );
  final info = await savePluginFile(
    c,
    c.requireString(0, 'name'),
    bytes,
    scope: _scopeOption(c, 2),
  );
  return info['path'];
}

Object encodePluginContent(Uint8List bytes, String? encoding, String name) {
  switch (encoding) {
    case 'base64':
      return base64Encode(bytes);
    case 'dataUrl':
      return 'data:${pluginMimeType(name)};base64,${base64Encode(bytes)}';
    case 'bytes':
      return bytes.toList();
    default:
      return utf8.decode(bytes, allowMalformed: true);
  }
}

Future<Object?> _load(PluginCall c) async {
  final target = pluginFile(
    c,
    c.requireString(0, 'name'),
    scope: _scopeOption(c, 1),
  );
  if (!await target.file.exists()) return null;
  return encodePluginContent(
    await target.file.readAsBytes(),
    c.mapArg(1)['encoding'] as String?,
    target.file.path,
  );
}

Future<Object?> _dataUrl(PluginCall c) async {
  final target = pluginFile(c, c.requireString(0, 'path'));
  if (!await target.file.exists()) return null;
  return encodePluginContent(
    await target.file.readAsBytes(),
    'dataUrl',
    target.file.path,
  );
}

Future<Object?> _remove(PluginCall c) async {
  final target = pluginFile(
    c,
    c.requireString(0, 'name'),
    scope: _scopeOption(c, 1),
  );
  if (await target.file.exists()) await target.file.delete();
  return null;
}

Future<Object?> _exists(PluginCall c) async => pluginFile(
  c,
  c.requireString(0, 'name'),
  scope: _scopeOption(c, 1),
).file.exists();

Future<Object?> _pick(PluginCall c) async {
  final options = c.mapArg(0);
  final extensions = options['extensions'] is List
      ? [
          for (final e in options['extensions'] as List)
            '$e'.replaceAll('.', ''),
        ]
      : null;
  final picked = await c.host.ui.pickFiles(
    multiple: options['multiple'] == true,
    extensions: extensions,
  );
  final scope = options['scope'] is String ? options['scope'] as String : null;
  final conflict = options['conflict'] ?? 'rename';
  final out = <Map<String, Object?>>[];
  for (final f in picked) {
    var name = safeFileName(f.name, 'file');
    if (conflict != 'overwrite') {
      var n = 1;
      final dot = name.lastIndexOf('.');
      final stem = dot <= 0 ? name : name.substring(0, dot);
      final ext = dot <= 0 ? '' : name.substring(dot);
      while (await pluginFile(c, name, scope: scope).file.exists()) {
        if (conflict == 'error') {
          throw PluginApiError('conflict', 'A file named $name exists');
        }
        name = '$stem ($n)$ext';
        n++;
      }
    }
    final info = await savePluginFile(c, name, f.bytes, scope: scope);
    out.add({...info, 'originalName': f.name});
  }
  return out;
}

Future<Object?> _share(PluginCall c) async {
  final first = c.requireString(0, 'name');
  final Uint8List bytes;
  final String name;
  if (c.arg(1) == null) {
    bytes = await readPluginFile(c, first);
    name = first.split('/').last;
  } else {
    bytes = await decodePluginContent(
      c,
      c.arg(1),
      c.mapArg(2)['encoding'] as String? ?? 'utf8',
    );
    name = safeFileName(first, 'export');
  }
  await c.host.ui.share(bytes, name);
  return null;
}

Future<Object?> _storageSet(PluginCall c) async {
  final data = c.mapArg(0);
  final key = data['key'];
  final value = data['value'];
  if (key is! String || value is! String) {
    throw const PluginApiError(
      'invalid_arguments',
      'storage.set needs key and value',
    );
  }
  await c.host.files(c.plugin.id).updateStorage((s) => s[key] = value);
  return null;
}

Future<Object?> _storageRemove(PluginCall c) async {
  final key = c.mapArg(0)['key'];
  if (key is! String) return null;
  await c.host.files(c.plugin.id).updateStorage((s) => s.remove(key));
  return null;
}

Future<Object?> _storageClear(PluginCall c) async {
  await c.host.files(c.plugin.id).updateStorage((s) => s.clear());
  return null;
}
