import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pasteboard/pasteboard.dart';

/// One image lifted off the clipboard: the raw bytes (what the composer
/// thumbnail paints) and the `data:` URL (what the message stores and the
/// request sends).
class ClipboardImage {
  final Uint8List bytes;
  final String dataUrl;

  const ClipboardImage({required this.bytes, required this.dataUrl});

  factory ClipboardImage.fromBytes(
    Uint8List bytes, {
    String? sourcePath,
    String? declaredMimeType,
  }) => ClipboardImage(
    bytes: bytes,
    dataUrl: encodeImageDataUrl(
      bytes,
      fallbackPath: sourcePath,
      fallbackMimeType: declaredMimeType,
    ),
  );
}

/// Reading images out of the system clipboard.
///
/// `Clipboard` from `flutter/services.dart` only ever sees `text/plain`, so
/// the bitmap a user copies out of a browser or a screenshot tool is invisible
/// to it. `pasteboard` reads the platform clipboard directly on all five
/// targets (Windows, macOS, Linux, Android, iOS).
///
/// Two shapes of "an image is on the clipboard" are handled, because both are
/// what people actually do:
///
/// * a **bitmap** — Ctrl+C in a browser, a screenshot tool, an image editor;
/// * **file paths** — Ctrl+C on files in Explorer/Finder. Those arrive as
///   paths, not pixels, so image files are read off disk. (Android hands back
///   `content://` URIs instead, which no `File` can open; they fall out at the
///   existence check and only the bitmap path applies there.)
class ClipboardImages {
  ClipboardImages._();

  static const Set<String> _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  };

  /// Every image sitting on the clipboard right now, capped at [limit]. Empty
  /// when the clipboard holds no image — which is the common case, so callers
  /// use it to decide between "attach this" and "let the normal text paste
  /// happen".
  static Future<List<ClipboardImage>> read({int limit = 1}) async {
    if (limit <= 0) return const [];
    final images = <ClipboardImage>[];

    final bitmap = await _readBitmap();
    if (bitmap != null) images.add(bitmap);

    if (images.length < limit) {
      for (final path in await _readFilePaths()) {
        if (images.length >= limit) break;
        final image = await _readImageFile(path);
        if (image != null) images.add(image);
      }
    }

    return images.take(limit).toList(growable: false);
  }

  static Future<ClipboardImage?> _readBitmap() async {
    try {
      final bytes = await Pasteboard.image;
      if (bytes == null || bytes.isEmpty) return null;
      return ClipboardImage.fromBytes(bytes);
    } catch (error) {
      debugPrint('[ClipboardImages] bitmap read failed: $error');
      return null;
    }
  }

  static Future<List<String>> _readFilePaths() async {
    try {
      return await Pasteboard.files();
    } catch (error) {
      debugPrint('[ClipboardImages] file list read failed: $error');
      return const [];
    }
  }

  static Future<ClipboardImage?> _readImageFile(String path) async {
    final lower = path.toLowerCase();
    if (!_imageExtensions.any(lower.endsWith)) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return ClipboardImage.fromBytes(bytes, sourcePath: path);
    } catch (error) {
      debugPrint('[ClipboardImages] file read failed: $error');
      return null;
    }
  }
}

/// Wraps raw image [bytes] as a `data:` URL.
///
/// The MIME type is sniffed from the magic bytes rather than taken from what
/// the source claims: a clipboard bitmap has no filename, a keyboard reports
/// whichever of the requested types it feels like, and a mislabelled type is
/// what makes a provider reject an otherwise valid multimodal request. Only
/// when the sniff recognises nothing does [fallbackMimeType] — then
/// [fallbackPath]'s extension — get a say.
String encodeImageDataUrl(
  Uint8List bytes, {
  String? fallbackPath,
  String? fallbackMimeType,
}) {
  final mime =
      sniffImageMimeType(bytes) ??
      _normalizeMimeType(fallbackMimeType) ??
      _mimeFromPath(fallbackPath);
  return 'data:$mime;base64,${base64Encode(bytes)}';
}

/// A declared type, kept only when it names an image format at all — anything
/// else would be carried straight into the request as a lie about the bytes.
String? _normalizeMimeType(String? mimeType) {
  final normalized = mimeType?.trim().toLowerCase();
  if (normalized == null || !normalized.startsWith('image/')) return null;
  // Android keyboards send `image/jpg`, which is not a registered type; every
  // provider expects `image/jpeg`.
  return normalized == 'image/jpg' ? 'image/jpeg' : normalized;
}

/// The MIME type [bytes] start with, or null when the header matches none of
/// the formats a model is willing to read.
String? sniffImageMimeType(Uint8List bytes) {
  bool startsWith(List<int> magic, {int offset = 0}) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (startsWith(const [0x42, 0x4D])) return 'image/bmp';
  // RIFF....WEBP
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], offset: 8)) {
    return 'image/webp';
  }
  return null;
}

String _mimeFromPath(String? path) {
  final lower = path?.toLowerCase() ?? '';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  return 'image/png';
}
