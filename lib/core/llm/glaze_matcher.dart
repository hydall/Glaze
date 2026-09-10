import 'regex_validator.dart';

const glazeBoundaries =
    r'[\s.,!?;:"\u201C\u201D\u2018\u2019\u00AB\u00BB(){}\[\]\u2014\u2013*]';

enum WholeWordMode { no, yes, glaze }

/// A key written in SillyTavern's `/pattern/flags` regex form.
class RegexKey {
  final String pattern;
  final bool ignoreCase;
  final bool multiLine;
  final bool dotAll;

  const RegexKey({
    required this.pattern,
    required this.ignoreCase,
    required this.multiLine,
    required this.dotAll,
  });
}

/// JS regex flags allowed after the closing delimiter. `g`, `y` and `d` carry
/// no meaning for a stateless `hasMatch`, so they are parsed and ignored.
const _jsRegexFlags = 'gimsuyd';

final _regexKeyShape = RegExp(r'^/(.+)/([a-z]*)$', dotAll: true);

/// Parses a key written as `/pattern/flags`, or returns null when the key is a
/// plain one. A trailing segment that is not a valid flag list keeps the key
/// literal, so `/home/user` is still matched as text.
RegexKey? parseRegexKey(String key) {
  final match = _regexKeyShape.firstMatch(key);
  if (match == null) return null;

  final flags = match.group(2)!;
  for (var i = 0; i < flags.length; i++) {
    if (!_jsRegexFlags.contains(flags[i])) return null;
  }

  return RegexKey(
    pattern: match.group(1)!,
    ignoreCase: flags.contains('i'),
    multiLine: flags.contains('m'),
    dotAll: flags.contains('s'),
  );
}

/// Splits a comma-separated key list without cutting `/pattern/flags` keys that
/// contain a comma (e.g. `/Кент(?:а|у){1,2}/g`).
List<String> splitLorebookKeys(String text) {
  final keys = <String>[];
  final buffer = StringBuffer();
  var inRegex = false;
  var inCharClass = false;
  var escaped = false;
  var segmentEmpty = true;

  void flush() {
    final key = buffer.toString().trim();
    if (key.isNotEmpty) keys.add(key);
    buffer.clear();
    segmentEmpty = true;
    inRegex = false;
    inCharClass = false;
    escaped = false;
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];

    if (inRegex) {
      buffer.write(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '[') {
        inCharClass = true;
      } else if (ch == ']') {
        inCharClass = false;
      } else if (ch == '/' && !inCharClass) {
        // Closing delimiter — the trailing flags are plain text again.
        inRegex = false;
      }
      continue;
    }

    if (ch == ',') {
      flush();
      continue;
    }

    if (ch == '/' && segmentEmpty) inRegex = true;
    buffer.write(ch);
    if (ch.trim().isNotEmpty) segmentEmpty = false;
  }

  flush();
  return keys;
}

WholeWordMode resolveWholeWords(
  bool? entryValue,
  bool globalValue,
  String keySearchMode,
) {
  if (entryValue == true) return WholeWordMode.yes;
  if (entryValue == false) return WholeWordMode.no;
  if (keySearchMode == 'glaze') return WholeWordMode.glaze;
  if (globalValue) return WholeWordMode.yes;
  return WholeWordMode.no;
}

bool glazeCheckMatch(
  String key,
  String text,
  bool caseSensitive,
  WholeWordMode wholeWords,
) {
  if (key.isEmpty) return false;

  // A `/pattern/flags` key is an explicit regex, the form ST exports: the
  // delimiters and flags are not part of the pattern, and whole-word wrapping
  // never applies to it. Without this, the whole literal (slashes included)
  // was compiled as the pattern and could only match text containing `/`.
  final regexKey = parseRegexKey(key);
  if (regexKey != null) {
    final regex = _safeRegex(
      regexKey.pattern,
      caseSensitive && !regexKey.ignoreCase,
      multiLine: regexKey.multiLine,
      dotAll: regexKey.dotAll,
    );
    if (regex != null) return regex.hasMatch(text);
    // Pathological or uncompilable — fall through to literal matching.
  }

  if (wholeWords == WholeWordMode.glaze) {
    final escaped = RegExp.escape(key);
    final beforeBoundary = '(?:^|$glazeBoundaries)';
    final afterBoundary = r'(?:$|' + glazeBoundaries + r')';
    final pattern = beforeBoundary + escaped + afterBoundary;
    final regex = _tryCreateRegex(pattern, caseSensitive);
    if (regex != null) return regex.hasMatch(text);
    final needle = caseSensitive ? key : key.toLowerCase();
    final haystack = caseSensitive ? text : text.toLowerCase();
    if (needle.isEmpty) return false;
    final fallback = _tryCreateRegex(
      beforeBoundary + RegExp.escape(needle) + afterBoundary,
      caseSensitive,
    );
    return fallback?.hasMatch(haystack) ?? false;
  }

  var pattern = key;
  if (wholeWords == WholeWordMode.yes) {
    pattern = _unicodeWholeWordPattern(pattern);
  }

  // Tavern-compatible keys may be regular expressions. Dart's RegExp engine
  // is synchronous and has no per-match timeout, so a single imported ReDoS
  // pattern can otherwise block the prompt worker until its hard 60s kill.
  // Keep regex compatibility for ordinary keys, but fall back to literal
  // matching for patterns with known catastrophic-backtracking structure.
  final regex = _safeRegex(
    pattern,
    caseSensitive,
    unicode: wholeWords == WholeWordMode.yes,
  );
  if (regex != null) return regex.hasMatch(text);

  final haystack = caseSensitive ? text : text.toLowerCase();
  final needle = caseSensitive ? key : key.toLowerCase();
  if (needle.isEmpty) return false;

  if (wholeWords == WholeWordMode.yes) {
    final wordRegex = _tryCreateRegex(
      _unicodeWholeWordPattern(RegExp.escape(needle)),
      caseSensitive,
      unicode: true,
    );
    return wordRegex?.hasMatch(haystack) ?? false;
  }

  return haystack.contains(needle);
}

String _unicodeWholeWordPattern(String pattern) {
  const wordCharacter = r'\p{L}\p{M}\p{N}_';
  return '(?:^|[^$wordCharacter])(?:$pattern)(?=\$|[^$wordCharacter])';
}

RegExp? _safeRegex(
  String pattern,
  bool caseSensitive, {
  bool multiLine = false,
  bool dotAll = false,
  bool unicode = false,
}) {
  if (classifyRegexSafety(pattern) == RegexSafety.pathological) return null;
  return _tryCreateRegex(
    pattern,
    caseSensitive,
    multiLine: multiLine,
    dotAll: dotAll,
    unicode: unicode,
  );
}

RegExp? _tryCreateRegex(
  String pattern,
  bool caseSensitive, {
  bool multiLine = false,
  bool dotAll = false,
  bool unicode = false,
}) {
  try {
    return RegExp(
      pattern,
      caseSensitive: caseSensitive,
      multiLine: multiLine,
      dotAll: dotAll,
      unicode: unicode,
    );
  } catch (_) {
    return null;
  }
}
