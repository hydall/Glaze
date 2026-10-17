/// Search/replace rewrites, ported from the original extension's
/// `searchReplaceDiffUtils.js`: the model answers with aider-style hunks, or
/// with [searchReplaceNoChanges] when nothing needs to change.
library;

const _searchMarker = '<<<<<<< SEARCH';
const _separatorMarker = '=======';
const _replaceMarker = '>>>>>>> REPLACE';

/// The reply that means "the text already satisfies the instructions".
const searchReplaceNoChanges = 'NO_CHANGES';

/// A reply that cannot be parsed, or a hunk that cannot be applied safely.
class SearchReplaceDiffError implements Exception {
  const SearchReplaceDiffError(this.message, this.code, [this.hunkIndex]);

  final String message;
  final String code;
  final int? hunkIndex;

  @override
  String toString() => message;
}

/// One change: [search] must match the target exactly once.
class SearchReplaceHunk {
  const SearchReplaceHunk({required this.search, required this.replace});

  final String search;
  final String replace;

  SearchReplaceHunk copyWith({String? replace}) =>
      SearchReplaceHunk(search: search, replace: replace ?? this.replace);
}

bool _isFenceLine(String line) {
  final trimmed = line.trim();
  return trimmed.startsWith('```') || trimmed.startsWith('~~~');
}

bool _isMarker(String line, String marker) => line.trim() == marker;

List<String> _lines(String text) =>
    text.replaceAll(RegExp(r'\r\n?'), '\n').split('\n');

const _noChangePhrases = {
  'no changes',
  'no change needed',
  'no changes needed',
  'no changes are needed',
  'no change required',
  'no changes required',
  'nothing to change',
  'no rewrite needed',
  'no rewrite required',
};

/// Whether [output] is the model deciding that nothing needs to change. One
/// outer Markdown fence is tolerated, and so are the common whole-reply
/// phrasings of it.
bool isSearchReplaceNoChanges(String output) {
  final content = _lines(
    output,
  ).where((line) => line.trim().isNotEmpty && !_isFenceLine(line)).toList();
  if (content.length != 1) return false;
  final response = content.single.trim();
  if (response == searchReplaceNoChanges) return true;
  final normalized = response
      .toLowerCase()
      .replaceAll(RegExp(r'[.!?]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return _noChangePhrases.contains(normalized);
}

/// Parses an aider-style search/replace diff.
List<SearchReplaceHunk> parseSearchReplaceDiff(String output) {
  if (output.trim().isEmpty) {
    throw const SearchReplaceDiffError(
      'The model returned an empty diff.',
      'EMPTY_DIFF',
    );
  }
  final lines = _lines(output);
  final hunks = <SearchReplaceHunk>[];
  var index = 0;

  void skipOutside() {
    while (index < lines.length &&
        (lines[index].trim().isEmpty || _isFenceLine(lines[index]))) {
      index++;
    }
  }

  skipOutside();
  while (index < lines.length) {
    final number = hunks.length + 1;
    if (!_isMarker(lines[index], _searchMarker)) {
      throw SearchReplaceDiffError(
        'Unexpected content outside a SEARCH/REPLACE hunk at line '
            '${index + 1}.',
        'UNEXPECTED_CONTENT',
        hunks.length,
      );
    }
    index++;

    final search = <String>[];
    while (index < lines.length && !_isMarker(lines[index], _separatorMarker)) {
      if (_isMarker(lines[index], _searchMarker) ||
          _isMarker(lines[index], _replaceMarker)) {
        throw SearchReplaceDiffError(
          'Malformed SEARCH section in hunk $number.',
          'MALFORMED_HUNK',
          hunks.length,
        );
      }
      search.add(lines[index]);
      index++;
    }
    if (index >= lines.length) {
      throw SearchReplaceDiffError(
        'Missing ======= marker in hunk $number.',
        'MALFORMED_HUNK',
        hunks.length,
      );
    }
    index++;

    final replace = <String>[];
    while (index < lines.length && !_isMarker(lines[index], _replaceMarker)) {
      if (_isMarker(lines[index], _searchMarker)) {
        throw SearchReplaceDiffError(
          'Malformed REPLACE section in hunk $number.',
          'MALFORMED_HUNK',
          hunks.length,
        );
      }
      replace.add(lines[index]);
      index++;
    }
    if (index >= lines.length) {
      throw SearchReplaceDiffError(
        'Missing >>>>>>> REPLACE marker in hunk $number.',
        'MALFORMED_HUNK',
        hunks.length,
      );
    }
    index++;

    final searchText = search.join('\n');
    if (searchText.isEmpty) {
      throw SearchReplaceDiffError(
        'SEARCH section in hunk $number is empty.',
        'EMPTY_SEARCH',
        hunks.length,
      );
    }
    hunks.add(
      SearchReplaceHunk(search: searchText, replace: replace.join('\n')),
    );
    skipOutside();
  }

  if (hunks.isEmpty) {
    throw const SearchReplaceDiffError(
      'No SEARCH/REPLACE hunks were found.',
      'NO_HUNKS',
    );
  }
  return hunks;
}

String _adaptLineEndings(String text, String source) =>
    source.contains('\r\n') ? text.replaceAll('\n', '\r\n') : text;

/// Applies [hunks] to [source] in order. Each SEARCH must match exactly once
/// in the text as it stands when its hunk is applied.
({String text, int appliedCount}) applySearchReplaceDiff(
  String source,
  List<SearchReplaceHunk> hunks,
) {
  if (hunks.isEmpty) {
    throw const SearchReplaceDiffError(
      'No SEARCH/REPLACE hunks were provided.',
      'NO_HUNKS',
    );
  }
  var result = source;
  for (var i = 0; i < hunks.length; i++) {
    final hunk = hunks[i];
    if (hunk.search.isEmpty) {
      throw SearchReplaceDiffError(
        'Invalid hunk ${i + 1}.',
        'MALFORMED_HUNK',
        i,
      );
    }
    final search = _adaptLineEndings(hunk.search, result);
    final replacement = _adaptLineEndings(hunk.replace, result);
    final first = result.indexOf(search);
    if (first == -1) {
      throw SearchReplaceDiffError(
        'SEARCH section from hunk ${i + 1} was not found in the rewrite '
            'target.',
        'SEARCH_NOT_FOUND',
        i,
      );
    }
    if (result.indexOf(search, first + 1) != -1) {
      throw SearchReplaceDiffError(
        'SEARCH section from hunk ${i + 1} is ambiguous (2 or more matches).',
        'AMBIGUOUS_SEARCH',
        i,
      );
    }
    result =
        result.substring(0, first) +
        replacement +
        result.substring(first + search.length);
  }
  return (text: result, appliedCount: hunks.length);
}

const _searchReplaceDiffTemplate =
    '<<<<<<< SEARCH\n'
    'exact text copied verbatim from the rewrite target\n'
    '=======\n'
    'replacement text\n'
    '>>>>>>> REPLACE';

/// Stands in for the block's own template in search/replace mode.
const searchReplaceDiffOutputTemplate =
    'Output exactly $searchReplaceNoChanges, or one or more SEARCH/REPLACE '
    'hunks as specified by the system instructions.';

/// The system message that teaches the model the diff format.
const searchReplaceDiffProtocol =
    'Choose exactly one of these two output forms:\n'
    '\n'
    '1. If the rewrite instructions are already satisfied, not applicable, or '
    'require no actual edits, output exactly this single token and stop:\n'
    '$searchReplaceNoChanges\n'
    '\n'
    '2. Otherwise, output only one or more SEARCH/REPLACE hunks in this exact '
    'format:\n'
    '$_searchReplaceDiffTemplate\n'
    '\n'
    'Rules:\n'
    '- SEARCH must be non-empty and match the rewrite target exactly, '
    'including whitespace and punctuation.\n'
    '- Include enough unchanged context in SEARCH to make every match '
    'unique.\n'
    '- Use multiple hunks for separate changes.\n'
    '- To delete text, leave the REPLACE section empty.\n'
    '- $searchReplaceNoChanges is a valid successful response. Do not replace '
    'it with prose such as "No changes needed."\n'
    '- Never create a no-op hunk or a hunk containing the complete rewrite '
    'target when no actual edits are needed.\n'
    '- Do not return explanations, XML wrappers, or the complete rewritten '
    'text.';
