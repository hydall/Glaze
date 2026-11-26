import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/utils/platform_paths.dart';
import '../image_gen_capabilities.dart';
import '../image_gen_models.dart';
import 'image_tag_markup.dart';
import 'novelai_reference_image.dart';
import 'reference_matcher.dart';

/// Per-provider preprocessing a collected reference needs before it is sent.
///
/// - [none] — send the file bytes as they are.
/// - [downscaleJpeg] — rout.my rejects oversized JSON, so it is shrunk first.
/// - [novelAiPad] — NovelAI V4.5 takes Precise References only at three canvas
///   sizes with the image fitted and black-padded; a raw avatar is a 400.
/// - [novelAiCut] — NovelAI V5 takes them cut to one of its 97 sizes.
enum _ReferenceTransform { none, downscaleJpeg, novelAiPad, novelAiCut }

/// Builds the reference-image list for one generation request.
///
/// Order follows https://github.com/0xl0cal/sillyimages: character avatar,
/// persona avatar, matched library references, then previously generated
/// context images. The list is clipped to what the active provider/model
/// accepts ([providerMaxReferences]).
///
/// Every entry is a flat map so the provider clients can stay independent of
/// this class: `name`, `image` (bare base64), `mime`, `description`,
/// `source` (`char` | `user` | `additional` | `context`) and, for a library
/// entry that picks one, its NovelAI Precise Reference `novelaiType`.
class ImageReferenceCollector {
  const ImageReferenceCollector();

  Future<List<Map<String, String>>> collect({
    required ImageGenSettings settings,
    required String prompt,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    List<Map<String, String>> leadingReferences = const [],
  }) async {
    final maxRefs = providerMaxReferences(settings);
    if (maxRefs <= 0) return const [];

    final transform = _transformFor(settings);

    final refs = <Map<String, String>>[];
    final seen = <String>{};

    void add(Map<String, String>? entry) {
      if (entry == null) return;
      final image = entry['image'] ?? '';
      if (image.isEmpty || !seen.add(image)) return;
      refs.add(entry);
    }

    // References handed over by a plugin come first, in their own order: a
    // gallery pose reference is meant to steer the whole picture, faces after
    // it. The same bytes are never sent twice, even if they are also an
    // avatar or a library entry.
    for (final raw in leadingReferences) {
      final image = (raw['image'] ?? '').trim();
      if (image.isEmpty) continue;
      final normalized = await _normalizeBase64(
        image,
        mime: raw['mime'] ?? '',
        transform: transform,
      );
      if (normalized == null) continue;
      final name = (raw['name'] ?? '').trim();
      final description = (raw['description'] ?? '').trim();
      add({
        'name': name,
        'image': normalized.$1,
        'mime': normalized.$2,
        'description': description.isEmpty ? name : description,
        'source': 'additional',
      });
    }

    if (settings.sendsCharAvatarImage && character?.avatarPath != null) {
      add(
        await _fromFile(
          character!.avatarPath!,
          name: character.name,
          description: character.name,
          source: 'char',
          transform: transform,
        ),
      );
    }
    if (settings.sendUserAvatar && persona?.avatarPath != null) {
      add(
        await _fromFile(
          persona!.avatarPath!,
          name: persona.name,
          description: persona.name,
          source: 'user',
          transform: transform,
        ),
      );
    }

    for (final ref in matchReferences(prompt, settings.references)) {
      final stripped = _stripDataUrl(ref.imageData);
      if (stripped.isEmpty) continue;
      var image = stripped;
      var mime = _mimeFromDataUrl(ref.imageData);
      if (_isNovelAi(transform)) {
        final prepared = await _prepareNovelAiBase64(stripped, transform);
        if (prepared != null) {
          image = prepared;
          mime = 'image/png';
        }
      }
      add({
        'name': ref.name.trim(),
        'image': image,
        'mime': mime,
        'description': ref.description.trim().isEmpty
            ? ref.name.trim()
            : ref.description.trim(),
        'source': 'additional',
        if (ref.novelaiType.isNotEmpty) 'novelaiType': ref.novelaiType,
      });
    }

    if (settings.imageContextEnabled && recentImageContexts != null) {
      final count = settings.imageContextCount.clamp(1, 3);
      for (final context in recentImageContexts.take(count)) {
        final path = ImageTagMarkup.normalizeImageResultPayload(context);
        add(
          await _fromFile(
            path,
            name: 'context',
            description: '',
            source: 'context',
            transform: transform,
          ),
        );
      }
    }

    return refs.length > maxRefs ? refs.sublist(0, maxRefs) : refs;
  }

  /// The preprocessing the active provider/model needs. Only reached when the
  /// provider takes references at all ([providerMaxReferences] gates it).
  static _ReferenceTransform _transformFor(ImageGenSettings settings) {
    if (settings.apiType == ImageGenApiType.routmy &&
        !isRoutmyGeminiModel(settings.routmyModel)) {
      return _ReferenceTransform.downscaleJpeg;
    }
    final novelAiModel = settings.novelai.model;
    if (settings.apiType == ImageGenApiType.novelai &&
        NovelAIConstants.supportsReferences(novelAiModel)) {
      return NovelAIConstants.referenceIsCut(novelAiModel)
          ? _ReferenceTransform.novelAiCut
          : _ReferenceTransform.novelAiPad;
    }
    return _ReferenceTransform.none;
  }

  static bool _isNovelAi(_ReferenceTransform transform) =>
      transform == _ReferenceTransform.novelAiPad ||
      transform == _ReferenceTransform.novelAiCut;

  /// Fits [bytes] for NovelAI V4.5 or V5; null when they cannot be decoded.
  static Future<Uint8List?> _prepareNovelAi(
    Uint8List bytes,
    _ReferenceTransform transform,
  ) => compute(
    transform == _ReferenceTransform.novelAiCut
        ? cutNovelAiReference
        : padNovelAiReference,
    bytes,
  );

  Future<String?> _prepareNovelAiBase64(
    String base64Image,
    _ReferenceTransform transform,
  ) async {
    try {
      final prepared = await _prepareNovelAi(
        base64Decode(base64Image),
        transform,
      );
      return prepared == null ? null : base64Encode(prepared);
    } catch (_) {
      return null;
    }
  }

  /// Applies the provider's preprocessing to a reference that already
  /// arrived as base64 (a plugin's `referenceImages` / `characters`).
  Future<(String, String)?> _normalizeBase64(
    String image, {
    required String mime,
    required _ReferenceTransform transform,
  }) async {
    try {
      final bytes = base64Decode(_stripDataUrl(image));
      switch (transform) {
        case _ReferenceTransform.none:
          return (base64Encode(bytes), mime.isEmpty ? 'image/png' : mime);
        case _ReferenceTransform.downscaleJpeg:
          final resized =
              await compute(
                _decodeAndResizeJpeg,
                _ResizeArgs(bytes, 512, 85),
              ) ??
              bytes;
          return (base64Encode(resized), 'image/jpeg');
        case _ReferenceTransform.novelAiPad:
        case _ReferenceTransform.novelAiCut:
          final prepared = await _prepareNovelAi(bytes, transform) ?? bytes;
          return (base64Encode(prepared), 'image/png');
      }
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
        case _ReferenceTransform.novelAiCut:
          final prepared = await _prepareNovelAi(bytes, transform) ?? bytes;
          return (base64Encode(prepared), 'image/png');
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
