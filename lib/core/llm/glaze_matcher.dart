const glazeBoundaries =
    r'[\s.,!?;:"\u201C\u201D\u2018\u2019\u00AB\u00BB(){}\[\]\u2014\u2013*]';

enum WholeWordMode { no, yes, glaze }

WholeWordMode resolveWholeWords(
    bool? entryValue, bool globalValue, String keySearchMode) {
  if (entryValue == true) return WholeWordMode.yes;
  if (entryValue == false) return WholeWordMode.no;
  if (keySearchMode == 'glaze') return WholeWordMode.glaze;
  if (globalValue) return WholeWordMode.yes;
  return WholeWordMode.no;
}

bool glazeCheckMatch(
    String key, String text, bool caseSensitive, WholeWordMode wholeWords) {
  if (key.isEmpty) return false;

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
    pattern = '\\b$pattern\\b';
  }

  final regex = _tryCreateRegex(pattern, caseSensitive);
  if (regex != null) return regex.hasMatch(text);

  final haystack = caseSensitive ? text : text.toLowerCase();
  final needle = caseSensitive ? key : key.toLowerCase();
  if (needle.isEmpty) return false;

  if (wholeWords == WholeWordMode.yes) {
    final wordRegex =
        _tryCreateRegex('\\b${RegExp.escape(needle)}\\b', caseSensitive);
    return wordRegex?.hasMatch(haystack) ?? false;
  }

  return haystack.contains(needle);
}

RegExp? _tryCreateRegex(String pattern, bool caseSensitive) {
  try {
    return RegExp(pattern, caseSensitive: caseSensitive);
  } catch (_) {
    return null;
  }
}
