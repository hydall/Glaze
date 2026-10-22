import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'api/files_api.dart';

typedef PluginPackageReader =
    Future<Uint8List?> Function(String pluginId, String path);

final RegExp _pluginId = RegExp(r'^[a-z0-9._-]+$');

/// Query parameter naming a frame document, see [PluginPackageServer.openFrame].
const String kPluginFrameParam = 'glaze-frame';

/// How long a frame document waits to be loaded.
const Duration _frameTtl = Duration(minutes: 1);

/// Frame documents kept waiting at most; the oldest go first.
const int _maxFrames = 512;

/// Serves installed plugin packages to their frames over a loopback HTTP
/// server, at `/plugins/<id>/<path>` as Tavo does, so a frame has a real
/// address: relative URLs, stylesheets, fonts and `fetch` of the plugin's
/// own files work as they do on the web, and nothing has to be inlined.
///
/// A frame's document itself is built by the plugin host in the chat page
/// (policy, SDK, boot data, the plugin's HTML) and handed over through
/// [openFrame]; it is served once, at an address in the plugin's package, so
/// the frame resolves its URLs against that package. The frames keep their
/// `sandbox` (an opaque origin); their policy lets each one reach only its
/// own package's path.
///
/// Package files are public (they come from public packages); anything else
/// is not served. A raw package page is served with every script and
/// request turned off: frames are only ever made from the host's documents.
class PluginPackageServer {
  HttpServer? _server;
  Uri? _origin;
  PluginPackageReader? _read;
  bool _stopped = false;
  final _frames = <String, _Frame>{};
  final _random = Random.secure();

  /// `http://127.0.0.1:<port>` while running.
  Uri? get origin => _origin;

  /// The address the files of [pluginId] are served under, ending in `/`;
  /// null while the server is not running.
  String? packageBase(String pluginId) {
    final origin = _origin;
    if (origin == null || !_pluginId.hasMatch(pluginId)) return null;
    return '$origin/plugins/$pluginId/';
  }

  /// Starts serving packages read through [read]; the origin once it is up,
  /// null when no loopback port could be had.
  Future<Uri?> start(PluginPackageReader read) async {
    _read = read;
    if (_server != null && !_stopped) return _origin;
    return _bind(_origin?.port ?? 0);
  }

  Future<Uri?> _bind(int preferredPort) async {
    HttpServer? server;
    if (preferredPort != 0) {
      try {
        server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          preferredPort,
        );
      } on SocketException catch (e) {
        debugPrint('[PluginPackageServer] port $preferredPort taken: $e');
      }
    }
    try {
      server ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } on SocketException catch (e) {
      debugPrint('[PluginPackageServer] no loopback port: $e');
      return null;
    }
    // dart:io adds `X-Frame-Options: SAMEORIGIN` to every response, and a
    // frame document is always embedded by another origin: the WebView
    // refused to show it (ERR_BLOCKED_BY_RESPONSE). Each response sets the
    // headers it needs itself.
    server.defaultResponseHeaders.clear();
    _server = server;
    _stopped = false;
    _origin = Uri.parse('http://127.0.0.1:${server.port}');
    unawaited(_accept(server));
    return _origin;
  }

  Future<void> _accept(HttpServer server) async {
    try {
      await for (final request in server) {
        unawaited(_handle(request));
      }
    } catch (e) {
      debugPrint('[PluginPackageServer] stopped: $e');
    }
    if (identical(server, _server)) _stopped = true;
  }

  /// Binds again on the same port when the OS took the socket away (iOS
  /// does that to a suspended app), so frames already open keep loading.
  Future<void> revive() async {
    final server = _server;
    if (server == null || _read == null) return;
    if (!_stopped && await _alive(server.port)) return;
    debugPrint('[PluginPackageServer] lost, rebinding');
    try {
      await server.close(force: true);
    } catch (_) {
      // The socket is already gone.
    }
    _server = null;
    await _bind(server.port);
  }

  Future<bool> _alive(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Keeps [document] for one load by a frame of [pluginId] and returns the
  /// address to load it from: [path] in the plugin's package, so the frame
  /// resolves its URLs against it. Null while the server is not running.
  String? openFrame(String pluginId, String path, String document) {
    final base = packageBase(pluginId);
    if (base == null) return null;
    final now = DateTime.now();
    _frames.removeWhere((_, f) => now.difference(f.at) > _frameTtl);
    while (_frames.length >= _maxFrames) {
      _frames.remove(_frames.keys.first);
    }
    final key = _key();
    final safe = _safePath(path) ?? 'index.html';
    _frames[key] = _Frame(pluginId, safe, document, now);
    final encoded = safe.split('/').map(Uri.encodeComponent).join('/');
    return '$base$encoded?$kPluginFrameParam=$key';
  }

  /// Whether [url] is a frame document address this server handed out.
  bool isFrameUrl(Uri url) {
    final origin = _origin;
    return origin != null &&
        url.scheme == origin.scheme &&
        url.host == origin.host &&
        url.port == origin.port &&
        url.path.startsWith('/plugins/') &&
        url.queryParameters.containsKey(kPluginFrameParam);
  }

  String _key() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String? _safePath(String path) {
    final segments = path.split('/');
    if (path.isEmpty ||
        path.contains('\\') ||
        path.contains(':') ||
        segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
      return null;
    }
    return path;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        return;
      }
      final segments = request.uri.pathSegments;
      final id = segments.length > 2 && segments.first == 'plugins'
          ? segments[1]
          : null;
      final path = id == null ? null : _safePath(segments.skip(2).join('/'));
      if (id == null || !_pluginId.hasMatch(id) || path == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');

      final key = request.uri.queryParameters[kPluginFrameParam];
      if (key != null) {
        final frame = _frames[key];
        if (frame == null || frame.pluginId != id || frame.path != path) {
          response.statusCode = HttpStatus.notFound;
          return;
        }
        _frames.remove(key);
        response.headers.contentType = ContentType.html;
        if (request.method == 'GET') response.add(utf8.encode(frame.document));
        return;
      }

      final bytes = await _read?.call(id, path);
      if (bytes == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      // Frames have an opaque origin: fonts and fetches of the package are
      // cross-origin to them.
      response.headers
        ..set('Access-Control-Allow-Origin', '*')
        ..set('X-Content-Type-Options', 'nosniff')
        // Only matters for a file loaded as a page or a worker: it may run
        // nothing and reach nothing.
        ..set('Content-Security-Policy', "default-src 'none'; sandbox");
      final type = pluginMimeType(path);
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        type.startsWith('text/') || type == 'application/json'
            ? '$type; charset=utf-8'
            : type,
      );
      response.contentLength = bytes.length;
      if (request.method == 'GET') response.add(bytes);
    } catch (e) {
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {
        // Headers already sent.
      }
    } finally {
      try {
        await response.close();
      } catch (_) {
        // Connection already gone.
      }
    }
  }

  @visibleForTesting
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _origin = null;
    _read = null;
    _frames.clear();
    await server?.close(force: true);
  }
}

class _Frame {
  _Frame(this.pluginId, this.path, this.document, this.at);
  final String pluginId;
  final String path;
  final String document;
  final DateTime at;
}

/// The app's one package server.
final PluginPackageServer pluginPackageServer = PluginPackageServer();
