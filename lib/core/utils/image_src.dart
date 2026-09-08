import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

import 'platform_paths.dart';

const Map<String, String> _baseImageFetchHeaders = {
  'User-Agent': 'Mozilla/5.0 (compatible) AppleWebKit/537.36 (KHTML, like Gecko)'
      ' Chrome/124.0.0.0 Safari/537.36',
  'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
};

/// Headers for a remote image fetch, including a same-origin `Referer`.
///
/// The chat WebView loads messages from a real `http(s)` origin
/// (`appassets.androidplatform.net` on Android, a `127.0.0.1` loopback
/// server on iOS/Windows), so Chromium attaches a `Referer` when it fetches
/// `<img>` sub-resources. The native viewer's bare `dart:io` request has no
/// page context and sends none, and some hotlink-protected CDNs 403 a
/// referer-less request while allowing the WebView's — sending the image's
/// own origin as `Referer` satisfies that check without needing to know the
/// real embedding page.
Map<String, String> _imageFetchHeaders(String url) {
  try {
    final origin = Uri.parse(url).origin;
    if (origin.isEmpty) return _baseImageFetchHeaders;
    return {..._baseImageFetchHeaders, 'Referer': '$origin/'};
  } catch (_) {
    return _baseImageFetchHeaders;
  }
}

/// Turns an image `src` as it appears inside the chat WebView into an
/// [ImageProvider] usable by native Flutter widgets (the full-screen viewer).
///
/// The WebView deals in five shapes and every one of them has to be mapped
/// back, otherwise the viewer opens onto a blank screen:
///
/// * `data:` URIs — inline base64 *or* percent-encoded payloads.
/// * `http(s)://127.0.0.1:<port>/__glaze_file__?path=…` — the loopback file
///   server that serves Glaze data files to the WebView (Android/iOS/Windows).
///   Going back out over HTTP would work, but reading the file directly is
///   cheaper and keeps working if the server was restarted with a new port
///   after the message was rendered.
/// * remote `http(s)` URLs — markdown images in bot messages.
/// * `file://` URLs.
/// * bare absolute/relative paths.
///
/// Returns `null` when [src] is empty or cannot be interpreted; callers should
/// surface that instead of opening an empty viewer.
ImageProvider? imageProviderForSrc(String src) {
  final trimmed = src.trim();
  if (trimmed.isEmpty) return null;

  if (trimmed.startsWith('data:')) {
    try {
      final data = Uri.parse(trimmed).data;
      if (data == null) return null;
      final bytes = data.contentAsBytes();
      if (bytes.isEmpty) return null;
      return MemoryImage(bytes);
    } catch (_) {
      return null;
    }
  }

  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    final localPath = glazeFilePathFromLoopbackUrl(trimmed);
    if (localPath != null) return _fileProvider(localPath);
    // CachedNetworkImageProvider (not NetworkImage) so the viewer shares the
    // cache the rest of the app already fills — a picture the WebView just
    // displayed usually opens instantly instead of being fetched twice.
    // The UA matters: several image CDNs answer 403 to the bare Dart client
    // (`Dart/3.x (dart:io)`) while happily serving the same URL to the WebView,
    // which is exactly the "renders in the message, blank in the viewer" case.
    return CachedNetworkImageProvider(trimmed, headers: _imageFetchHeaders(trimmed));
  }

  return _fileProvider(imageSrcToFilePath(trimmed));
}

/// The on-disk path behind a chat WebView loopback file URL
/// (`http://127.0.0.1:<port>/__glaze_file__?path=…`), or `null` when [url] is
/// an ordinary remote URL.
String? glazeFilePathFromLoopbackUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.host != '127.0.0.1' && uri.host != 'localhost') return null;
  if (uri.path != '/__glaze_file__') return null;
  final path = uri.queryParameters['path'];
  if (path == null || path.isEmpty) return null;
  return path;
}

/// Converts a `file://` URL (or a plain path) to an on-disk path.
String imageSrcToFilePath(String src) {
  if (!src.startsWith('file://')) return src;
  try {
    return Uri.parse(src).toFilePath(windows: Platform.isWindows);
  } catch (_) {
    final withoutScheme = src.replaceFirst('file://', '');
    if (Platform.isWindows) return withoutScheme.replaceFirst('/', '');
    return withoutScheme.startsWith('/') ? withoutScheme : '/$withoutScheme';
  }
}

FileImage? _fileProvider(String path) {
  // Rebases stale absolute paths (iOS container UUID changes) and joins
  // relative paths onto the current data root — without this a perfectly
  // valid stored image resolves to a file that does not exist.
  final resolved = resolveGlazeFilePath(path);
  if (resolved == null || resolved.isEmpty) return null;
  return FileImage(File(resolved));
}
