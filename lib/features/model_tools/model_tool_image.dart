import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'model_tool.dart';

/// Largest picture a tool accepts, downloaded or inline.
const int kMaxToolImageBytes = 15 * 1024 * 1024;

/// HTTP client the tools download pictures with; a provider so tests can
/// answer without the network.
final modelToolDioProvider = Provider<Dio>(
  (ref) => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.bytes,
      // Statuses are reported to the model, not thrown at it.
      validateStatus: (_) => true,
    ),
  ),
);

/// A picture a tool call pointed at, fetched and checked.
class ToolImage {
  const ToolImage(this.bytes, this.mimeType);

  final Uint8List bytes;
  final String mimeType;

  String get dataUrl => 'data:$mimeType;base64,${base64Encode(bytes)}';
}

/// Fetches the picture [source] names — an `http(s)` URL or a `data:` URL —
/// and accepts it only when its bytes are a PNG, JPEG, WebP or GIF within
/// [kMaxToolImageBytes]. Everything else is a [ModelToolError] at [path].
Future<ToolImage> fetchToolImage(Ref ref, Object? source, String path) async {
  if (source is! String || source.trim().isEmpty) {
    throw ModelToolError.invalid(path, 'an https URL or a data: URL', source);
  }
  final value = source.trim();
  final Uint8List bytes;
  if (value.startsWith('data:')) {
    final comma = value.indexOf(',');
    if (comma < 0 || !value.substring(0, comma).contains(';base64')) {
      throw ModelToolError.invalid(path, 'a base64 data: URL', source);
    }
    try {
      bytes = base64Decode(value.substring(comma + 1).trim());
    } on FormatException {
      throw ModelToolError.invalid(path, 'valid base64 data', source);
    }
  } else {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw ModelToolError.invalid(path, 'an https URL or a data: URL', source);
    }
    bytes = await _download(ref.read(modelToolDioProvider), uri, path);
  }
  if (bytes.length > kMaxToolImageBytes) throw _tooLarge(path);
  final mime = sniffImageMime(bytes);
  if (mime == null) {
    throw ModelToolError(
      'invalid_arguments',
      '$path is not a PNG, JPEG, WebP or GIF image.',
      details: {'path': path},
    );
  }
  return ToolImage(bytes, mime);
}

Future<Uint8List> _download(Dio dio, Uri uri, String path) async {
  final Response<List<int>> response;
  // Cut the transfer off as soon as it is known to be too big — from the
  // declared length, or from what has arrived — rather than after it landed.
  final cancel = CancelToken();
  var oversized = false;
  try {
    response = await dio.getUri<List<int>>(
      uri,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Accept': 'image/*'},
      ),
      onReceiveProgress: (received, total) {
        if (received > kMaxToolImageBytes || total > kMaxToolImageBytes) {
          oversized = true;
          cancel.cancel();
        }
      },
    );
  } on DioException catch (e) {
    if (oversized) throw _tooLarge(path);
    throw ModelToolError(
      'fetch_failed',
      'Could not download $path: ${e.message ?? e.type.name}.',
      details: {'path': path},
    );
  }
  final status = response.statusCode ?? 0;
  if (status < 200 || status >= 300) {
    throw ModelToolError(
      'fetch_failed',
      'Downloading $path returned HTTP $status.',
      details: {'path': path, 'status': status},
    );
  }
  return Uint8List.fromList(response.data ?? const []);
}

ModelToolError _tooLarge(String path) => ModelToolError(
  'invalid_arguments',
  '$path is larger than ${kMaxToolImageBytes ~/ (1024 * 1024)} MB.',
  details: {'path': path},
);

/// The image type [bytes] start with, by signature; null for anything else.
String? sniffImageMime(Uint8List bytes) {
  bool startsWith(List<int> sig, [int offset = 0]) {
    if (bytes.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(ascii.encode('GIF87a')) ||
      startsWith(ascii.encode('GIF89a'))) {
    return 'image/gif';
  }
  if (startsWith(ascii.encode('RIFF')) && startsWith(ascii.encode('WEBP'), 8)) {
    return 'image/webp';
  }
  return null;
}
