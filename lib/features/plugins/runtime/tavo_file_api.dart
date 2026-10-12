import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'tavo_call.dart';

/// Per-file size cap for `tavo.file.save`.
const int kTavoFileMaxBytes = 32 * 1024 * 1024;

/// `tavo.file.*` and the `localStorage` shim (`storage.*`).
Map<String, TavoMethod> tavoFileMethods() => {
  'file.list': const TavoMethod(_list, permission: 'file'),
  'file.save': const TavoMethod(_save, permission: 'file'),
  'file.load': const TavoMethod(_load, permission: 'file'),
  'file.delete': const TavoMethod(_delete, permission: 'file'),
  'file.exists': const TavoMethod(_exists, permission: 'file'),
  'storage.set': const TavoMethod(_storageSet),
  'storage.remove': const TavoMethod(_storageRemove),
  'storage.clear': const TavoMethod(_storageClear),
};

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
  'css': 'text/css',
  'js': 'text/javascript',
  'pdf': 'application/pdf',
};

String tavoMimeType(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return _mimeByExtension[ext] ?? 'application/octet-stream';
}

String? _scopeOption(TavoCall c, int index) {
  final scope = c.mapArg(index)['scope'];
  return scope is String ? scope : null;
}

Future<Object?> _list(TavoCall c) async {
  final options = c.mapArg(0);
  final scope = options['scope'] is String
      ? options['scope'] as String
      : 'chat';
  final store = c.host.files(c.plugin.id);
  final dir = store.scopeDir(scope, c.host.sessionId);
  if (!await dir.exists()) return {'files': <Object>[]};
  final entries = await dir.list().where((e) => e is File).cast<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final files = <Map<String, Object?>>[];
  for (final f in entries) {
    final stat = await f.stat();
    final name = f.uri.pathSegments.last;
    files.add({
      'path': 'files/$scope/$name',
      'name': name,
      'size': stat.size,
      'mimeType': tavoMimeType(name),
      'modifiedAt': stat.modified.toUtc().toIso8601String(),
    });
  }
  return {'files': files};
}

Future<Uint8List> _decodeContent(Object? content, String? encoding) async {
  if (content is! String) {
    throw const TavoError('invalid_arguments', 'File content must be a string');
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
    final response = await Dio().get<List<int>>(
      content,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data ?? const []);
  }
  return utf8.encode(content);
}

Future<Object?> _save(TavoCall c) async {
  final name = c.requireString(0, 'name');
  final options = c.mapArg(2);
  final bytes = await _decodeContent(c.arg(1), options['encoding'] as String?);
  if (bytes.length > kTavoFileMaxBytes) {
    throw const TavoError('too_large', 'The file is too large');
  }
  final target = c.host
      .files(c.plugin.id)
      .resolve(name, scope: _scopeOption(c, 2), sessionId: c.host.sessionId);
  await target.file.parent.create(recursive: true);
  await target.file.writeAsBytes(bytes, flush: true);
  return target.virtualPath;
}

Future<Object?> _load(TavoCall c) async {
  final target = c.host
      .files(c.plugin.id)
      .resolve(
        c.requireString(0, 'name'),
        scope: _scopeOption(c, 1),
        sessionId: c.host.sessionId,
      );
  if (!await target.file.exists()) return null;
  final bytes = await target.file.readAsBytes();
  switch (c.mapArg(1)['encoding']) {
    case 'base64':
      return base64Encode(bytes);
    case 'dataUrl':
      final mime = tavoMimeType(target.file.path);
      return 'data:$mime;base64,${base64Encode(bytes)}';
    case 'bytes':
      return bytes.toList();
    default:
      return utf8.decode(bytes, allowMalformed: true);
  }
}

Future<Object?> _delete(TavoCall c) async {
  final target = c.host
      .files(c.plugin.id)
      .resolve(
        c.requireString(0, 'name'),
        scope: _scopeOption(c, 1),
        sessionId: c.host.sessionId,
      );
  if (await target.file.exists()) await target.file.delete();
  return null;
}

Future<Object?> _exists(TavoCall c) async {
  final target = c.host
      .files(c.plugin.id)
      .resolve(
        c.requireString(0, 'name'),
        scope: _scopeOption(c, 1),
        sessionId: c.host.sessionId,
      );
  return target.file.exists();
}

Future<Object?> _storageSet(TavoCall c) async {
  final key = c.named('key');
  final value = c.named('value');
  if (key is! String || value is! String) {
    throw const TavoError(
      'invalid_arguments',
      'storage.set needs key and value',
    );
  }
  await c.host.files(c.plugin.id).updateStorage((s) => s[key] = value);
  return null;
}

Future<Object?> _storageRemove(TavoCall c) async {
  final key = c.named('key');
  if (key is! String) return null;
  await c.host.files(c.plugin.id).updateStorage((s) => s.remove(key));
  return null;
}

Future<Object?> _storageClear(TavoCall c) async {
  await c.host.files(c.plugin.id).updateStorage((s) => s.clear());
  return null;
}
