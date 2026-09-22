import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/utils/platform_paths.dart';
import '../image_gen_capabilities.dart';
import '../image_gen_models.dart';
import 'image_tag_markup.dart';
import 'reference_matcher.dart';

/// Per-provider preprocessing a collected reference needs before it is sent.
///
/// - [none] — send the file bytes as they are.
/// - [downscaleJpeg] — rout.my rejects oversized JSON, so it is shrunk first.
/// - [novelAiPad] — NovelAI's Director Tools take only three canvas sizes with
///   the image fitted and black-padded; a raw avatar is rejected with a 400.
enum _ReferenceTransform { none, downscaleJpeg, novelAiPad }

/// Builds the reference-image list for one generation request.
///
/// Order follows https://github.com/0xl0cal/sillyimages: character avatar,
/// persona avatar, matched library references, then previously generated
/// context images. The list is clipped to what the active provider/model
/// accepts ([providerMaxReferences]).
///
/// Every entry is a flat map so the provider clients can stay independent of
/// this class: `name`, `image` (bare base64), `mime`, `description` and
/// `source` (`char` | `user` | `additional` | `context`).
class ImageReferenceCollector {
  const ImageReferenceCollector();

  Future<List<Map<String, String>>> collect({
    required ImageGenSettings settings,
    required String prompt,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
  }) async {
    final maxRefs = providerMaxReferences(settings);
    if (maxRefs <= 0) return const [];

    final transform = _transformFor(settings);

    final refs = <Map<String, String>>[];

    if (settings.sendCharAvatar && character?.avatarPath != null) {
      final entry = await _fromFile(
        character!.avatarPath!,
        name: character.name,
        description: character.name,
        source: 'char',
        transform: transform,
      );
      if (entry != null) refs.add(entry);
    }
    if (settings.sendUserAvatar && persona?.avatarPath != null) {
      final entry = await _fromFile(
        persona!.avatarPath!,
        name: persona.name,
        description: persona.name,
        source: 'user',
        transform: transform,
      );
      if (entry != null) refs.add(entry);
    }

    for (final ref in matchReferences(prompt, settings.references)) {
      final stripped = _stripDataUrl(ref.imageData);
      if (stripped.isEmpty) continue;
      var image = stripped;
      var mime = _mimeFromDataUrl(ref.imageData);
      if (transform == _ReferenceTransform.novelAiPad) {
        final padded = await _padNovelAiBase64(stripped);
        if (padded != null) {
          image = padded;
          mime = 'image/png';
        }
      }
      refs.add({
        'name': ref.name.trim(),
        'image': image,
        'mime': mime,
        'description': ref.description.trim().isEmpty
            ? ref.name.trim()
            : ref.description.trim(),
        'source': 'additional',
      });
    }

    if (settings.imageContextEnabled && recentImageContexts != null) {
      final count = settings.imageContextCount.clamp(1, 3);
      for (final context in recentImageContexts.take(count)) {
        final path = ImageTagMarkup.normalizeImageResultPayload(context);
        final entry = await _fromFile(
          path,
          name: 'context',
          description: '',
          source: 'context',
          transform: transform,
        );
        if (entry != null) refs.add(entry);
      }
    }

    return refs.length > maxRefs ? refs.sublist(0, maxRefs) : refs;
  }

  /// The preprocessing the active provider/model needs. Only reached when the
  /// provider takes references at all ([providerMaxReferences] gates it).
  static _ReferenceTransform _transformFor(ImageGenSettings settings) {
    if (settings.apiType == ImageGenApiType.routmy) {
      return _ReferenceTransform.downscaleJpeg;
    }
    if (settings.apiType == ImageGenApiType.novelai &&
        NovelAIConstants.supportsReferences(settings.novelai.model)) {
      return _ReferenceTransform.novelAiPad;
    }
    return _ReferenceTransform.none;
  }

  Future<String?> _padNovelAiBase64(String base64Image) async {
    try {
      final padded = await compute(
        padNovelAiReference,
        base64Decode(base64Image),
      );
      return padded == null ? null : base64Encode(padded);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>?> _fromFile(
    String path, {
    required String name,
    required String description,
    required String source,
    required _ReferenceTransform transform,
  }) async {
    final encoded = await _fileToBase64(path, transform);
    if (encoded == null) return null;
    return {
      'name': name,
      'image': encoded.$1,
      'mime': encoded.$2,
      'description': description,
      'source': source,
    };
  }

  /// Reads [path] and returns `(base64, mime)`, or null when it is missing.
  Future<(String, String)?> _fileToBase64(
    String path,
    _ReferenceTransform transform,
  ) async {
    try {
      final resolved = resolveGlazeFilePath(path) ?? path;
      final file = File(resolved);
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();

      switch (transform) {
        case _ReferenceTransform.none:
          return (base64Encode(bytes), _mimeFromPath(path));
        case _ReferenceTransform.downscaleJpeg:
          final resized =
              await compute(
                _decodeAndResizeJpeg,
                _ResizeArgs(bytes, 512, 85),
              ) ??
              bytes;
          return (base64Encode(resized), 'image/jpeg');
        case _ReferenceTransform.novelAiPad:
          final padded = await compute(padNovelAiReference, bytes) ?? bytes;
          return (base64Encode(padded), 'image/png');
      }
    } catch (_) {
      return null;
    }
  }

  static String _stripDataUrl(String dataUrl) {
    final commaIndex = dataUrl.indexOf(',');
    if (commaIndex == -1) return dataUrl;
    return dataUrl.substring(commaIndex + 1);
  }

  static String _mimeFromDataUrl(String dataUrl) {
    if (!dataUrl.startsWith('data:')) return 'image/png';
    final end = dataUrl.indexOf(';');
    return end > 5 ? dataUrl.substring(5, end) : 'image/png';
  }

  static String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }
}

/// Fits [bytes] inside the NovelAI Character-Reference canvas for its
/// orientation and re-encodes it as PNG on a black background.
///
/// Director Tools accept only 1024x1536, 1536x1024 or 1472x1472 with the image
/// scaled to fit and black-padded (NovelAI image OpenAPI spec); a raw avatar of
/// any other size is rejected with a 400. The image is never cropped — the
/// whole character is the reference. Returns null when the bytes cannot be
/// decoded, so the caller can fall back to sending them unchanged.
Uint8List? padNovelAiReference(Uint8List bytes) {
  try {
    final src = img.decodeImage(bytes);
    if (src == null) return null;

    final (canvasWidth, canvasHeight) = NovelAIConstants.referenceCanvas(
      src.width,
      src.height,
    );

    final scale = min(canvasWidth / src.width, canvasHeight / src.height);
    final targetWidth = (src.width * scale).round().clamp(1, canvasWidth);
    final targetHeight = (src.height * scale).round().clamp(1, canvasHeight);

    final resized = img.copyResize(
      src,
      width: targetWidth,
      height: targetHeight,
      interpolation: img.Interpolation.linear,
    );

    final canvas = img.Image(width: canvasWidth, height: canvasHeight);
    img.fill(canvas, color: img.ColorRgb8(0, 0, 0));
    img.compositeImage(
      canvas,
      resized,
      dstX: (canvasWidth - targetWidth) ~/ 2,
      dstY: (canvasHeight - targetHeight) ~/ 2,
    );
    return Uint8List.fromList(img.encodePng(canvas));
  } catch (_) {
    return null;
  }
}

// ─── Isolate helpers for JPEG resize ────────────────────────────────────────

class _ResizeArgs {
  const _ResizeArgs(this.bytes, this.maxSide, this.jpegQuality);
  final Uint8List bytes;
  final int maxSide;
  final int jpegQuality;
}

/// Runs in a separate isolate via [compute]. Returns null on any error so the
/// caller can fall back to the raw bytes.
Uint8List? _decodeAndResizeJpeg(_ResizeArgs args) {
  try {
    final src = img.decodeImage(args.bytes);
    if (src == null) return null;
    final resized = img.copyResize(
      src,
      width: src.width >= src.height ? args.maxSide : -1,
      height: src.height > src.width ? args.maxSide : -1,
      interpolation: img.Interpolation.linear,
    );
    return Uint8List.fromList(
      img.encodeJpg(resized, quality: args.jpegQuality),
    );
  } catch (_) {
    return null;
  }
}
