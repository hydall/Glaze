/// Turns the `custom_css` of a Tavo theme package into the three stylesheets
/// Glaze understands (docs/THEME_LAYOUTS.md § Stylesheets).
///
/// A Tavo theme addresses its own DOM with the public `.tavo-*` selectors
/// (docs.tavoai.dev/en/guides/theme-development). The chat page carries those
/// names as aliases (renderer/message_renderer.js, chrome/composer.js), so
/// most rules pass through untouched. Two kinds need moving:
///
///  * rules that reach the text inside a message — `.tavo-message-content p`,
///    `.tavo-message-content q::after` — because Glaze renders the text in a
///    shadow root, and only `layout.contentCss` gets in there;
///  * composer rules, because the composer lives in the chrome's closed
///    shadow root and only `chrome.css` gets in there.
///
/// A rule is never copied across those boundaries: each selector goes to the
/// one stylesheet where it can match.
library;

class TavoCssParts {
  const TavoCssParts({this.page = '', this.content = '', this.chrome = ''});

  /// Goes onto the chat page (`layout.css`).
  final String page;

  /// Goes into every message's shadow root (`layout.contentCss`).
  final String content;

  /// Goes into the chrome (`layout.chrome.css`).
  final String chrome;
}

/// Splits [css] into the page, message-content and chrome stylesheets.
///
/// [assetUrl] maps a `theme/assets/...` reference to a `data:` URI. It returns
/// null when the archive has no such file, leaving the reference in place for
/// the page's CSS sanitizer to drop.
TavoCssParts splitTavoCss(
  String css, {
  String? Function(String path)? assetUrl,
}) {
  if (css.trim().isEmpty) return const TavoCssParts();
  final source = assetUrl == null ? css : _rewriteAssetUrls(css, assetUrl);
  final out = _CssOutput();
  _split(source, out);
  return TavoCssParts(
    page: out.page.toString().trim(),
    content: out.content.toString().trim(),
    chrome: out.chrome.toString().trim(),
  );
}

class _CssOutput {
  final page = StringBuffer();
  final content = StringBuffer();
  final chrome = StringBuffer();

  bool get isEmpty => page.isEmpty && content.isEmpty && chrome.isEmpty;

  void add(_Kind kind, String text) {
    if (text.trim().isEmpty) return;
    _buffer(kind).writeln(text);
  }

  StringBuffer _buffer(_Kind kind) => switch (kind) {
    _Kind.page => page,
    _Kind.content => content,
    _Kind.chrome => chrome,
  };

  void addAll(_CssOutput other) {
    add(_Kind.page, other.page.toString());
    add(_Kind.content, other.content.toString());
    add(_Kind.chrome, other.chrome.toString());
  }
}

enum _Kind { page, content, chrome }

void _split(String source, _CssOutput out) {
  var i = 0;
  final n = source.length;
  while (i < n) {
    // Whitespace and comments between rules.
    if (source[i] == '/' && i + 1 < n && source[i + 1] == '*') {
      final end = source.indexOf('*/', i + 2);
      i = end < 0 ? n : end + 2;
      out.add(_Kind.page, '');
      continue;
    }
    if (_isSpace(source[i])) {
      i++;
      continue;
    }

    final start = i;
    var paren = 0;
    var quote = '';
    var brace = -1;
    var semicolon = -1;
    while (i < n) {
      final char = source[i];
      if (quote.isNotEmpty) {
        if (char == '\\') {
          i += 2;
          continue;
        }
        if (char == quote) quote = '';
        i++;
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
      } else if (char == '/' && i + 1 < n && source[i + 1] == '*') {
        final end = source.indexOf('*/', i + 2);
        i = end < 0 ? n : end + 1;
      } else if (char == '(') {
        paren++;
      } else if (char == ')') {
        paren = paren > 0 ? paren - 1 : 0;
      } else if (char == '{' && paren == 0) {
        brace = i;
        break;
      } else if (char == ';' && paren == 0) {
        semicolon = i;
        break;
      }
      i++;
    }

    if (semicolon >= 0) {
      final statement = source.substring(start, semicolon + 1).trim();
      if (statement.isNotEmpty) out.add(_Kind.page, statement);
      i = semicolon + 1;
      continue;
    }
    if (brace < 0) {
      final tail = source.substring(start).trim();
      if (tail.isNotEmpty) out.add(_Kind.page, tail);
      break;
    }

    var end = brace + 1;
    var depth = 1;
    quote = '';
    while (end < n && depth > 0) {
      final char = source[end];
      if (quote.isNotEmpty) {
        if (char == '\\') {
          end += 2;
          continue;
        }
        if (char == quote) quote = '';
      } else if (char == '"' || char == "'") {
        quote = char;
      } else if (char == '/' && end + 1 < n && source[end + 1] == '*') {
        final close = source.indexOf('*/', end + 2);
        end = close < 0 ? n : close + 1;
      } else if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
      }
      end++;
    }
    final ruleEnd = end;
    final head = source.substring(start, brace).trim();
    final body = source.substring(brace + 1, ruleEnd - 1).trim();
    i = ruleEnd;

    if (head.isEmpty) continue;
    if (head.startsWith('@')) {
      final name = RegExp(r'^@([\w-]+)').firstMatch(head)?.group(1) ?? '';
      final grouping = const {
        'media',
        'supports',
        'container',
        'layer',
        'scope',
      }.contains(name);
      if (grouping) {
        final inner = _CssOutput();
        _split(body, inner);
        _addWrapped(head, inner, out);
      } else {
        // Keyframes, font-face, page and the like are global on the page.
        // The page sanitizer decides whether they may stay.
        out.add(_Kind.page, '$head { $body }');
      }
      continue;
    }

    _splitSelectors(head, body, out);
  }
}

void _addWrapped(String head, _CssOutput inner, _CssOutput out) {
  void wrap(_Kind kind, String text) {
    if (text.trim().isEmpty) return;
    out.add(kind, '$head {\n$text\n}');
  }

  wrap(_Kind.page, inner.page.toString());
  wrap(_Kind.content, inner.content.toString());
  wrap(_Kind.chrome, inner.chrome.toString());
}

void _splitSelectors(String head, String body, _CssOutput out) {
  final byKind = <_Kind, List<String>>{
    _Kind.page: [],
    _Kind.content: [],
    _Kind.chrome: [],
  };
  for (final selector in _splitSelectorList(head)) {
    final (kind, rewritten) = _classify(selector);
    if (rewritten.trim().isEmpty) continue;
    byKind[kind]!.add(rewritten);
  }
  for (final entry in byKind.entries) {
    if (entry.value.isEmpty) continue;
    out.add(entry.key, '${entry.value.join(',\n')} { $body }');
  }
}

(_Kind, String) _classify(String selector) {
  // Tavo keeps the older `.tav-` spellings working; Glaze carries one set of
  // aliases, under `.tavo-`.
  final trimmed = selector.trim().replaceAllMapped(
    RegExp(r'\.tav-'),
    (_) => '.tavo-',
  );
  if (trimmed.isEmpty) return (_Kind.page, '');
  if (trimmed.contains('.tavo-composer')) {
    return (_Kind.chrome, trimmed);
  }
  final content = _rewriteMessageContent(trimmed);
  if (content != null) return (_Kind.content, content);
  return (_Kind.page, _rewritePageSelector(trimmed));
}

/// The part of a selector that follows `.tavo-message-content`: null when the
/// rule styles the box itself, a rewritten selector when it reaches the text
/// inside (the shadow root).
String? _rewriteMessageContent(String selector) {
  final match = RegExp(r'\.tavo-message-content(?![\w-])').firstMatch(selector);
  if (match == null) return null;
  final after = selector.substring(match.end);
  final rest = after.trimLeft();
  if (rest.isEmpty) return null;

  final startsWithPseudo =
      rest.startsWith('::before') ||
      rest.startsWith('::after') ||
      rest.startsWith(':before') ||
      rest.startsWith(':after');
  if (startsWithPseudo) return null;

  final child = after.startsWith('>');
  final sibling = after.startsWith('+') || after.startsWith('~');
  if (!child && !sibling && !_isSpace(after[0])) return null;

  final String tail;
  if (child || sibling) {
    final inner = rest.substring(1).trim();
    if (inner.isEmpty) return null;
    tail = ' > $inner';
  } else {
    tail = ' $rest';
  }

  final role = _roleOf(selector);
  final host = role == null ? ':host' : ':host(.$role)';
  return _rewriteQuoteTags('$host .glaze-message$tail');
}

/// Tavo marks speech with `<q>` and `a[href="#speech"]`; Glaze's formatter
/// emits `.chat-quote` (the marks) and `.chat-quote-text` (what is between
/// them). Map the element selectors onto those, so a theme's speech glass
/// lands on the text it was written for.
String _rewriteQuoteTags(String selector) {
  var out = selector.replaceAll(
    RegExp(r'''a\[href(?:=["']#speech["']|\$=["']#speech["'])\]'''),
    '.chat-quote-text',
  );
  out = out.replaceAllMapped(
    RegExp(r'(^|[^\w.#-])q(?=::?(?:before|after))'),
    (match) => '${match.group(1)}.chat-quote',
  );
  return out.replaceAllMapped(
    RegExp(r'(^|[^\w.#-])q(?![\w-])'),
    (match) => '${match.group(1)}.chat-quote-text',
  );
}

String? _roleOf(String selector) {
  if (selector.contains('.tavo-character')) return 'char';
  if (selector.contains('.tavo-user')) return 'user';
  return null;
}

String _rewritePageSelector(String selector) {
  // Glaze draws the reasoning header as a div, not a <summary>.
  if (selector.contains('.tavo-message-reasoning')) {
    return selector.replaceAllMapped(
      RegExp(r'(^|[^\w-])summary(?![\w-])'),
      (match) => '${match.group(1)}.msg-reasoning-header',
    );
  }
  return selector;
}

List<String> _splitSelectorList(String selector) {
  final parts = <String>[];
  var depth = 0;
  var quote = '';
  var start = 0;
  for (var i = 0; i < selector.length; i++) {
    final char = selector[i];
    if (quote.isNotEmpty) {
      if (char == '\\') {
        i++;
        continue;
      }
      if (char == quote) quote = '';
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '(' || char == '[') {
      depth++;
    } else if (char == ')' || char == ']') {
      depth--;
    } else if (char == ',' && depth == 0) {
      parts.add(selector.substring(start, i).trim());
      start = i + 1;
    }
  }
  final tail = selector.substring(start).trim();
  if (tail.isNotEmpty) parts.add(tail);
  return parts.where((part) => part.isNotEmpty).toList(growable: false);
}

String _rewriteAssetUrls(String css, String? Function(String path) assetUrl) {
  return css.replaceAllMapped(
    RegExp(r'''url\(\s*(['"]?)([^'")]+)\1\s*\)''', caseSensitive: false),
    (match) {
      final raw = match.group(2) ?? '';
      String path;
      try {
        path = Uri.decodeFull(raw.trim());
      } catch (_) {
        path = raw.trim();
      }
      final data = assetUrl(path);
      return data == null ? match.group(0)! : 'url("$data")';
    },
  );
}

bool _isSpace(String char) =>
    char == ' ' || char == '\n' || char == '\r' || char == '\t';
