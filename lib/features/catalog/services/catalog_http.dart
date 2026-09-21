import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

const _timeout = Duration(seconds: 20);

/// Browser User-Agent for the raw catalog Dio client. Without this, dart:io
/// sends `Dart/x (dart:io)`, which Cloudflare / WAF-fronted hosts (jannyai.com,
/// datacat.run) reject with 403. The janitor provider avoids this by routing
/// through a real WebView; janny/datacat use this client directly, so they must
/// carry a plausible browser UA themselves.
const _catalogUA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';

final _dio = Dio(BaseOptions(
  connectTimeout: _timeout,
  receiveTimeout: _timeout,
  responseType: ResponseType.plain,
  headers: {'User-Agent': _catalogUA},
  // Take all responses so we can surface the server's error body instead of
  // Dio throwing an opaque DioException before our own status check runs.
  validateStatus: (_) => true,
));

/// Replaces the transport under the shared catalog client.
///
/// The client is a file-private singleton on purpose — every provider must
/// carry the same browser UA — so this is the seam the provider tests use to
/// answer a request without a network round-trip.
@visibleForTesting
void setCatalogHttpAdapter(HttpClientAdapter adapter) {
  _dio.httpClientAdapter = adapter;
}

/// The HTTP status a catalog failure reported, or null when the request never
/// reached a server that answered.
///
/// Providers used to decide whether to re-authenticate by searching
/// `e.toString()` for `'401'`, which matches a 401 that merely appears
/// somewhere in the server's *body* just as readily as a real one — and reads
/// as a 401 for a request whose status was something else entirely.
int? catalogErrorStatus(Object error) =>
    error is DioException ? error.response?.statusCode : null;

/// Raises a [DioException] carrying the response, so callers can run it through
/// the shared `formatError()` (same friendly, localized handling as LLM
/// requests) instead of showing a raw dump. The full body is logged in debug
/// for diagnosis — the server puts the real reason there (e.g. "bad syntax").
Never _throwHttp(Response<String> res) {
  assert(() {
    final body = (res.data ?? '').trim();
    debugPrint(
      '[catalog] HTTP ${res.statusCode} ${res.requestOptions.uri}'
      '${body.isEmpty ? '' : ' — ${body.length > 500 ? '${body.substring(0, 500)}…' : body}'}',
    );
    return true;
  }());
  throw DioException.badResponse(
    statusCode: res.statusCode ?? 0,
    requestOptions: res.requestOptions,
    response: res,
  );
}

Future<Map<String, dynamic>> catalogGet(
  String url,
  Map<String, String> headers,
) async {
  final res = await _dio.get<String>(
    url,
    options: Options(headers: headers, responseType: ResponseType.plain),
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res);
  }
  return _parseJson(res.data ?? '');
}

Future<String> catalogGetText(
  String url,
  Map<String, String> headers,
) async {
  final res = await _dio.get<String>(
    url,
    options: Options(headers: headers, responseType: ResponseType.plain),
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res);
  }
  return res.data ?? '';
}

/// Raw bytes, for endpoints that answer with an image rather than JSON.
///
/// DataCat's Client API serves archived character images from an endpoint that
/// needs the same headers as every other call (client id, transfer lease), so
/// the bytes cannot be fetched with a bare `Dio()` the way a public avatar URL
/// can.
Future<List<int>> catalogGetBytes(
  String url,
  Map<String, String> headers,
) async {
  final res = await _dio.get<List<int>>(
    url,
    options: Options(headers: headers, responseType: ResponseType.bytes),
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    throw DioException.badResponse(
      statusCode: res.statusCode!,
      requestOptions: res.requestOptions,
      response: res,
    );
  }
  return res.data ?? const [];
}

Future<Map<String, dynamic>> catalogPost(
  String url,
  Map<String, dynamic> body,
  Map<String, String> headers,
) async {
  final allHeaders = {'Content-Type': 'application/json', ...headers};
  final res = await _dio.post<String>(
    url,
    data: jsonEncode(body),
    options: Options(headers: allHeaders, responseType: ResponseType.plain),
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res);
  }
  return _parseJson(res.data ?? '');
}

/// A DELETE whose success is the status alone. Used by endpoints that answer
/// `204 No Content`, where parsing a body would only ever fail.
Future<void> catalogDelete(String url, Map<String, String> headers) async {
  final res = await _dio.delete<String>(
    url,
    options: Options(headers: headers, responseType: ResponseType.plain),
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res);
  }
}

Map<String, dynamic> _parseJson(String text) {
  try {
    return jsonDecode(text) as Map<String, dynamic>;
  } catch (_) {
    throw Exception('Server returned invalid JSON');
  }
}

List<dynamic> _parseJsonList(String text) {
  try {
    return jsonDecode(text) as List<dynamic>;
  } catch (_) {
    throw Exception('Server returned invalid JSON');
  }
}

Future<List<dynamic>> catalogGetList(
  String url,
  Map<String, String> headers,
) async {
  final res = await _dio.get<String>(
    url,
    options: Options(headers: headers, responseType: ResponseType.plain),
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res);
  }
  return _parseJsonList(res.data ?? '[]');
}
