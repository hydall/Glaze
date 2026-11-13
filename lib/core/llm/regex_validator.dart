// Heuristic detection of catastrophic-backtracking (ReDoS) regex patterns.
//
// Dart's `RegExp` is synchronous with no timeout API. A pattern with nested
// quantifiers (e.g. `(.+)*`, `(a+)+`, `(?:X*)*`) can hang the isolate
// indefinitely on modest input. This checker scans the raw pattern string
// and classifies it so callers can skip risky scripts before they run.
//
// This is a **heuristic** — it trades precision for breadth. It will not
// catch every pathological pattern, but it catches the common signatures
// that SillyTavern preset imports have been observed to carry.

/// Result of a regex safety check.
enum RegexSafety {
  /// No known-bad structure detected.
  safe,

  /// Likely slow (quadratic) on long input with no match, but not necessarily
  /// exponential. Allowed to run; the isolate-timeout is the safety net.
  risky,

  /// Contains nested quantifiers that cause exponential backtracking.
  /// Should be skipped at runtime.
  pathological,
}

/// Stripped pattern + parsed flags.
class ParsedRegex {
  final String pattern;
  final bool multiLine;
  final bool dotAll;
  final bool caseSensitive;
  const ParsedRegex({
    required this.pattern,
    required this.multiLine,
    required this.dotAll,
    required this.caseSensitive,
  });
}

/// Parses a `/pattern/flags` or bare `pattern` string into components.
ParsedRegex parseRegexPattern(String raw) {
  if (raw.startsWith('/') && raw.length > 1) {
    final lastSlash = raw.lastIndexOf('/');
    if (lastSlash > 0) {
      return ParsedRegex(
        pattern: raw.substring(1, lastSlash),
        multiLine: raw.substring(lastSlash + 1).contains('m'),
        dotAll: raw.substring(lastSlash + 1).contains('s'),
        caseSensitive: !raw.substring(lastSlash + 1).contains('i'),
      );
    }
  }
  return ParsedRegex(
    pattern: raw,
    multiLine: false,
    dotAll: false,
    caseSensitive: true,
  );
}

/// Classifies a raw regex pattern string for ReDoS risk.
RegexSafety classifyRegexSafety(String rawPattern) {
  final parsed = parseRegexPattern(rawPattern);
  final p = parsed.pattern;
  if (p.isEmpty) return RegexSafety.safe;

  if (_hasNestedQuantifiers(p)) return RegexSafety.pathological;
  if (_hasLazyDotAllWithAnchor(p, parsed.dotAll)) return RegexSafety.risky;

  return RegexSafety.safe;
}

/// Detects a quantifier (`+`, `*`, or `{n,}`) applied to a group that itself
/// contains a quantifier — the classic exponential-backtracking structure.
///
/// Examples caught: `(.+)*`, `(a+)+`, `(?:\\w*)*`, `(\"[^\"]*\")+`.
/// `?` as the outer quantifier is excluded (0-or-1 does not compound).
bool _hasNestedQuantifiers(String p) {
  final groupStarts = <int>[];
  var inClass = false;

  for (var i = 0; i < p.length; i++) {
    final ch = p[i];

    if (ch == '\\' && i + 1 < p.length) {
      i++;
      continue;
    }

    if (inClass) {
      if (ch == ']') inClass = false;
      continue;
    }

    if (ch == '[') {
      inClass = true;
      continue;
    }

    if (ch == '(') {
      groupStarts.add(i);
    } else if (ch == ')' && groupStarts.isNotEmpty) {
      final open = groupStarts.removeLast();
      final inner = p.substring(open + 1, i);
      if (_containsQuantifier(inner) && _isOuterQuantifier(p, i + 1)) {
        return true;
      }
    }
  }
  return false;
}

/// Whether the character at [pos] starts a compounding quantifier (`+`, `*`,
/// or an unbounded `{n,}`). `?` is excluded.
bool _isOuterQuantifier(String p, int pos) {
  if (pos >= p.length) return false;
  final ch = p[pos];
  if (ch == '+' || ch == '*') return true;
  if (ch == '{') {
    final close = p.indexOf('}', pos);
    if (close > pos) {
      final body = p.substring(pos + 1, close);
      // {n,} with no upper bound, or {n,m} where m is very large.
      final comma = body.indexOf(',');
      if (comma >= 0) {
        final after = body.substring(comma + 1).trim();
        if (after.isEmpty) return true;
        final m = int.tryParse(after);
        if (m != null && m > 100) return true;
      }
    }
  }
  return false;
}

/// Whether [s] — a group's body, right after its `(` — contains any
/// quantifier (`+`, `*`, `?`, or unbounded `{n,}`). Character classes `[...]`
/// and escapes are skipped, and so is group syntax: the `?` of `(?:` or
/// `(?<name>` is not a quantifier, and a lookaround is atomic, so whatever it
/// repeats inside cannot compound with the quantifier outside.
bool _containsQuantifier(String s) {
  var inClass = false;
  for (var i = _groupPrefixEnd(s, 0); i < s.length; i++) {
    final ch = s[i];
    if (ch == '\\' && i + 1 < s.length) {
      i++;
      continue;
    }
    if (inClass) {
      if (ch == ']') inClass = false;
      continue;
    }
    if (ch == '[') {
      inClass = true;
      continue;
    }
    if (ch == '(') {
      if (_isLookaround(s, i)) {
        i = _groupEnd(s, i);
      } else {
        i = _groupPrefixEnd(s, i + 1) - 1;
      }
      continue;
    }
    if (ch == '+' || ch == '*' || ch == '?') return true;
    if (ch == '{') {
      final close = s.indexOf('}', i);
      if (close > i) {
        final body = s.substring(i + 1, close);
        final comma = body.indexOf(',');
        if (comma >= 0 && body.substring(comma + 1).trim().isEmpty) {
          return true; // {n,}
        }
      }
    }
  }
  return false;
}

/// Detects `[\s\S]*?` (or `.*?` with dotAll) combined with a `$` anchor —
/// quadratic on input that has no match: at each start position the lazy
/// quantifier extends to the end before failing.
bool _hasLazyDotAllWithAnchor(String p, bool dotAll) {
  final hasLazyBroadMatch =
      p.contains(r'[\s\S]*?') ||
      p.contains(r'[\s\S]+?') ||
      (dotAll && (p.contains('.*?') || p.contains('.+?')));
  if (!hasLazyBroadMatch) return false;

  for (var i = 0; i < p.length; i++) {
    if (p[i] == '\\' && i + 1 < p.length) {
      i++;
      continue;
    }
    if (p[i] == '\$') return true;
  }
  return false;
}

bool _isLookaround(String s, int open) =>
    s.startsWith('(?=', open) ||
    s.startsWith('(?!', open) ||
    s.startsWith('(?<=', open) ||
    s.startsWith('(?<!', open);

/// Index just past a group's `?:` / `?=` / `?!` / `?<=` / `?<!` / `?<name>`
/// prefix, for a group body starting at [start]; [start] itself when the
/// group is a plain capturing one.
int _groupPrefixEnd(String s, int start) {
  if (start >= s.length || s[start] != '?') return start;
  if (s.startsWith('?<=', start) || s.startsWith('?<!', start)) {
    return start + 3;
  }
  if (s.startsWith('?<', start)) {
    final close = s.indexOf('>', start);
    return close < 0 ? start + 2 : close + 1;
  }
  return start + 2;
}

/// Index of the `)` closing the group opened at [open], or the last index
/// when the group is unbalanced.
int _groupEnd(String s, int open) {
  var depth = 0;
  var inClass = false;
  for (var i = open; i < s.length; i++) {
    final ch = s[i];
    if (ch == '\\') {
      i++;
      continue;
    }
    if (inClass) {
      if (ch == ']') inClass = false;
      continue;
    }
    if (ch == '[') {
      inClass = true;
    } else if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return s.length - 1;
}
