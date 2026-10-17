/// The original extension's helpers for finding `<name>…</name>` blocks in
/// text (`blockUtils.js`), ported one-for-one so a preset's tags are read the
/// same way here.
///
/// A block name may carry attributes, `stat type="x"`: the opening tag is
/// then matched in full and the closing tag by the bare name before them.
library;

/// The opening and closing names for [blockName].
({String upper, String bottom}) blockTagNames(String blockName) {
  if (!blockName.contains('=')) return (upper: blockName, bottom: blockName);
  final head = blockName.substring(0, blockName.indexOf('=')).trim();
  final words = head.split(RegExp(r'\s+'));
  final bottom = words.sublist(0, words.length - 1).join(' ');
  return (upper: blockName, bottom: bottom);
}

bool _isTagBoundary(String text, int index) {
  if (index >= text.length) return false;
  final c = text[index];
  return c == '>' || c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/// The first `<blockName>…</blockName>` in [message], tags included, or `''`.
String blockFromMessage(String message, String blockName) {
  if (message.isEmpty) return '';
  final names = blockTagNames(blockName);
  final start = '<${names.upper}';
  final closing = '</${names.bottom}>';
  var startIndex = message.indexOf(start);
  while (startIndex != -1) {
    if (_isTagBoundary(message, startIndex + start.length)) {
      final tagEnd = message.indexOf('>', startIndex);
      if (tagEnd != -1) {
        final end = message.indexOf(closing, tagEnd);
        if (end != -1) {
          return message.substring(startIndex, end + closing.length);
        }
      }
    }
    startIndex = message.indexOf(start, startIndex + 1);
  }
  return '';
}

/// The inner text of every `<blockName>…</blockName>` in [message], each
/// trimmed, joined by a newline and trimmed again. `''` when there is none.
String multiBlockContentFromMessage(String message, String blockName) {
  if (message.isEmpty) return '';
  final names = blockTagNames(blockName);
  final start = '<${names.upper}';
  final closing = '</${names.bottom}>';
  final contents = <String>[];
  var searchIndex = 0;
  while (true) {
    final startIndex = message.indexOf(start, searchIndex);
    if (startIndex == -1) break;
    if (!_isTagBoundary(message, startIndex + start.length)) {
      searchIndex = startIndex + 1;
      continue;
    }
    final tagEnd = message.indexOf('>', startIndex);
    if (tagEnd == -1) {
      searchIndex = startIndex + 1;
      continue;
    }
    final end = message.indexOf(closing, tagEnd);
    if (end == -1) {
      searchIndex = startIndex + 1;
      continue;
    }
    contents.add(message.substring(tagEnd + 1, end).trim());
    searchIndex = end + closing.length;
  }
  return contents.join('\n').trim();
}

/// The regex source matching a whole `<blockName>…</blockName>`, with any
/// newlines before it — the original's `getRegexForBlock`.
String blockRegexSource(String blockName) {
  final names = blockTagNames(blockName);
  return '(\\n*<${RegExp.escape(names.upper)}(\\s+[^>]+)?>[\\s\\S]*?'
      '<\\/${RegExp.escape(names.bottom)}>)';
}
