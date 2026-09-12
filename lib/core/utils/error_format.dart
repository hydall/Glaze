import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';

/// Returns a short, human-readable error string.
///
/// DioExceptions are translated to HTTP status codes or network descriptions.
/// The status line always carries the HTTP description ("HTTP 404 - Not
/// Found"); a provider error body (OpenAI / Anthropic / Gemini shape) is
/// appended on its own line instead of replacing it, so the user sees
///
///     HTTP 404 - Not Found
///     Unknown page - v1beta/v1
///
/// instead of the full Dio verbose dump.
String formatError(Object err) {
  if (err is DioException) {
    if (err.type == DioExceptionType.cancel) {
      return 'error_request_cancelled'.tr();
    }

    final response = err.response;
    if (response != null) return _formatHttpError(response);

    return switch (err.type) {
      DioExceptionType.connectionTimeout => 'error_connection_timed_out'.tr(),
      DioExceptionType.receiveTimeout => 'error_server_too_long'.tr(),
      DioExceptionType.sendTimeout => 'error_upload_timed_out'.tr(),
      DioExceptionType.connectionError =>
        'error_connection_failed_check_network'.tr(),
      DioExceptionType.badCertificate => 'error_ssl_certificate'.tr(),
      _ => err.message ?? 'error_request_failed'.tr(),
    };
  }
  return err.toString();
}

/// Decodes an error body left as a byte stream by `ResponseType.stream`.
Future<DioException> decodeStreamingError(DioException err) async {
  final response = err.response;
  final body = response?.data;
  if (response == null || body is! ResponseBody) return err;

  late final String text;
  try {
    text = await utf8.decodeStream(body.stream).then((value) => value.trim());
  } on Object {
    return err;
  }
  if (text.isEmpty) return err;

  dynamic data = text;
  try {
    data = jsonDecode(text);
  } on FormatException {
    // Some OpenAI-compatible providers return useful plain-text errors.
  }
  return DioException(
    requestOptions: err.requestOptions,
    response: Response<dynamic>(
      data: data,
      headers: response.headers,
      requestOptions: response.requestOptions,
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      isRedirect: response.isRedirect,
      redirects: response.redirects,
      extra: response.extra,
    ),
    type: err.type,
    error: err.error,
    stackTrace: err.stackTrace,
    message: err.message,
  );
}

/// Builds "HTTP <code> - <description>" and appends the provider message on a
/// second line when the body carries one.
String _formatHttpError(Response<dynamic> response) {
  final code = response.statusCode;
  final known = code != null ? _defaultHttpMessage(code) : null;
  final description = known ?? _statusMessage(response);
  final status = code?.toString() ?? '?';
  final header =
      (description != null ? 'HTTP $status - $description' : 'HTTP $status') +
      _redirectHint(code, response);

  final apiMsg = _extractApiMessage(response.data);
  if (apiMsg == null) return header;
  // Providers that just echo the status text add nothing to the header.
  if (description != null &&
      apiMsg.toLowerCase() == description.toLowerCase()) {
    return header;
  }
  return '$header\n$apiMsg';
}

/// Names the endpoint as the thing to fix when the server answered with a
/// redirect, and quotes where it points.
///
/// A redirect is not an error, but it reaches this function as one: dart:io
/// follows 301/302/307/308 for a GET and refuses to for a POST, which every
/// completion request is. So a base URL that is missing the provider's API
/// path — `https://llm.chutes.ai` where the server wants
/// `https://llm.chutes.ai/v1` — surfaced as a bare `HTTP 308` naming nothing,
/// and the reporter had no way to tell it from the server being down.
///
/// The `Location` header is the answer the server actually gave, so it is
/// quoted rather than guessed at. Following it automatically is the one thing
/// not done here: the request carries the account's API key, and a redirect may
/// point at another host.
String _redirectHint(int? code, Response<dynamic> response) {
  if (code != 301 && code != 302 && code != 307 && code != 308) return '';
  final hint = '\n${'error_endpoint_redirect'.tr()}';
  final location = response.headers.value('location')?.trim();
  if (location == null || location.isEmpty) return hint;
  return '$hint\n→ $location';
}

/// The server-supplied reason phrase, when it is not blank.
String? _statusMessage(Response<dynamic> response) {
  final message = response.statusMessage?.trim();
  return (message == null || message.isEmpty) ? null : message;
}

String? _defaultHttpMessage(int code) {
  final key = switch (code) {
    301 => 'error_http_301',
    302 => 'error_http_302',
    307 => 'error_http_307',
    308 => 'error_http_308',
    400 => 'error_http_400',
    401 => 'error_http_401',
    402 => 'error_http_402',
    403 => 'error_http_403',
    404 => 'error_http_404',
    405 => 'error_http_405',
    408 => 'error_http_408',
    409 => 'error_http_409',
    413 => 'error_http_413',
    422 => 'error_http_422',
    429 => 'error_http_429',
    451 => 'error_http_451',
    500 => 'error_http_500',
    502 => 'error_http_502',
    503 => 'error_http_503',
    504 => 'error_http_504',
    522 => 'error_http_522',
    524 => 'error_http_524',
    529 => 'error_http_529',
    _ => null,
  };
  return key?.tr();
}

/// The longest provider message worth showing. The string lands in a modal
/// dialog, in a toast, and on one line of a memory card; past this length it
/// stops being a message and starts being a document.
const _maxApiMessageChars = 300;

/// Tries to pull a human-readable message out of common API error shapes.
/// Returns null if nothing useful is found.
///
/// A body that arrived as text is decoded before the shapes below are tried.
/// Dio parses JSON only when the request asked for it, and the catalog client
/// asks for `ResponseType.plain` (its hosts answer HTML as readily as JSON) —
/// so a server's `{"error":{"message":...}}` reached here as a String, none of
/// the shape-aware branches ever ran, and the whole body went to the reader
/// verbatim. That is how a DataCat 403 came out as `HTTP 403:` followed by its
/// entire Turnstile blob, over a dialog the size of the screen.
String? _extractApiMessage(dynamic data) {
  if (data is String) {
    final decoded = _jsonBody(data);
    return decoded == null ? _proseMessage(data) : _extractApiMessage(decoded);
  }
  // Gemini and several proxies wrap the error object in a single-element array.
  if (data is List) {
    for (final entry in data) {
      final message = _extractApiMessage(entry);
      if (message != null) return message;
    }
    return null;
  }
  if (data is! Map) return null;
  // OpenAI / Anthropic / Gemini: {"error": {"message": "..."}}
  final error = data['error'];
  if (error is String && error.trim().isNotEmpty) return _clamp(error);
  if (error is Map) {
    final msg = error['message'];
    if (msg is String && msg.trim().isNotEmpty) return _clamp(msg);
  }
  // Fallback: top-level {"message": "..."} — Meilisearch, Janny and most
  // OpenAI-compatible proxies answer in this shape.
  final msg = data['message'];
  if (msg is String && msg.trim().isNotEmpty) return _clamp(msg);
  final detail = data['detail'];
  if (detail is String && detail.trim().isNotEmpty) return _clamp(detail);
  // A JSON object in none of the known shapes describes the failure to a
  // machine, not to a person — server instance ids, challenge configs, lease
  // flags. The localized status description says more than any of it, so
  // nothing is added to it.
  return null;
}

/// [body] decoded, when it is a JSON object or array.
///
/// Returns null for anything else, including a bare JSON string, so the
/// caller's recursion is one level deep at most.
Object? _jsonBody(String body) {
  final text = body.trimLeft();
  if (!text.startsWith('{') && !text.startsWith('[')) return null;
  try {
    final decoded = jsonDecode(text);
    return (decoded is Map || decoded is List) ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// A plain-text body, when it reads like something a person wrote.
///
/// Bare prose is worth showing: several OpenAI-compatible providers answer
/// with nothing else. A block page is not — Cloudflare and friends answer with
/// kilobytes of markup, and the first 300 characters of it are a `<head>`.
String? _proseMessage(String body) {
  final text = body.trim();
  if (text.isEmpty || text.startsWith('<')) return null;
  return _clamp(text);
}

String _clamp(String message) {
  final text = message.trim();
  if (text.length <= _maxApiMessageChars) return text;
  return '${text.substring(0, _maxApiMessageChars).trimRight()}…';
}
