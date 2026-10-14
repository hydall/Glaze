import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../models/plugin_manifest.dart';
import '../../../../core/utils/id_generator.dart';
import '../plugin_api.dart';
import '../plugin_request_capture.dart';
import 'files_api.dart';

/// `glaze.net.fetch(input, init)`: a request the app makes for the plugin.
/// The page's cross-origin rules do not apply, so a plugin can talk to a
/// service directly rather than through a relay server of its own. The
/// plugin's internet rules do: the hosts it may reach (checked again on
/// every redirect), https only and no local addresses unless it has local
/// network access, every host in its network log. No cookies or other app
/// credentials go along.
///
/// The SDK turns `fetch` arguments into `[url, {id, method, headers, body,
/// timeout}]` (headers as name/value pairs, body base64) and the result,
/// `{status, statusText, url, redirected, headers, body}`, back into a
/// `Response`. `net.abort(id)` cancels a request in flight; the SDK keeps it
/// for `AbortSignal`s.
Map<String, PluginMethod> netApi() => {
  'net.fetch': const PluginMethod(_fetch, permission: PluginPermission.network),
  'net.abort': const PluginMethod(_abort, permission: PluginPermission.network),
};

const _methods = {'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'};

/// Request headers the app sets itself or that would carry what is not the
/// plugin's to send.
const _ownHeaders = {
  'connection',
  'content-length',
  'cookie',
  'cookie2',
  'expect',
  'host',
  'keep-alive',
  'origin',
  'referer',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'via',
};

/// Headers that describe a body; dropped when a redirect turns the request
/// into a GET.
const _bodyHeaders = {
  'content-type',
  'content-encoding',
  'content-language',
  'content-location',
};

const _maxTimeout = Duration(minutes: 10);

final _token = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");

/// Requests in flight by plugin and SDK id, for `net.abort`.
final Map<String, CancelToken> _inFlight = {};

String _key(PluginCall c, String id) => '${c.plugin.id}\n$id';

Future<Object?> _abort(PluginCall c) async {
  final id = c.arg(0);
  if (id is String) _inFlight[_key(c, id)]?.cancel();
  return null;
}

Future<Object?> _fetch(PluginCall c) async {
  var uri = Uri.tryParse(c.requireString(0, 'url'));
  final options = c.mapArg(1);
  var method = (options['method'] as String? ?? 'GET').toUpperCase();
  if (!_methods.contains(method)) {
    throw PluginApiError('invalid_arguments', 'Unsupported method $method');
  }
  final headers = _requestHeaders(options['headers']);
  final rawBody = options['body'];
  Uint8List? body;
  if (rawBody is String && rawBody.isNotEmpty) {
    try {
      body = base64Decode(rawBody);
    } on FormatException {
      throw const PluginApiError('invalid_arguments', 'body must be base64');
    }
    if (body.length > kPluginFileMaxBytes) {
      throw const PluginApiError('too_large', 'The request body is too large');
    }
  }
  if (body != null && (method == 'GET' || method == 'HEAD')) {
    throw PluginApiError('invalid_arguments', '$method takes no body');
  }

  if (uri == null) {
    throw const PluginApiError('invalid_arguments', 'Malformed URL');
  }
  final id = options['id'];
  final capture = pluginRequestContext(
    pluginId: c.plugin.id,
    sessionId: c.host.sessionId,
    requestId: 'app:${generateId()}',
    method: method,
    url: uri,
  );
  recordPluginRequest(
    capture,
    method: method,
    url: '$uri',
    headers: [
      for (final h in headers.entries) [h.key, h.value],
    ],
    body: body == null ? null : _bodyText(body, headers['content-type']),
    via: 'glaze.net.fetch',
  );
  final cancel = CancelToken();
  final key = id is String && id.isNotEmpty ? _key(c, id) : null;
  if (key != null) _inFlight[key] = cancel;
  final timeoutMs = options['timeout'];
  final timer = timeoutMs is num && timeoutMs > 0
      ? Timer(
          Duration(milliseconds: timeoutMs.toInt()) < _maxTimeout
              ? Duration(milliseconds: timeoutMs.toInt())
              : _maxTimeout,
          () => cancel.cancel('timeout'),
        )
      : null;
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      // Between chunks: a model may think for a while before it answers.
      receiveTimeout: const Duration(minutes: 5),
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
      if (uri.scheme == 'http' && !c.plugin.localNetwork) {
        throw const PluginApiError(
          'permission_denied',
          'Plain http needs local network access',
        );
      }
      if (hop > 20) {
        throw const PluginApiError('network_error', 'Too many redirects');
      }
      await requirePluginHost(c, uri);
      final response = await dio.requestUri<ResponseBody>(
        uri,
        data: body == null ? null : Stream.value(body),
        cancelToken: cancel,
        options: Options(
          method: method,
          headers: {
            ...headers,
            if (body != null) Headers.contentLengthHeader: body.length,
          },
        ),
      );
      final status = response.statusCode ?? 0;
      final location = response.headers.value('location');
      if (const {301, 302, 303, 307, 308}.contains(status) &&
          location != null) {
        await response.data?.stream.drain<void>().catchError((_) {});
        final next = uri.resolve(location);
        if (status == 303 && method != 'HEAD' ||
            (status == 301 || status == 302) && method == 'POST') {
          method = 'GET';
          body = null;
          headers.removeWhere((name, _) => _bodyHeaders.contains(name));
        }
        if (next.scheme != uri.scheme ||
            next.host != uri.host ||
            next.port != uri.port) {
          headers.remove('authorization');
        }
        uri = next;
        continue;
      }
      final bytes = method == 'HEAD'
          ? null
          : await _readCapped(response.data!.stream);
      recordPluginResponse(
        capture,
        status: status,
        body: bytes == null
            ? null
            : _bodyText(bytes, response.headers.value('content-type')),
      );
      return {
        'status': status,
        'statusText': (response.statusMessage ?? '').replaceAll(
          RegExp(r'[\r\n]'),
          '',
        ),
        'url': uri.toString(),
        'redirected': hop > 0,
        'headers': _responseHeaders(response.headers),
        'body': bytes == null ? null : base64Encode(bytes),
      };
    }
  } on DioException catch (e) {
    final error = !CancelToken.isCancel(e)
        ? PluginApiError(
            'network_error',
            e.message ?? 'The request failed (${e.type.name})',
          )
        : e.error == 'timeout'
        ? const PluginApiError('timeout', 'The request timed out')
        : const PluginApiError('aborted', 'The request was aborted');
    recordPluginResponse(
      capture,
      error: error.code == 'network_error' ? error.message : error.code,
    );
    throw error;
  } on PluginApiError catch (e) {
    recordPluginResponse(capture, error: '${e.code}: ${e.message}');
    rethrow;
  } finally {
    timer?.cancel();
    if (key != null && identical(_inFlight[key], cancel)) _inFlight.remove(key);
    dio.close(force: true);
  }
}

/// [bytes] as the inspector shows them: text, or what kind of data and how
/// much of it.
String _bodyText(Uint8List bytes, String? type) {
  final t = (type ?? '').toLowerCase();
  if (RegExp(
    r'^(image|audio|video|font)/|octet-stream|pdf|zip|protobuf',
  ).hasMatch(t)) {
    return '[${t.split(';').first}, ${bytes.length} bytes]';
  }
  final text = utf8.decode(
    bytes.length > kPluginRequestTextCap * 4
        ? bytes.sublist(0, kPluginRequestTextCap * 4)
        : bytes,
    allowMalformed: true,
  );
  return text.length > kPluginRequestTextCap
      ? text.substring(0, kPluginRequestTextCap)
      : text;
}

/// Lower-cased names, without the ones the app sets itself; repeated names
/// are joined as a browser would.
Map<String, String> _requestHeaders(Object? raw) {
  final pairs = <(Object?, Object?)>[
    if (raw is List)
      for (final p in raw)
        if (p is List && p.length == 2) (p[0], p[1]),
    if (raw is Map)
      for (final e in raw.entries) (e.key, e.value),
  ];
  final out = <String, String>{};
  for (final (name, value) in pairs) {
    if (name is! String || value is! String || !_token.hasMatch(name)) {
      throw const PluginApiError('invalid_arguments', 'Malformed header');
    }
    if (value.contains('\r') || value.contains('\n')) {
      throw PluginApiError('invalid_arguments', 'Malformed header $name');
    }
    final lower = name.toLowerCase();
    if (_ownHeaders.contains(lower) ||
        lower.startsWith('proxy-') ||
        lower.startsWith('sec-')) {
      continue;
    }
    out[lower] = out.containsKey(lower) ? '${out[lower]}, $value' : value;
  }
  return out;
}

/// Name/value pairs, without cookies. The app unpacks compressed bodies,
/// so their encoding and length no longer apply.
List<List<String>> _responseHeaders(Headers headers) {
  final unpacked = headers.value('content-encoding') != null;
  return [
    for (final e in headers.map.entries)
      if (!e.key.toLowerCase().startsWith('set-cookie') &&
          !(unpacked &&
              const {
                'content-encoding',
                'content-length',
              }.contains(e.key.toLowerCase())))
        [e.key.toLowerCase(), e.value.join(', ')],
  ];
}

Future<Uint8List> _readCapped(Stream<Uint8List> stream) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    out.add(chunk);
    if (out.length > kPluginFileMaxBytes) {
      throw const PluginApiError('too_large', 'The response is too large');
    }
  }
  return out.takeBytes();
}
