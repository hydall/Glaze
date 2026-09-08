import 'package:flutter/material.dart';

import '../../../core/utils/html_to_markdown.dart';

/// Renders a chat-list preview of the last message with inline markdown
/// applied (bold, italic, strikethrough and the custom `==...==` color
/// markers) instead of showing the raw markers as literal characters.
///
/// Optimized for list scrolling: parsing is a pure string → segment pass with
/// a bounded, theme-independent cache keyed on the raw message, and a plain
/// [Text] fast path when the preview has no formatting. No `GptMarkdown`
/// widget is built per row.
class MessagePreviewText extends StatelessWidget {
  final String raw;
  final TextStyle style;
  final int maxLines;

  const MessagePreviewText({
    super.key,
    required this.raw,
    required this.style,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final segments = _segmentsFor(raw);

    if (segments.isEmpty) {
      return Text(
        '',
        style: style,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
    }

    // Fast path: nothing to style, render a plain Text.
    if (segments.length == 1 && segments.first.isPlain) {
      return Text(
        segments.first.text,
        style: style,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
    }

    return Text.rich(
      TextSpan(
        children: [
          for (final s in segments)
            TextSpan(
              text: s.text,
              style: TextStyle(
                fontWeight: s.bold ? FontWeight.w600 : null,
                fontStyle: s.italic ? FontStyle.italic : null,
                decoration: s.strike ? TextDecoration.lineThrough : null,
                color: s.color != null ? Color(s.color!) : null,
              ),
            ),
        ],
      ),
      style: style,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A styled run of preview text. Theme-independent: [color] is only set when a
/// marker carries an explicit color, so the base [TextStyle] (which owns the
/// default color) can be applied at build time and cached segments reused.
class _PreviewSegment {
  final String text;
  final bool bold;
  final bool italic;
  final bool strike;
  final int? color;

  const _PreviewSegment(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.color,
  });

  bool get isPlain => !bold && !italic && !strike && color == null;
}

// Bounded LRU-ish cache so repeated rebuilds / scrolling don't re-parse.
const int _cacheCap = 512;
final Map<String, List<_PreviewSegment>> _cache = {};

List<_PreviewSegment> _segmentsFor(String raw) {
  final cached = _cache[raw];
  if (cached != null) return cached;

  final segments = _buildSegments(raw);
  if (_cache.length >= _cacheCap) {
    _cache.remove(_cache.keys.first);
  }
  _cache[raw] = segments;
  return segments;
}

List<_PreviewSegment> _buildSegments(String raw) {
  // Strip HTML first (reuses the shared converter), then flatten whitespace so
  // the preview is a single tidy line before markdown parsing.
  var text = stripHtml(raw);
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return const [];

  final out = <_PreviewSegment>[];
  _parseInline(text, out);
  return out;
}

/// Combined inline-token matcher. Alternatives are ordered so `**`/`__` win
/// over `*`/`_`. Underscore emphasis is guarded by word boundaries so
/// identifiers like `snake_case` are not mangled.
final RegExp _tokenRe = RegExp(
  r'==([a-z]+(?::[^=]*)?)==([\s\S]*?)==' // 1: marker spec, 2: marker inner
  r'|\*\*([\s\S]+?)\*\*' // 3: bold  **
  r'|(?<![\w])__([\s\S]+?)__(?![\w])' // 4: bold  __
  r'|\*([\s\S]+?)\*' // 5: italic *
  r'|(?<![\w])_([\s\S]+?)_(?![\w])' // 6: italic _
  r'|~~([\s\S]+?)~~' // 7: strikethrough
  r'|`([^`]+)`', // 8: inline code
);

void _parseInline(
  String text,
  List<_PreviewSegment> out, {
  bool bold = false,
  bool italic = false,
  bool strike = false,
  int? color,
}) {
  var pos = 0;
  for (final m in _tokenRe.allMatches(text)) {
    if (m.start > pos) {
      _emit(text.substring(pos, m.start), out,
          bold: bold, italic: italic, strike: strike, color: color);
    }

    if (m.group(1) != null) {
      _parseInline(m.group(2)!, out,
          bold: bold,
          italic: italic,
          strike: strike,
          color: _markerColor(m.group(1)!) ?? color);
    } else if (m.group(3) != null) {
      _parseInline(m.group(3)!, out,
          bold: true, italic: italic, strike: strike, color: color);
    } else if (m.group(4) != null) {
      _parseInline(m.group(4)!, out,
          bold: true, italic: italic, strike: strike, color: color);
    } else if (m.group(5) != null) {
      _parseInline(m.group(5)!, out,
          bold: bold, italic: true, strike: strike, color: color);
    } else if (m.group(6) != null) {
      _parseInline(m.group(6)!, out,
          bold: bold, italic: true, strike: strike, color: color);
    } else if (m.group(7) != null) {
      _parseInline(m.group(7)!, out,
          bold: bold, italic: italic, strike: true, color: color);
    } else if (m.group(8) != null) {
      _emit(m.group(8)!, out,
          bold: bold, italic: italic, strike: strike, color: color);
    }

    pos = m.end;
  }
  if (pos < text.length) {
    _emit(text.substring(pos), out,
        bold: bold, italic: italic, strike: strike, color: color);
  }
}

void _emit(
  String text,
  List<_PreviewSegment> out, {
  required bool bold,
  required bool italic,
  required bool strike,
  required int? color,
}) {
  if (text.isEmpty) return;
  out.add(_PreviewSegment(text,
      bold: bold, italic: italic, strike: strike, color: color));
}

/// Extracts a text color from a `==...==` marker spec. Only the markers that
/// set foreground color contribute (`hc`, `cg`, `grad`); `glow`, `bg`, `mark`
/// and `active` inherit the base color.
int? _markerColor(String spec) {
  final colon = spec.indexOf(':');
  if (colon == -1) return null; // mark / active
  final tag = spec.substring(0, colon);
  if (tag != 'hc' && tag != 'cg' && tag != 'grad') return null;
  final hex =
      RegExp(r'#([0-9a-fA-F]{3,8})').firstMatch(spec.substring(colon + 1));
  if (hex == null) return null;
  return _hexToArgb(hex.group(1)!);
}

int? _hexToArgb(String hex) {
  var h = hex;
  if (h.length == 3) {
    h = '${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}';
  } else if (h.length == 4) {
    h = '${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}${h[3]}${h[3]}';
  }
  if (h.length == 6) {
    return int.tryParse('ff$h', radix: 16);
  }
  if (h.length == 8) {
    // CSS #RRGGBBAA → Flutter 0xAARRGGBB
    final rgb = h.substring(0, 6);
    final a = h.substring(6, 8);
    return int.tryParse('$a$rgb', radix: 16);
  }
  return null;
}
