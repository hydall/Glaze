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
  final header = description != null
      ? 'HTTP $status - $description'
      : 'HTTP $status';

  final hint = _rejectedImagesHint(code, response.requestOptions);
  final apiMsg = _extractApiMessage(response.data);
  if (apiMsg == null) return '$header$hint';
  // Providers that just echo the status text add nothing to the header.
  if (description != null &&
      apiMsg.toLowerCase() == description.toLowerCase()) {
    return '$header$hint';
  }
  return '$header\n$apiMsg$hint';
}

/// The line that turns a bare `HTTP 400 - Bad Request` into something the
/// user can act on when the request carried a picture.
///
/// Nothing tells Glaze whether the selected model is multimodal, so the
/// attachments in a chat's history are serialized for whatever model is
/// active — switch to one that does not take images and the provider rejects
/// the whole request, naming nothing the reader recognises. The rejection is
/// the only evidence there is, so the hint is offered as a possibility, and
/// only when the request that failed actually held an image.
String _rejectedImagesHint(int? code, RequestOptions options) {
  if (code != 400 && code != 415 && code != 422) return '';
  if (!_carriesImagePart(options.data)) return '';
  return '\n${'error_images_maybe_unsupported'.tr()}';
}

/// Whether a request body holds an image part, in any of the shapes the
/// transports build: OpenAI `image_url`, the Responses API's `input_image`,
/// Anthropic's `image`, or Gemini's `inline_data`.
///
/// Depth-limited because this runs on the error path of a body that may be
/// megabytes of base64, and must not become the reason an error is slow.
bool _carriesImagePart(Object? data, [int depth = 0]) {
  if (depth > 6) return false;
  if (data is Map) {
    final type = data['type'];
    if (type == 'image_url' || type == 'input_image' || type == 'image') {
      return true;
    }
    if (data.containsKey('inline_data') || data.containsKey('inlineData')) {
      return true;
    }
    for (final value in data.values) {
      if (_carriesImagePart(value, depth + 1)) return true;
    }
    return false;
  }
  if (data is List) {
    for (final value in data) {
      if (_carriesImagePart(value, depth + 1)) return true;
    }
    return false;
  }
  // A body handed to Dio already encoded. Searching the text is cruder than
  // walking the structure, but the markers are distinctive enough and the
  // alternative is decoding the whole thing to answer one question.
  if (data is String) {
    return data.contains('"image_url"') ||
        data.contains('"input_image"') ||
        data.contains('"inline_data"') ||
        data.contains('"inlineData"') ||
        data.contains('"type":"image"') ||
        data.contains('"type": "image"');
  }
  return false;
}

/// The server-supplied reason phrase, when it is not blank.
String? _statusMessage(Response<dynamic> response) {
  final message = response.statusMessage?.trim();
  return (message == null || message.isEmpty) ? null : message;
}

String? _defaultHttpMessage(int code) {
  final key = switch (code) {
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

/// Tries to pull a human-readable message out of common API error shapes.
/// Returns null if nothing useful is found.
String? _extractApiMessage(dynamic data) {
  if (data is String && data.trim().isNotEmpty) return data.trim();
  if (data is! Map<String, dynamic>) return null;
  // OpenAI / Anthropic / Gemini: {"error": {"message": "..."}}
  final error = data['error'];
  if (error is String && error.trim().isNotEmpty) return error.trim();
  if (error is Map) {
    final msg = error['message'];
    if (msg is String && msg.isNotEmpty) return msg;
  }
  // Fallback: top-level {"message": "..."}
  final msg = data['message'];
  if (msg is String && msg.isNotEmpty) return msg;
  final detail = data['detail'];
  if (detail is String && detail.isNotEmpty) return detail;
  return null;
}
