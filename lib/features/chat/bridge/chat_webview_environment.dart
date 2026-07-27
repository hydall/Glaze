import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/constants/build_channel.dart';
import '../../../core/utils/platform_paths.dart';
import 'chat_webview_settings.dart';

WebViewEnvironment? _chatWebViewEnvironment;
String? _janitorWebViewUserAgent;
HttpServer? _chatWebViewAssetServer;
WebUri? _chatWebViewAssetBaseUrl;
HttpServer? _chatWebViewLocalFileServer;
WebUri? _chatWebViewLocalFileBaseUrl;

/// Shared WebView2 environment for Windows chat/headless WebViews.
///
/// The Windows implementation of `flutter_inappwebview` expects WebView2 to be
/// initialized before creating WebViews. Mobile platforms do not use this.
WebViewEnvironment? get chatWebViewEnvironment => _chatWebViewEnvironment;

/// Cleaned-up User-Agent for the janitorai WebViews, or `null` to keep the
/// native UA (no override).
///
/// Embedded WebViews carry markers that gatekeepers reject: WebView2's native UA
/// has an `Edg/…` token Google's sign-in flags as "UA inconsistency", and
/// Android WebView's UA has a `; wv` qualifier Google blocks with
/// `disallowed_useragent`. We can't just hardcode a clean Chrome UA: the
/// `userAgent` override changes only the UA *string*, while the WebView keeps
/// emitting User-Agent Client Hints (`Sec-CH-UA`) from its real Chromium version
/// — and Cloudflare blocks when the two disagree. So we keep the real
/// `Chrome/<major>` version (matching the client hints CF sees) and only strip
/// the embedded-WebView markers. See [_deriveJanitorWebViewUA] (Windows) and
/// [_deriveMobileJanitorWebViewUA] (Android/iOS).
String? get janitorWebViewUserAgent => _janitorWebViewUserAgent;

/// Builds a clean Windows desktop-Chrome UA pinned to [webView2Version]'s major
/// (e.g. `120.0.2210.91` → `Chrome/120.0.0.0`). Returns `null` if the version
/// can't be parsed, leaving the WebViews on their native UA.
String? _deriveJanitorWebViewUA(String webView2Version) {
  final major = RegExp(r'^\d+').firstMatch(webView2Version)?.group(0);
  if (major == null) return null;
  return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36';
}

/// Mobile counterpart of [_deriveJanitorWebViewUA]: takes the platform's default
/// WebView UA and strips the embedded-WebView markers Google's sign-in flow
/// rejects with `disallowed_useragent` — Android's `; wv` qualifier and the
/// `Version/4.0` WebView token — leaving a plain mobile-Chrome UA. The real
/// `Chrome/<major>` version is preserved, so it stays aligned with the client
/// hints Cloudflare validates. Returns `null` if the default UA is unavailable
/// or already clean (e.g. iOS WKWebView), leaving the WebViews on their native
/// UA → no override applied.
Future<String?> _deriveMobileJanitorWebViewUA() async {
  try {
    final defaultUa = await InAppWebViewController.getDefaultUserAgent();
    if (defaultUa.isEmpty) return null;
    final cleaned = defaultUa
        .replaceAll('; wv', '')
        .replaceAll(RegExp(r'\bVersion/\d+\.\d+\s+'), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    return cleaned == defaultUa ? null : cleaned;
  } catch (_) {
    return null;
  }
}

String? chatWebViewInitialFile() {
  if (_chatWebViewAssetBaseUrl != null) return null;
  if (chatWebViewUsesAndroidAssetLoader()) return null;
  return 'assets/chat_webview/index.html';
}

URLRequest? chatWebViewInitialUrlRequest() {
  final baseUrl = _chatWebViewAssetBaseUrl;
  if (baseUrl != null) {
    return URLRequest(url: WebUri.uri(baseUrl.uriValue.resolve('index.html')));
  }
  final androidUrl = chatWebViewAndroidAssetUrl();
  if (androidUrl != null) {
    return URLRequest(url: WebUri(androidUrl));
  }
  return null;
}

String? chatWebViewResolveLocalFileUrl(String? source) {
  if (source == null || source.isEmpty) return source;
  if (source.startsWith('data:') ||
      source.startsWith('http://') ||
      source.startsWith('https://')) {
    return source;
  }

  final path = _sourceToFilePath(source);
  if (path == null) return source;
  // iOS reinstalls/OS updates change the sandbox container UUID, so a path
  // persisted by an older build points at a directory that no longer exists.
  // Rebase it onto the current Glaze data root before serving.
  final healed = Platform.isIOS ? (resolveGlazeFilePath(path) ?? path) : path;
  final filePath = chatWebViewUsesAndroidAssetLoader()
      ? healed
      : File(healed).absolute.path;
  if (!_isInsideGlazeData(filePath)) {
    return source;
  }

  final fileBase = _localFileServingBaseUrl();
  if (fileBase == null) return source;

  final url = fileBase.uriValue.replace(
    path: '/__glaze_file__',
    queryParameters: {'path': filePath},
  );
  return url.toString();
}

Future<void> initChatWebViewEnvironment() async {
  if (kIsWeb) return;
  if (defaultTargetPlatform == TargetPlatform.android) {
    setChatWebViewAndroidFileRoot(await getAppDataDir());
    await _startChatWebViewLocalFileServer();
    _janitorWebViewUserAgent = await _deriveMobileJanitorWebViewUA();
    return;
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    // WKWebView loads `file://` index.html on an opaque origin, where ES
    // module imports of sibling files fail and local avatar/image files have
    // no http(s) URL to load from. Serve bundled chat assets and Glaze data
    // files over a loopback HTTP server so the page gets a real origin —
    // mirrors the Windows path, but assets come from `rootBundle` (the iOS
    // app bundle layout differs from the Windows `data/flutter_assets` tree).
    await getAppDataDir();
    await _startChatWebViewBundleServer();
    _janitorWebViewUserAgent = await _deriveMobileJanitorWebViewUA();
    return;
  }
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  if (_chatWebViewEnvironment != null) return;

  try {
    final availableVersion = await WebViewEnvironment.getAvailableVersion();
    if (availableVersion == null) {
      return;
    }
    _janitorWebViewUserAgent = _deriveJanitorWebViewUA(availableVersion);

    _chatWebViewEnvironment = await WebViewEnvironment.create();
    await _startChatWebViewAssetServer();
  } catch (_) {}
}

WebUri? _localFileServingBaseUrl() =>
    _chatWebViewLocalFileBaseUrl ?? _chatWebViewAssetBaseUrl;

Future<void> _startChatWebViewAssetServer() async {
  if (_chatWebViewAssetServer != null) return;

  final assetDir = _chatWebViewAssetDirectory();
  if (!assetDir.existsSync()) {
    return;
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _chatWebViewAssetServer = server;
  _chatWebViewAssetBaseUrl = WebUri('http://127.0.0.1:${server.port}/');
  unawaited(_serveChatWebViewAssets(server, assetDir));
}

/// Loopback server for Glaze user files on Android. Bundled chat assets keep
/// using [WebViewAssetLoader]; only avatars / generated images go through here.
Future<void> _startChatWebViewLocalFileServer() async {
  if (_chatWebViewLocalFileServer != null) return;

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _chatWebViewLocalFileServer = server;
  _chatWebViewLocalFileBaseUrl = WebUri('http://127.0.0.1:${server.port}/');
  unawaited(_serveChatWebViewLocalFiles(server));
}

/// Loopback server for iOS: serves bundled chat assets from [rootBundle] and
/// Glaze data files (avatars/generated images) from a `?path=` query, all over
/// one http origin so WKWebView can load ES modules and local images.
Future<void> _startChatWebViewBundleServer() async {
  if (_chatWebViewAssetServer != null) return;

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _chatWebViewAssetServer = server;
  _chatWebViewAssetBaseUrl = WebUri('http://127.0.0.1:${server.port}/');
  unawaited(_serveChatWebViewBundleAssets(server));
}

Future<void> _serveChatWebViewBundleAssets(HttpServer server) async {
  await for (final request in server) {
    try {
      if (request.uri.path == '/__glaze_file__') {
        await _serveGlazeDataFile(request);
        continue;
      }

      final path = _safeAssetPath(request.uri.path);
      if (path == null) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        continue;
      }

      // Asset keys always use forward slashes regardless of platform.
      final assetKey =
          'assets/chat_webview/${path.replaceAll(Platform.pathSeparator, '/')}';
      ByteData data;
      try {
        data = await rootBundle.load(assetKey);
      } catch (_) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }

      request.response.headers.contentType = _contentTypeFor(path);
      request.response.add(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      await request.response.close();
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }
}

Future<void> _serveChatWebViewLocalFiles(HttpServer server) async {
  await for (final request in server) {
    try {
      if (request.uri.path != '/__glaze_file__') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      await _serveGlazeDataFile(request);
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }
}

Directory _chatWebViewAssetDirectory() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final separator = Platform.pathSeparator;
  return Directory(
    [
      exeDir,
      'data',
      'flutter_assets',
      'assets',
      'chat_webview',
    ].join(separator),
  );
}

Future<void> _serveChatWebViewAssets(HttpServer server, Directory root) async {
  await for (final request in server) {
    try {
      if (request.uri.path == '/__glaze_file__') {
        await _serveGlazeDataFile(request);
        continue;
      }

      final path = _safeAssetPath(request.uri.path);
      if (path == null) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        continue;
      }

      final file = File('${root.path}${Platform.pathSeparator}$path');
      if (!file.existsSync()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }

      request.response.headers.contentType = _contentTypeFor(path);
      await request.response.addStream(file.openRead());
      await request.response.close();
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }
}

Future<void> _serveGlazeDataFile(HttpRequest request) async {
  final path = request.uri.queryParameters['path'];
  if (path == null || !_isInsideGlazeData(path)) {
    request.response.statusCode = HttpStatus.forbidden;
    await request.response.close();
    return;
  }

  final file = File(path).absolute;
  if (!file.existsSync()) {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
    return;
  }

  request.response.headers.contentType = _contentTypeFor(file.path);
  await request.response.addStream(file.openRead());
  await request.response.close();
}

String _normalizeAndroidPath(String path) => path.replaceAll('\\', '/');

String? _sourceToFilePath(String source) {
  if (source.startsWith('file://')) {
    try {
      return Uri.parse(source).toFilePath(windows: Platform.isWindows);
    } catch (_) {
      return source.replaceFirst('file:///', '').replaceFirst('file://', '');
    }
  }
  if (source.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(source)) {
    return source;
  }
  return null;
}

bool _isInsideGlazeData(String path) {
  if (chatWebViewUsesAndroidAssetLoader()) {
    final root = chatWebViewAndroidFileRoot;
    if (root == null || root.isEmpty) return false;
    final rootDir = _normalizeAndroidPath(root);
    final rootPrefix = rootDir.endsWith('/') ? rootDir : '$rootDir/';
    return _normalizeAndroidPath(path).startsWith(rootPrefix);
  }

  final root = _glazeDataDirectory().absolute.path;
  final file = File(path).absolute.path;
  final rootPrefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  if (Platform.isWindows) {
    return file.toLowerCase().startsWith(rootPrefix.toLowerCase());
  }
  return file.startsWith(rootPrefix);
}

Directory _glazeDataDirectory() {
  if (Platform.isAndroid) {
    final root = chatWebViewAndroidFileRoot;
    if (root != null && root.isNotEmpty) return Directory(root);
  }
  if (Platform.isIOS) {
    final root = cachedAppDataDir;
    if (root != null && root.isNotEmpty) return Directory(root);
  }
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      // Must track the same per-channel folder as getAppDataDir(), or the
      // file-serving root would point at another channel's install.
      return Directory(
        '$appData${Platform.pathSeparator}$glazeDataFolderName',
      );
    }
  }
  return Directory.current;
}

String? _safeAssetPath(String rawPath) {
  var path = Uri.decodeComponent(rawPath);
  if (path == '/' || path.isEmpty) return 'index.html';
  if (path.startsWith('/')) path = path.substring(1);
  path = path.replaceAll('/', Platform.pathSeparator);
  final segments = path.split(Platform.pathSeparator);
  if (segments.any((segment) => segment == '..' || segment.isEmpty)) {
    return null;
  }
  return path;
}

ContentType _contentTypeFor(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.html')) return ContentType.html;
  if (lower.endsWith('.js')) {
    return ContentType('application', 'javascript', charset: 'utf-8');
  }
  if (lower.endsWith('.css')) {
    return ContentType('text', 'css', charset: 'utf-8');
  }
  if (lower.endsWith('.svg')) return ContentType('image', 'svg+xml');
  if (lower.endsWith('.png')) return ContentType('image', 'png');
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return ContentType('image', 'jpeg');
  }
  if (lower.endsWith('.webp')) return ContentType('image', 'webp');
  if (lower.endsWith('.gif')) return ContentType('image', 'gif');
  return ContentType.binary;
}

@visibleForTesting
void setChatWebViewLocalFileBaseUrlForTesting(WebUri? baseUrl) {
  _chatWebViewLocalFileBaseUrl = baseUrl;
}

@visibleForTesting
void setChatWebViewAssetBaseUrlForTesting(WebUri? baseUrl) {
  _chatWebViewAssetBaseUrl = baseUrl;
}
