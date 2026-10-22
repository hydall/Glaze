import 'dart:convert';

import '../../../core/constants/image_gen_patterns.dart';

/// The images one image block carries, which of them is on screen, and the
/// instruction that produced them.
///
/// A finished block is stored as an `<img data-iig-…>` element
/// ([ImageTagMarkup.encodeResultElement]); this codec is what a pending block
/// and every message written before that form existed are spelled with. A
/// block keeps every image it has generated so the reader can page back
/// through them, so the payload is a list rather than a single path:
///
///     [IMG:RESULT:/a.png;;*/b.png|{"prompt":"…"}]
///     [IMG:GEN:@/a.png;;/b.png|{"prompt":"…"}]
///
/// Rules that keep older messages readable and newer ones unambiguous:
///
/// * the instruction is always the last segment, so a `|` inside a prompt is
///   never mistaken for a separator;
/// * a result block with one image keeps the historical `path|instruction`
///   spelling, and gains `;;` separators only once it holds a second image;
/// * `*` marks the visible image, and is only written when there is more than
///   one — without it the first image is the visible one;
/// * a pending block introduces its carried images with `@`, because its
///   payload is otherwise a bare instruction (JSON or plain prompt text) that
///   must keep parsing exactly as before.
///
/// [presentation] is not part of the tag payload: it rides on the element
/// forms and the error card (see [ImageTagMarkup.presentationAttributes]).
class ImageBlockPayload {
  const ImageBlockPayload({
    this.paths = const [],
    this.activeIndex = 0,
    this.instruction = '',
    this.presentation = const {},
  });

  /// Every image generated for this block, oldest first.
  final List<String> paths;

  /// Position in [paths] of the image the message shows.
  final int activeIndex;

  /// Instruction JSON (or raw prompt text) carried by the block.
  final String instruction;

  /// The attributes the author put on the `<img>` besides the ones Glaze owns
  /// (see [ImageTagMarkup.presentationAttributes]), unescaped.
  final Map<String, String> presentation;

  static const String _separator = ';;';

  /// Separator between the images one block carries, in the tag payload and in
  /// the `data-iig-variants` attribute alike. Mirrored by the WebView
  /// formatter (`IMG_VARIANT_SEPARATOR`).
  static const String variantSeparator = _separator;
  static const String _activeMarker = '*';
  static const String _pendingMarker = '@';

  /// The image on screen, or empty when the block has none yet.
  String get activePath => paths.isEmpty
      ? ''
      : paths[activeIndex.clamp(0, paths.length - 1)];

  bool get hasVariants => paths.length > 1;

  /// Reads a `[IMG:RESULT:…]` payload, whose leading segment is the path list.
  static ImageBlockPayload parseResult(String payload) {
    final pipeIdx = payload.indexOf('|');
    final head = pipeIdx == -1 ? payload : payload.substring(0, pipeIdx);
    final instruction = pipeIdx == -1 ? '' : payload.substring(pipeIdx + 1);
    return _fromPathList(head, instruction);
  }

  /// Reads a `[IMG:GEN:…]` payload: a bare instruction, or images carried
  /// through the regeneration behind the `@` marker.
  static ImageBlockPayload parsePending(String payload) {
    if (!payload.startsWith(_pendingMarker)) {
      return ImageBlockPayload(instruction: payload);
    }
    final rest = payload.substring(_pendingMarker.length);
    final pipeIdx = rest.indexOf('|');
    final head = pipeIdx == -1 ? rest : rest.substring(0, pipeIdx);
    final instruction = pipeIdx == -1 ? '' : rest.substring(pipeIdx + 1);
    return _fromPathList(head, instruction);
  }

  static ImageBlockPayload _fromPathList(String head, String instruction) {
    final paths = <String>[];
    var active = 0;
    for (final entry in head.split(_separator)) {
      if (entry.isEmpty) continue;
      if (entry.startsWith(_activeMarker)) {
        active = paths.length;
        paths.add(entry.substring(_activeMarker.length));
      } else {
        paths.add(entry);
      }
    }
    return ImageBlockPayload(
      paths: paths,
      activeIndex: paths.isEmpty ? 0 : active.clamp(0, paths.length - 1),
      instruction: instruction,
    );
  }

  String encodeResult() {
    final head = _encodePathList();
    return instruction.isEmpty ? head : '$head|$instruction';
  }

  String encodePending() {
    if (paths.isEmpty) return instruction;
    final head = '$_pendingMarker${_encodePathList()}';
    return instruction.isEmpty ? head : '$head|$instruction';
  }

  String _encodePathList() {
    if (paths.length < 2) return paths.isEmpty ? '' : paths.first;
    final active = activeIndex.clamp(0, paths.length - 1);
    return [
      for (var i = 0; i < paths.length; i++)
        i == active ? '$_activeMarker${paths[i]}' : paths[i],
    ].join(_separator);
  }

  /// Appends [path] and puts it on screen — what a finished (re)generation
  /// does, so the previous images stay reachable through the block switcher.
  ImageBlockPayload withNewImage(String path) => ImageBlockPayload(
    paths: [...paths, path],
    activeIndex: paths.length,
    instruction: instruction,
    presentation: presentation,
  );

  ImageBlockPayload withActiveIndex(int index) => ImageBlockPayload(
    paths: paths,
    activeIndex: paths.isEmpty ? 0 : index.clamp(0, paths.length - 1),
    instruction: instruction,
    presentation: presentation,
  );

  ImageBlockPayload withPaths(List<String> newPaths, {int? activeIndex}) =>
      ImageBlockPayload(
        paths: newPaths,
        activeIndex: newPaths.isEmpty
            ? 0
            : (activeIndex ?? this.activeIndex).clamp(0, newPaths.length - 1),
        instruction: instruction,
        presentation: presentation,
      );

  ImageBlockPayload withInstruction(String value) => ImageBlockPayload(
    paths: paths,
    activeIndex: activeIndex,
    instruction: value,
    presentation: presentation,
  );

  ImageBlockPayload withPresentation(Map<String, String> value) =>
      ImageBlockPayload(
        paths: paths,
        activeIndex: activeIndex,
        instruction: instruction,
        presentation: value,
      );

  /// The path list on its own, as carried through an error card.
  String encodePathList() => _encodePathList();

  static List<String> decodePathList(String value) =>
      _fromPathList(value, '').paths;
}

/// One finished image block written in the stored `<img data-iig-…>` form:
/// the span it occupies and the payload its attributes carry.
class ImageResultElement {
  const ImageResultElement(this.start, this.end, this.payload);

  final int start;
  final int end;
  final ImageBlockPayload payload;
}

/// One pending image tag located in a message: the span it occupies and the
/// raw instruction payload it carries.
class PendingImageTag {
  const PendingImageTag(
    this.start,
    this.end,
    this.payload, {
    this.presentation = const {},
  });

  /// Offset of the first character of the tag inside the scanned text.
  final int start;

  /// Offset just past the last character of the tag.
  final int end;

  /// Raw instruction payload — the `data-iig-instruction` attribute value or
  /// whatever follows `[IMG:GEN:`. Empty when the tag carries no instruction.
  final String payload;

  /// The author's attributes of an `<img>` form; empty for a bare tag.
  final Map<String, String> presentation;
}

/// State of one image block inside a message.
enum ImageBlockKind {
  /// `[IMG:GEN…]` — still waiting for its image.
  pending,

  /// `[IMG:RESULT:…]` — the image arrived and is on disk.
  result,

  /// `[IMG:ERROR:…]` — the image did not arrive; the block offers a retry.
  error,
}

/// One image block of a message, whatever state it is in. Its position in
/// [ImageTagMarkup.scanImageBlocks] is the index the chat webview tags each
/// rendered block with, so a per-image action addresses exactly this block.
class ImageBlock {
  const ImageBlock({
    required this.start,
    required this.end,
    required this.kind,
    required this.instruction,
    this.imagePath = '',
    this.paths = const [],
    this.activeIndex = 0,
    this.presentation = const {},
  });

  final int start;
  final int end;
  final ImageBlockKind kind;

  /// Instruction JSON carried by the block, or empty when it has none.
  final String instruction;

  /// Visible image of a finished block; empty for the other kinds.
  final String imagePath;

  /// Every image this block has generated, oldest first. A pending or failed
  /// block carries the images of its earlier attempts here.
  final List<String> paths;

  /// Position of [imagePath] inside [paths].
  final int activeIndex;

  /// The author's attributes of the block's `<img>`, kept across its states.
  final Map<String, String> presentation;

  ImageBlockPayload get payload => ImageBlockPayload(
    paths: paths,
    activeIndex: activeIndex,
    instruction: instruction,
    presentation: presentation,
  );

  /// The block written back as a pending tag, prompt and earlier images
  /// included, so a regeneration neither asks the model for the prompt again
  /// nor loses the images the block already holds.
  String get asPendingTag => ImageTagMarkup.pendingTag(payload);
}

/// Pure text transformations for image-gen markup: the `<img data-iig-…>`
/// element a finished block is stored as, the `[IMG:GEN]` / `[IMG:ERROR]` tags
/// of a block that has no picture yet, and the `[IMG:RESULT:]` of messages
/// written before the element form existed. Has no dependency on image
/// generation, file I/O, or network — only on [ImgGenPatterns] and JSON
/// encoding, so the paths it moves around are stored exactly as handed in
/// (relative to the Glaze data root, as every caller writes them).
///
/// Every operation is anchored on [scanPendingTags], a single document-ordered
/// pass over the four tag spellings. Resolving one tag rewrites only that tag's
/// span, so the other pending tags of the same message survive untouched —
/// a message with several images keeps every block until its own image lands.
class ImageTagMarkup {
  ImageTagMarkup._();

  /// Pending image tags in document order, deduplicated across the spellings
  /// that can match the same `<img>` element.
  ///
  /// HTML forms win over the bare `[IMG:GEN…]` they wrap, so an
  /// `<img data-iig-instruction='…' src="[IMG:GEN]">` counts once and is
  /// replaced as a whole element.
  ///
  /// A tag inside a reasoning block is skipped (INV-IG11): the model writing
  /// "then I'll put [IMG:GEN:…] here" while it thinks is planning aloud, not
  /// asking for a picture. This is the single gate every generation goes
  /// through — [hasImageGenTags], [scanImageBlocks], the replace/reset helpers
  /// and `ImageGenProcessor` all read the message through it — so a reasoning
  /// tag is not generated, not turned into an error card, and not counted in
  /// the block numbering the WebView addresses.
  static List<PendingImageTag> scanPendingTags(String text) {
    if (!text.contains('[IMG:GEN') && !text.contains('data-iig-instruction')) {
      return const [];
    }

    final reasoning = ImgGenPatterns.reasoningSpans(text);
    final tags = <PendingImageTag>[];
    bool overlapsExisting(int start, int end) =>
        tags.any((tag) => start < tag.end && tag.start < end);

    void collect(
      RegExp pattern,
      PendingImageTag Function(RegExpMatch) tagOf, {
      bool Function(String element)? accept,
    }) {
      for (final match in pattern.allMatches(text)) {
        if (overlapsExisting(match.start, match.end)) continue;
        if (ImgGenPatterns.overlapsSpan(reasoning, match.start, match.end)) {
          continue;
        }
        if (accept != null && !accept(match.group(0)!)) continue;
        tags.add(tagOf(match));
      }
    }

    // The same `<img data-iig-instruction…>` element is the stored form of a
    // *finished* block once its `src` names an image, so only the ones still
    // waiting for a picture count as pending here.
    collect(
      ImgGenPatterns.htmlIigTagRegex,
      _pendingElementTag,
      accept: ImgGenPatterns.isPendingIigElement,
    );
    collect(
      ImgGenPatterns.htmlIigTagDoubleRegex,
      _pendingElementTag,
      accept: ImgGenPatterns.isPendingIigElement,
    );
    // `<img src="[IMG:GEN:…]">` without the instruction attribute: the payload
    // lives in the src, but the whole element is what gets replaced.
    collect(
      ImgGenPatterns.imgSrcGenRegex,
      (m) => PendingImageTag(
        m.start,
        m.end,
        ImgGenPatterns.imgGenRegex.firstMatch(m.group(0)!)?.group(1) ?? '',
        presentation: presentationOf(m.group(0)!),
      ),
    );
    collect(
      ImgGenPatterns.imgGenRegex,
      (m) => PendingImageTag(m.start, m.end, m.group(1) ?? ''),
    );

    tags.sort((a, b) => a.start.compareTo(b.start));
    return tags;
  }

  /// A pending `<img data-iig-…>` element as a tag. The images a reset
  /// block carries ride in [variantsAttribute], the same as on a finished one
  /// (see [pendingTag]).
  static PendingImageTag _pendingElementTag(RegExpMatch match) {
    final element = match.group(0)!;
    final attributes = ImgGenPatterns.imgAttributes(element);
    final instruction = _unescapeAttribute(
      attributes[instructionAttribute] ?? '',
    );
    final paths = ImageBlockPayload.decodePathList(
      _unescapeAttribute(attributes[variantsAttribute] ?? ''),
    );
    final payload = paths.isEmpty
        ? instruction
        : ImageBlockPayload(
            paths: paths,
            activeIndex:
                (int.tryParse(attributes[variantIndexAttribute] ?? '') ?? 0)
                    .clamp(0, paths.length - 1),
            instruction: instruction,
          ).encodePending();
    return PendingImageTag(
      match.start,
      match.end,
      payload,
      presentation: _presentationFrom(attributes),
    );
  }

  static bool hasImageGenTags(String text) => scanPendingTags(text).isNotEmpty;

  /// Attributes of an author's `<img>` that only decide how the picture looks.
  ///
  /// A card lays its picture out with them — `<img style="position:absolute;
  /// width:100%;height:100%" …>` inside a box with a fixed aspect ratio — so a
  /// block keeps them through every state it passes: the stored element, a
  /// reset back to pending, an error card. Without them the picture drops out
  /// of the layout it was written for (INV-IG14). Everything else on the
  /// element either belongs to Glaze or is not ours to carry.
  static const List<String> presentationAttributes = [
    'style',
    'class',
    'alt',
    'title',
    'width',
    'height',
  ];

  /// The [presentationAttributes] of one `<img …>` element, unescaped.
  static Map<String, String> presentationOf(String element) =>
      _presentationFrom(ImgGenPatterns.imgAttributes(element));

  static Map<String, String> _presentationFrom(Map<String, String> attributes) {
    return {
      for (final name in presentationAttributes)
        if (attributes[name] case final value? when value.trim().isNotEmpty)
          name: _unescapeAttribute(value),
    };
  }

  static String _presentationMarkup(Map<String, String> presentation) => [
    for (final MapEntry(:key, :value) in presentation.entries)
      if (presentationAttributes.contains(key))
        ' $key="${_escapeAttribute(value, '"')}"',
  ].join();

  static Map<String, String> _presentationFromJson(Object? value) {
    if (value is! Map) return const {};
    return _presentationFrom({
      for (final MapEntry(:key, :value) in value.entries)
        if (key is String && value is String) key: value,
    });
  }

  /// An `[IMG:ERROR:…]` card for [fields].
  ///
  /// The card ends at the first `]`, so one inside the JSON — an instruction
  /// or a style that happens to hold it — is written as its `\u005d` escape,
  /// which every JSON reader turns back into the bracket.
  static String errorTag(Map<String, Object?> fields) =>
      '[IMG:ERROR:${jsonEncode(fields).replaceAll(']', r'\u005d')}]';

  // ── Stored `<img data-iig-…>` form of a finished block ──────────────────

  /// Instruction JSON of an image block, on both the pending element a model
  /// writes and the finished one Glaze stores.
  static const String instructionAttribute = 'data-iig-instruction';

  /// The block's images, `;;`-separated. Absent while the block holds one.
  static const String variantsAttribute = 'data-iig-variants';

  /// Position inside [variantsAttribute] of the image the message shows.
  static const String variantIndexAttribute = 'data-iig-index';

  /// The stored spelling of a finished image block.
  ///
  /// Mirrors the tag the SillyTavern image extension writes, so message text
  /// stays readable HTML: the visible image is the element's `src`, the other
  /// images of the block ride along in [variantsAttribute] so that `src` is
  /// always one plain path, and every path is relative to the Glaze data root
  /// — which is what keeps a message working after that root moves (a new iOS
  /// container, a database copied between build channels).
  ///
  /// `[IMG:RESULT:…]` is still read, so older messages render unchanged, but
  /// it is never written any more.
  ///
  /// The author's [presentationAttributes] follow the `src`, so a card that
  /// positioned its picture keeps it where it put it.
  static String encodeResultElement(ImageBlockPayload payload) {
    final buffer = StringBuffer('<img $instructionAttribute=')
      ..write("'${_escapeAttribute(payload.instruction, "'")}'");
    if (payload.hasVariants) _writeVariants(buffer, payload);
    buffer
      ..write(' src="${_escapeAttribute(payload.activePath, '"')}"')
      ..write(_presentationMarkup(payload.presentation))
      ..write('>');
    return buffer.toString();
  }

  static void _writeVariants(StringBuffer buffer, ImageBlockPayload payload) {
    final joined = payload.paths.join(ImageBlockPayload.variantSeparator);
    buffer
      ..write(" $variantsAttribute='${_escapeAttribute(joined, "'")}'")
      ..write(
        " $variantIndexAttribute="
        "'${payload.activeIndex.clamp(0, payload.paths.length - 1)}'",
      );
  }

  /// Every finished block written in the stored `<img data-iig-…>` form, in
  /// document order. Elements still waiting for their image are left to
  /// [scanPendingTags]; the two never claim the same element.
  static List<ImageResultElement> scanResultElements(String text) {
    if (!text.contains(instructionAttribute)) return const [];

    final elements = <ImageResultElement>[];
    void collect(RegExp pattern) {
      for (final match in pattern.allMatches(text)) {
        final overlaps = elements.any(
          (element) => match.start < element.end && element.start < match.end,
        );
        if (overlaps) continue;
        final payload = _resultPayloadOfElement(match.group(0)!);
        if (payload == null) continue;
        elements.add(ImageResultElement(match.start, match.end, payload));
      }
    }

    collect(ImgGenPatterns.htmlIigTagRegex);
    collect(ImgGenPatterns.htmlIigTagDoubleRegex);
    elements.sort((a, b) => a.start.compareTo(b.start));
    return elements;
  }

  /// The payload an `<img …>` element carries, or null when it is not a
  /// finished image block (no instruction attribute, or no image yet).
  static ImageBlockPayload? _resultPayloadOfElement(String element) {
    if (ImgGenPatterns.isPendingIigElement(element)) return null;
    final attributes = ImgGenPatterns.imgAttributes(element);
    if (!attributes.containsKey(instructionAttribute)) return null;
    final src = _unescapeAttribute(attributes['src'] ?? '').trim();
    if (src.isEmpty) return null;
    final instruction = _unescapeAttribute(
      attributes[instructionAttribute] ?? '',
    );
    final presentation = _presentationFrom(attributes);
    final variants = _unescapeAttribute(attributes[variantsAttribute] ?? '');
    final paths = variants.isEmpty
        ? <String>[src]
        : ImageBlockPayload.decodePathList(variants);
    if (paths.isEmpty) {
      return ImageBlockPayload(
        paths: [src],
        instruction: instruction,
        presentation: presentation,
      );
    }
    // The declared index wins; without one the block shows whichever variant
    // the `src` names, so a hand-edited element still renders the right image.
    final declared = int.tryParse(attributes[variantIndexAttribute] ?? '');
    final active = declared ?? paths.indexOf(src);
    return ImageBlockPayload(
      paths: paths,
      activeIndex: active < 0 ? 0 : active.clamp(0, paths.length - 1),
      instruction: instruction,
      presentation: presentation,
    );
  }

  /// Sends every stored `<img data-iig-…>` block back to pending, keeping its
  /// prompt and the images it already holds.
  static String resetResultElements(String text) {
    var result = text;
    // Right to left: replacing one element must not move the spans of the
    // elements still to be replaced.
    for (final element in scanResultElements(text).reversed) {
      result = result.replaceRange(
        element.start,
        element.end,
        pendingTag(element.payload),
      );
    }
    return result;
  }

  static const Map<String, String> _attributeEntities = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    "'": '&#39;',
    '"': '&quot;',
  };

  /// [value] as an attribute of an element delimited by [quote].
  ///
  /// Only the delimiter and the characters that would end the element are
  /// encoded, so instruction JSON inside a single-quoted attribute keeps its
  /// plain `"` — the spelling a model writes, and the one every reader of the
  /// pending form already parses.
  static String _escapeAttribute(String value, String quote) {
    var escaped = value.replaceAll('&', _attributeEntities['&']!);
    for (final char in ['<', '>', quote]) {
      escaped = escaped.replaceAll(char, _attributeEntities[char]!);
    }
    return escaped;
  }

  static String _unescapeAttribute(String value) {
    if (!value.contains('&')) return value;
    return value
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&');
  }


  /// How many image tags of [text] are still waiting for their image.
  static int pendingImageGenTagCount(String text) =>
      scanPendingTags(text).length;

  static List<Map<String, dynamic>> extractImageGenInstructions(String text) =>
      scanPendingTags(text).map(_decodeInstruction).toList();

  static Map<String, dynamic> _decodeInstruction(PendingImageTag tag) {
    final instruction = ImageBlockPayload.parsePending(tag.payload).instruction;
    if (instruction.isEmpty) return <String, dynamic>{'prompt': ''};
    try {
      final decoded = jsonDecode(instruction);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return <String, dynamic>{'prompt': instruction};
  }

  static String replaceTagWithResult(String text, int index, String imagePath) {
    final tags = scanPendingTags(text);
    if (index < 0 || index >= tags.length) return text;
    final tag = tags[index];
    final instruction = _decodeInstruction(tag);
    final instrJson = instruction.isNotEmpty ? jsonEncode(instruction) : '';
    final payload = ImageBlockPayload.parsePending(tag.payload)
        .withInstruction(instrJson)
        .withPresentation(tag.presentation)
        .withNewImage(imagePath);
    return text.replaceRange(tag.start, tag.end, encodeResultElement(payload));
  }

  static String replaceTagWithError(String text, int index, String error) {
    final tags = scanPendingTags(text);
    if (index < 0 || index >= tags.length) return text;
    final tag = tags[index];
    final instructionJson = jsonEncode(_decodeInstruction(tag));
    // The path list rides along as a plain string: the error payload is JSON,
    // and a JSON array would close the tag on its own `]`.
    final carried = ImageBlockPayload.parsePending(tag.payload).encodePathList();
    return text.replaceRange(
      tag.start,
      tag.end,
      errorTag({
        'error': error,
        if (instructionJson.isNotEmpty) 'instruction': instructionJson,
        if (carried.isNotEmpty) 'variants': carried,
        if (tag.presentation.isNotEmpty) 'presentation': tag.presentation,
      }),
    );
  }

  /// Resolves every pending image tag to a retryable disabled-state error.
  /// Keeping the original instruction lets the UI enable image generation and
  /// immediately retry the same message without asking the model again.
  static String replaceAllImageGenTagsWithDisabled(String text) {
    var result = text;
    while (hasImageGenTags(result)) {
      final replaced = replaceTagWithError(
        result,
        0,
        'Image generation disabled',
      );
      if (replaced == result) break;
      result = replaced;
    }
    return result;
  }

  static String resetErrorTags(String text) =>
      resetResultTags(resetImageErrorTags(text));

  /// Sends every `[IMG:ERROR:…]` card back to pending, keeping its prompt and
  /// the images its earlier attempts produced.
  static String resetImageErrorTags(String text) {
    return text.replaceAllMapped(ImgGenPatterns.imgErrorRegex, (m) {
      try {
        final json = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        return pendingTag(
          ImageBlockPayload(
            paths: ImageBlockPayload.decodePathList(
              json['variants'] as String? ?? '',
            ),
            instruction: json['instruction'] as String? ?? '',
            presentation: _presentationFromJson(json['presentation']),
          ),
        );
      } catch (_) {}
      return '[IMG:GEN]';
    });
  }

  /// Sends every finished block back to pending, in both stored forms, keeping
  /// its prompt and the images it already holds.
  static String resetResultTags(String text) {
    final reset = text.replaceAllMapped(ImgGenPatterns.imgResultRegex, (m) {
      return pendingTag(ImageBlockPayload.parseResult(m.group(1) ?? ''));
    });
    return resetResultElements(reset);
  }

  /// The pending spelling of [payload].
  ///
  /// A block that carries the author's [presentationAttributes] stays an
  /// `<img>` element with `[IMG:GEN]` in its `src` and its images in
  /// [variantsAttribute]: the bracket tag has nowhere to keep them, and the
  /// picture the regeneration brings would lose the card's layout.
  static String pendingTag(ImageBlockPayload payload) {
    if (payload.presentation.isEmpty) {
      final encoded = payload.encodePending();
      return encoded.isEmpty ? '[IMG:GEN]' : '[IMG:GEN:$encoded]';
    }
    final buffer = StringBuffer('<img $instructionAttribute=')
      ..write("'${_escapeAttribute(payload.instruction, "'")}'");
    if (payload.paths.isNotEmpty) _writeVariants(buffer, payload);
    buffer
      ..write(' src="[IMG:GEN]"')
      ..write(_presentationMarkup(payload.presentation))
      ..write('>');
    return buffer.toString();
  }

  /// Every image block of [text] in document order, whatever state it is in.
  ///
  /// This is the numbering the chat webview renders against, so a block index
  /// coming back from a tap addresses exactly one image of the message.
  static List<ImageBlock> scanImageBlocks(String text) {
    final blocks = <ImageBlock>[
      for (final tag in scanPendingTags(text))
        _pendingBlock(tag),
    ];

    // A resolved token can never sit inside a block already collected; the
    // guard just keeps one quoted inside a tag payload or an element attribute
    // from being counted twice.
    bool insidePendingTag(RegExpMatch match) => blocks.any(
      (block) => match.start < block.end && block.start < match.end,
    );

    for (final element in scanResultElements(text)) {
      final payload = element.payload;
      blocks.add(
        ImageBlock(
          start: element.start,
          end: element.end,
          kind: ImageBlockKind.result,
          instruction: payload.instruction,
          imagePath: payload.activePath,
          paths: payload.paths,
          activeIndex: payload.activeIndex,
          presentation: payload.presentation,
        ),
      );
    }

    for (final match in ImgGenPatterns.imgResultRegex.allMatches(text)) {
      if (insidePendingTag(match)) continue;
      final payload = ImageBlockPayload.parseResult(match.group(1) ?? '');
      blocks.add(
        ImageBlock(
          start: match.start,
          end: match.end,
          kind: ImageBlockKind.result,
          instruction: payload.instruction,
          imagePath: payload.activePath,
          paths: payload.paths,
          activeIndex: payload.activeIndex,
        ),
      );
    }

    for (final match in ImgGenPatterns.imgErrorRegex.allMatches(text)) {
      if (insidePendingTag(match)) continue;
      var instruction = '';
      var carried = const <String>[];
      var presentation = const <String, String>{};
      try {
        final parsed = jsonDecode(match.group(1) ?? '');
        if (parsed is Map) {
          instruction = parsed['instruction'] as String? ?? '';
          carried = ImageBlockPayload.decodePathList(
            parsed['variants'] as String? ?? '',
          );
          presentation = _presentationFromJson(parsed['presentation']);
        }
      } catch (_) {}
      blocks.add(
        ImageBlock(
          start: match.start,
          end: match.end,
          kind: ImageBlockKind.error,
          instruction: instruction,
          paths: carried,
          presentation: presentation,
        ),
      );
    }

    blocks.sort((a, b) => a.start.compareTo(b.start));
    return blocks;
  }

  /// [text] with every image block reduced to the pending tag that asked for
  /// it: the picture, the block's other images and the position of the visible
  /// one are dropped, the instruction is kept.
  ///
  /// This is the only spelling of an image block a model may read or write.
  /// Glaze is the sole writer of a finished block — it writes one the moment it
  /// has saved the file — so an `<img data-iig-…>` element in model output
  /// names files that do not exist: it renders as a broken picture, and the
  /// variant list it carries counts images that were never generated. Left in
  /// the history it also teaches the next reply to write another one, a little
  /// longer each turn (INV-IG12).
  ///
  /// Applied to a reply as it is stored (`SavedMessageWriter`) and to chat
  /// content on its way into any prompt (`HistoryAssembler` and the extension
  /// context builders), so the internal form neither leaves nor enters Glaze.
  static String reduceBlocksToInstructions(String text) {
    // Every prompt build walks the whole history through here, and most
    // messages carry no image at all.
    if (!text.contains('[IMG:') && !text.contains(instructionAttribute)) {
      return text;
    }
    final blocks = scanImageBlocks(text);
    if (blocks.isEmpty) return text;
    var result = text;
    // Right to left: replacing one block must not move the spans of the ones
    // still to be replaced.
    for (final block in blocks.reversed) {
      // A block that is already waiting for its picture and carries none is
      // left exactly as written. There is nothing in it to strip, and both of
      // its spellings survive a prompt round trip — where rewriting the
      // element form into `[IMG:GEN:…]` would end the tag at the first `]` of
      // an instruction that happens to contain one.
      if (block.kind == ImageBlockKind.pending && block.paths.isEmpty) {
        continue;
      }
      result = result.replaceRange(
        block.start,
        block.end,
        pendingTag(ImageBlockPayload(instruction: block.instruction)),
      );
    }
    return result;
  }

  /// [text] with every image a pending block carries and [keep] rejects
  /// dropped, the instruction and the surviving images left in place.
  ///
  /// A block keeps its earlier images through a regeneration so the reader can
  /// page back through them, which only holds for images that are still on
  /// disk. One that is not — a file the user deleted, or a path that never
  /// named a file at all — can do nothing but render as a broken picture and
  /// pad the block's switcher, so a regeneration is where it is dropped.
  static String dropCarriedImages(String text, bool Function(String) keep) {
    final tags = scanPendingTags(text);
    if (tags.isEmpty) return text;
    var result = text;
    // Right to left: rewriting one tag must not move the spans of the rest.
    for (final tag in tags.reversed) {
      final payload = ImageBlockPayload.parsePending(tag.payload);
      if (payload.paths.isEmpty) continue;
      final kept = <String>[];
      var active = 0;
      for (var i = 0; i < payload.paths.length; i++) {
        if (!keep(payload.paths[i])) continue;
        if (i == payload.activeIndex) active = kept.length;
        kept.add(payload.paths[i]);
      }
      if (kept.length == payload.paths.length) continue;
      result = result.replaceRange(
        tag.start,
        tag.end,
        pendingTag(
          payload
              .withPresentation(tag.presentation)
              .withPaths(kept, activeIndex: active),
        ),
      );
    }
    return result;
  }

  static ImageBlock _pendingBlock(PendingImageTag tag) {
    final payload = ImageBlockPayload.parsePending(tag.payload);
    return ImageBlock(
      start: tag.start,
      end: tag.end,
      kind: ImageBlockKind.pending,
      instruction: payload.instruction,
      paths: payload.paths,
      activeIndex: payload.activeIndex,
      presentation: tag.presentation,
    );
  }

  /// Sends the [index]-th image block back to pending, keeping its prompt.
  ///
  /// Returns [text] unchanged when the index addresses nothing or the block is
  /// already waiting for its image — the caller reads that as "nothing to do".
  static String resetImageBlockAt(String text, int index) {
    final blocks = scanImageBlocks(text);
    if (index < 0 || index >= blocks.length) return text;
    final block = blocks[index];
    if (block.kind == ImageBlockKind.pending) return text;
    return text.replaceRange(block.start, block.end, block.asPendingTag);
  }

  /// Points the [index]-th image block at [imagePath], keeping its prompt.
  static String replaceImageBlockWithResult(
    String text,
    int index,
    String imagePath,
  ) {
    final blocks = scanImageBlocks(text);
    if (index < 0 || index >= blocks.length) return text;
    final block = blocks[index];
    final payload = block.payload.withNewImage(imagePath);
    return text.replaceRange(
      block.start,
      block.end,
      encodeResultElement(payload),
    );
  }

  /// Puts the [variantIndex]-th image of the [blockIndex]-th block on screen.
  ///
  /// Returns [text] unchanged when either index addresses nothing or the block
  /// already shows that image, which the caller reads as "nothing to do".
  static String setImageBlockVariant(
    String text,
    int blockIndex,
    int variantIndex,
  ) {
    final blocks = scanImageBlocks(text);
    if (blockIndex < 0 || blockIndex >= blocks.length) return text;
    final block = blocks[blockIndex];
    if (block.kind != ImageBlockKind.result) return text;
    if (variantIndex < 0 || variantIndex >= block.paths.length) return text;
    if (variantIndex == block.activeIndex) return text;
    return text.replaceRange(
      block.start,
      block.end,
      encodeResultElement(block.payload.withActiveIndex(variantIndex)),
    );
  }

  /// The visible image of every finished block, in document order — both the
  /// stored `<img data-iig-…>` form and the `[IMG:RESULT:…]` of older messages.
  static List<String> extractImageResultPaths(String text) {
    return [
      for (final block in scanImageBlocks(text))
        if (block.kind == ImageBlockKind.result && block.imagePath.isNotEmpty)
          block.imagePath,
    ];
  }

  /// Rewrites the file path inside every finished image block with [resolve],
  /// in both stored forms, dropping the whole block when it returns null.
  ///
  /// The payload is split exactly like the WebView formatter does — the tag
  /// ends at the first `]`, the path ends at the first `|` — so an instruction
  /// JSON carrying a `]` cannot leave the two sides disagreeing about which
  /// substring is the path. A stricter pattern skipped such a tag, and the raw
  /// filesystem path then reached the page as `file://…`, which the chat
  /// WebView (an https / loopback origin) cannot load at all: the message
  /// rendered a broken image.
  static String rewriteResultPaths(
    String text,
    String? Function(String path) resolve,
  ) {
    var result = text.replaceAllMapped(ImgGenPatterns.imgResultRegex, (match) {
      final rewritten = _rewritePayload(
        ImageBlockPayload.parseResult(match.group(1) ?? ''),
        resolve,
      );
      return rewritten == null ? '' : '[IMG:RESULT:${rewritten.encodeResult()}]';
    });
    // Scanned after the tag pass, so the spans are the ones of `result`, and
    // walked right to left so replacing one element leaves the rest in place.
    for (final element in scanResultElements(result).reversed) {
      final rewritten = _rewritePayload(element.payload, resolve);
      result = result.replaceRange(
        element.start,
        element.end,
        rewritten == null ? '' : encodeResultElement(rewritten),
      );
    }
    return result;
  }

  /// [payload] with [resolve] applied to every image it carries, or null when
  /// none of them can be served.
  ///
  /// Every variant is resolved, not just the visible one: the switcher swaps
  /// the image in the page, and a variant it cannot address would read as a
  /// picture that vanished. A variant that cannot be served is dropped from
  /// the block instead.
  static ImageBlockPayload? _rewritePayload(
    ImageBlockPayload payload,
    String? Function(String path) resolve,
  ) {
    final resolved = <String>[];
    var active = 0;
    for (var i = 0; i < payload.paths.length; i++) {
      final url = resolve(payload.paths[i]);
      if (url == null) continue;
      if (i == payload.activeIndex) active = resolved.length;
      resolved.add(url);
    }
    if (resolved.isEmpty) return null;
    return payload.withPaths(resolved, activeIndex: active);
  }

  /// The image an `[IMG:RESULT:…]` payload shows — instruction suffix and the
  /// block's other variants stripped.
  static String normalizeImageResultPayload(String payload) =>
      ImageBlockPayload.parseResult(payload).activePath;

  /// [contentsNewestFirst] — text blobs ordered newest → oldest (e.g. ext-block bodies).
  static List<String> collectRecentImageResultPaths(
    Iterable<String> contentsNewestFirst, {
    int maxPaths = 3,
  }) {
    final collected = <String>[];
    for (final content in contentsNewestFirst) {
      if (collected.length >= maxPaths) break;
      for (final path in extractImageResultPaths(content)) {
        if (collected.length >= maxPaths) break;
        collected.add(path);
      }
    }
    return collected.reversed.toList();
  }

  /// Reads image instructions from pending [IMG:GEN] tags or finished
  /// [IMG:RESULT:path|json] tokens inside ext-block HTML.
  static List<Map<String, dynamic>> extractInstructionsFromImageContent(
    String text,
  ) {
    final fromGen = extractImageGenInstructions(text);
    if (fromGen.isNotEmpty) return fromGen;

    final fromResult = <Map<String, dynamic>>[];
    for (final element in scanResultElements(text)) {
      final instruction = element.payload.instruction;
      if (instruction.isEmpty) continue;
      try {
        fromResult.add(jsonDecode(instruction) as Map<String, dynamic>);
      } catch (_) {}
    }
    for (final match in ImgGenPatterns.imgResultRegex.allMatches(text)) {
      final raw = match.group(1) ?? '';
      final pipeIdx = raw.indexOf('|');
      if (pipeIdx < 0 || pipeIdx >= raw.length - 1) continue;
      try {
        fromResult.add(
          jsonDecode(raw.substring(pipeIdx + 1)) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    return fromResult;
  }
}
