/// Hybrid line + word diff algorithm for the POST-cleaner diff viewer.
///
/// First aligns lines between original and cleaned using LCS. For lines
/// classified as `same`, they are shown as-is. For lines classified as
/// `removed` or `added`, we additionally run a word-level diff so that
/// within a changed line, individual words are highlighted rather than
/// the entire line.
library;

enum DiffLineType { same, added, removed }

/// A word within a diff line. `isChanged` marks words that differ from
/// the corresponding word on the other side.
class DiffWord {
  final String text;
  final bool isChanged;

  const DiffWord(this.text, {this.isChanged = false});
}

class DiffLine {
  final String text;
  final DiffLineType type;
  /// Word-level breakdown for inline highlighting. Null for unchanged lines.
  final List<DiffWord>? words;

  const DiffLine(this.text, this.type, {this.words});
}

class DiffResult {
  final List<DiffLine> leftLines;
  final List<DiffLine> rightLines;
  final int removedLines;
  final int addedLines;

  const DiffResult({
    required this.leftLines,
    required this.rightLines,
    required this.removedLines,
    required this.addedLines,
  });

  const DiffResult.empty()
      : leftLines = const [],
        rightLines = const [],
        removedLines = 0,
        addedLines = 0;
}

/// Computes a hybrid line+word diff between [original] and [cleaned].
///
/// 1. Split both texts into lines.
/// 2. Align lines using LCS.
/// 3. For `same` lines → shown as-is.
/// 4. For `removed` + `added` line pairs that are adjacent → run
///    word-level diff to highlight individual changed words.
DiffResult computeLineDiff(String original, String cleaned) {
  final left = original.isEmpty ? <String>[] : original.split('\n');
  final right = cleaned.isEmpty ? <String>[] : cleaned.split('\n');
  final n = left.length;
  final m = right.length;

  // LCS DP table for line alignment.
  final dp = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      if (left[i] == right[j]) {
        dp[i][j] = dp[i + 1][j + 1] + 1;
      } else {
        dp[i][j] = dp[i + 1][j] > dp[i][j + 1]
            ? dp[i + 1][j]
            : dp[i][j + 1];
      }
    }
  }

  // Backtrack to build the raw diff (list of ops).
  final ops = <_DiffOp>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (left[i] == right[j]) {
      ops.add(_DiffOp.same(left[i], right[j]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      ops.add(_DiffOp.removed(left[i]));
      i++;
    } else {
      ops.add(_DiffOp.added(right[j]));
      j++;
    }
  }
  while (i < n) {
    ops.add(_DiffOp.removed(left[i]));
    i++;
  }
  while (j < m) {
    ops.add(_DiffOp.added(right[j]));
    j++;
  }

  // Post-process: pair adjacent removed+added ops and run word-level diff
  // on them. Unpaired removed → left-only red; unpaired added → right-only green.
  final leftLines = <DiffLine>[];
  final rightLines = <DiffLine>[];
  var removed = 0;
  var added = 0;

  var k = 0;
  while (k < ops.length) {
    final op = ops[k];
    if (op.isSame) {
      leftLines.add(DiffLine(op.leftText!, DiffLineType.same));
      rightLines.add(DiffLine(op.rightText!, DiffLineType.same));
      k++;
      continue;
    }

    // Collect a run of consecutive removed ops.
    var removedStart = k;
    while (k < ops.length && ops[k].isRemoved) {
      k++;
    }
    var removedEnd = k;

    // Collect a run of consecutive added ops immediately after.
    var addedStart = k;
    while (k < ops.length && ops[k].isAdded) {
      k++;
    }
    var addedEnd = k;

    final removedRun = ops.sublist(removedStart, removedEnd);
    final addedRun = ops.sublist(addedStart, addedEnd);

    if (removedRun.isNotEmpty && addedRun.isNotEmpty) {
      // Pair them up and run word-level diff on each pair.
      final pairs = _pairRuns(removedRun, addedRun);
      for (final pair in pairs) {
        if (pair.left != null && pair.right != null) {
          final wordDiff = _computeWordDiff(pair.left!, pair.right!);
          leftLines.add(DiffLine(
            pair.left!, DiffLineType.removed, words: wordDiff.left,
          ));
          rightLines.add(DiffLine(
            pair.right!, DiffLineType.added, words: wordDiff.right,
          ));
          removed++;
          added++;
        } else if (pair.left != null) {
          leftLines.add(DiffLine(pair.left!, DiffLineType.removed));
          rightLines.add(const DiffLine('', DiffLineType.removed));
          removed++;
        } else if (pair.right != null) {
          leftLines.add(const DiffLine('', DiffLineType.added));
          rightLines.add(DiffLine(pair.right!, DiffLineType.added));
          added++;
        }
      }
    } else if (removedRun.isNotEmpty) {
      for (final r in removedRun) {
        leftLines.add(DiffLine(r.leftText!, DiffLineType.removed));
        rightLines.add(const DiffLine('', DiffLineType.removed));
        removed++;
      }
    } else if (addedRun.isNotEmpty) {
      for (final a in addedRun) {
        leftLines.add(const DiffLine('', DiffLineType.added));
        rightLines.add(DiffLine(a.rightText!, DiffLineType.added));
        added++;
      }
    }
  }

  return DiffResult(
    leftLines: leftLines,
    rightLines: rightLines,
    removedLines: removed,
    addedLines: added,
  );
}

class _DiffOp {
  final String? leftText;
  final String? rightText;

  const _DiffOp._(this.leftText, this.rightText);

  factory _DiffOp.same(String left, String right) => _DiffOp._(left, right);
  factory _DiffOp.removed(String left) => _DiffOp._(left, null);
  factory _DiffOp.added(String right) => _DiffOp._(null, right);

  bool get isSame => leftText != null && rightText != null;
  bool get isRemoved => leftText != null && rightText == null;
  bool get isAdded => leftText == null && rightText != null;
}

class _Pair {
  final String? left;
  final String? right;
  const _Pair._(this.left, this.right);
  factory _Pair.both(String l, String r) => _Pair._(l, r);
  factory _Pair.leftOnly(String l) => _Pair._(l, null);
  factory _Pair.rightOnly(String r) => _Pair._(null, r);
}

List<_Pair> _pairRuns(List<_DiffOp> removed, List<_DiffOp> added) {
  final pairs = <_Pair>[];
  final minLen = removed.length < added.length ? removed.length : added.length;
  for (var i = 0; i < minLen; i++) {
    pairs.add(_Pair.both(removed[i].leftText!, added[i].rightText!));
  }
  for (var i = minLen; i < removed.length; i++) {
    pairs.add(_Pair.leftOnly(removed[i].leftText!));
  }
  for (var i = minLen; i < added.length; i++) {
    pairs.add(_Pair.rightOnly(added[i].rightText!));
  }
  return pairs;
}

class _WordDiffResult {
  final List<DiffWord> left;
  final List<DiffWord> right;
  const _WordDiffResult._(this.left, this.right);
}

/// Computes a word-level diff between two strings using LCS on words.
/// Returns two lists of [DiffWord] where `isChanged=true` marks words
/// that differ from the corresponding word on the other side.
_WordDiffResult _computeWordDiff(String leftStr, String rightStr) {
  final leftWords = _tokenize(leftStr);
  final rightWords = _tokenize(rightStr);
  final n = leftWords.length;
  final m = rightWords.length;

  final dp = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      if (leftWords[i] == rightWords[j]) {
        dp[i][j] = dp[i + 1][j + 1] + 1;
      } else {
        dp[i][j] = dp[i + 1][j] > dp[i][j + 1]
            ? dp[i + 1][j]
            : dp[i][j + 1];
      }
    }
  }

  final leftResult = <DiffWord>[];
  final rightResult = <DiffWord>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (leftWords[i] == rightWords[j]) {
      leftResult.add(DiffWord(leftWords[i]));
      rightResult.add(DiffWord(rightWords[j]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      // Remove from left (advance i).
      leftResult.add(DiffWord(leftWords[i], isChanged: true));
      rightResult.add(const DiffWord('', isChanged: true));
      i++;
    } else {
      // Add from right (advance j).
      leftResult.add(const DiffWord('', isChanged: true));
      rightResult.add(DiffWord(rightWords[j], isChanged: true));
      j++;
    }
  }
  while (i < n) {
    leftResult.add(DiffWord(leftWords[i], isChanged: true));
    rightResult.add(const DiffWord('', isChanged: true));
    i++;
  }
  while (j < m) {
    leftResult.add(const DiffWord('', isChanged: true));
    rightResult.add(DiffWord(rightWords[j], isChanged: true));
    j++;
  }

  return _WordDiffResult._(leftResult, rightResult);
}

/// Tokenize a string into words by splitting on whitespace. Empty tokens
/// are filtered out. Spaces between words are not separate tokens — the
/// word diff operates on words only, and the UI joins them with spaces.
List<String> _tokenize(String s) {
  if (s.isEmpty) return const [];
  return s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
}
