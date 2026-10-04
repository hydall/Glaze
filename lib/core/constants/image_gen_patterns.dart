class ImgGenPatterns {
  ImgGenPatterns._();

  static final imgGenRegex = RegExp(r'\[IMG:GEN(?::(.*?))?\]');
  static final imgResultRegex = RegExp(r'\[IMG:RESULT:(.*?)\]');
  static final imgErrorRegex = RegExp(r'\[IMG:ERROR:(.*?)\]');

  static final imgResultStripRegex = RegExp(r'\[IMG:RESULT:[^\]]*\]');
  static final imgErrorStripRegex = RegExp(r'\[IMG:ERROR:[^\]]*\]');
  static final imgGenStripRegex = RegExp(r'\[IMG:GEN[^\]]*\]');

  static final htmlIigTagRegex = RegExp(
    r"<img\s[^>]*?data-iig-instruction\s*=\s*'([^']*)'[^>]*>",
    caseSensitive: false,
    dotAll: true,
  );
  static final htmlIigTagDoubleRegex = RegExp(
    r'''<img\s[^>]*?data-iig-instruction\s*=\s*"([^"]*)"[^>]*>''',
    caseSensitive: false,
    dotAll: true,
  );
  static final htmlIigAnyAttrRegex = RegExp(
    r'<img\s[^>]*?data-iig-instruction\s*=[^>]*>',
    caseSensitive: false,
    dotAll: true,
  );
  static final imgSrcGenRegex = RegExp(
    r'''<img\b[^>]*?\bsrc\s*=\s*["']\[IMG:GEN[^\]]*\]["'][^>]*>''',
    caseSensitive: false,
    dotAll: true,
  );
  static final imgGenHtmlRegex = RegExp(
    r"""<img\s[^>]*?data-iig-instruction\s*=\s*'([^']*)'[^>]*?src="\[IMG:GEN\]"[^>]*>""",
    caseSensitive: false,
    dotAll: true,
  );

  /// Reads the attributes off one matched `<img …>` element, lower-cased names
  /// to their raw (still entity-encoded) values.
  ///
  /// Walking the pairs left to right consumes each quoted value whole, so a
  /// `src=` written inside an instruction prompt is never mistaken for the
  /// element's own `src` — which is the attribute that tells a finished image
  /// block apart from one still waiting for its picture.
  static Map<String, String> imgAttributes(String tag) {
    final body = tag.replaceFirst(
      RegExp(r'^<\s*[A-Za-z][-A-Za-z0-9]*', caseSensitive: false),
      '',
    );
    final attributes = <String, String>{};
    for (final match in _attributePairRegex.allMatches(body)) {
      final name = match.group(1)!.toLowerCase();
      attributes.putIfAbsent(
        name,
        () => match.group(2) ?? match.group(3) ?? match.group(4) ?? '',
      );
    }
    return attributes;
  }

  static final _attributePairRegex = RegExp(
    '([A-Za-z_:][-A-Za-z0-9_:.]*)'
    r'\s*=\s*'
    '(?:"([^"]*)"'
    "|'([^']*)'"
    r'''|([^\s"'>]*))''',
  );

  /// A folded-away reasoning block: `<think>…</think>` and
  /// `<thinking>…</thinking>`, the shapes the WebView formatter matches (see
  /// `formatter.js` step 1a). Only a *closed* block counts, exactly as it does
  /// there — an unclosed tag is not yet a reasoning block on either side.
  static final reasoningBlockRegex = RegExp(
    r'<(think|thinking)\b[\s\S]*?<\/\1\b[^>]*(?:>|$)',
    caseSensitive: false,
  );

  /// Cheap probe: most messages carry no reasoning at all, and the scan below
  /// only has to run for the ones that do.
  static final _reasoningProbe = RegExp('<think', caseSensitive: false);

  /// Character spans of [text] covered by a reasoning block, in document order.
  ///
  /// A model plans its images out loud — "then I'll put [IMG:GEN:…] here" — and
  /// a tag written inside its own reasoning is a note to itself, not a request.
  /// Generating from it produces a picture nobody asked for, so every scan that
  /// can start a generation walks past these spans (INV-IG11).
  static List<(int, int)> reasoningSpans(String text) {
    if (!_reasoningProbe.hasMatch(text)) return const [];
    return [
      for (final match in reasoningBlockRegex.allMatches(text))
        (match.start, match.end),
    ];
  }

  /// Whether `[start, end)` falls in any of [spans].
  static bool overlapsSpan(List<(int, int)> spans, int start, int end) =>
      spans.any((span) => start < span.$2 && span.$1 < end);

  /// Whether an `<img …data-iig-instruction…>` element is still waiting for its
  /// image: it has no `src`, or only the `[IMG:GEN…]` placeholder in it. The
  /// same element with a stored image path in its `src` is the finished form.
  static bool isPendingIigElement(String tag) {
    final src = (imgAttributes(tag)['src'] ?? '').trim();
    return src.isEmpty || src.startsWith('[IMG:GEN');
  }

  static final base64DataUrlRegex = RegExp(
    r'data:image/[^;]+;base64,[A-Za-z0-9+/=]{256,}',
  );
  static final imgTagDataSrcRegex = RegExp(
    r'<img\s[^>]*?src="data:image/[^"]{256,}?"[^>]*\/?>',
  );

  static const imgGenPattern = r'\[IMG:RESULT:(.*?)\]';

  static bool hasAnyImageTag(String text) {
    return imgGenRegex.hasMatch(text) ||
        imgResultRegex.hasMatch(text) ||
        imgErrorRegex.hasMatch(text) ||
        htmlIigTagRegex.hasMatch(text) ||
        htmlIigTagDoubleRegex.hasMatch(text);
  }

  static String stripHtmlImgTags(String text) {
    return text.replaceAll(htmlIigAnyAttrRegex, '');
  }
}
