/// The HuggingFace `tokenizer.json` pre-tokenizers used by the models Glaze
/// resolves to: they cut text into the pieces BPE runs on independently.
abstract class PreTokenizer {
  const PreTokenizer();

  List<String> split(List<String> pieces);

  /// Returns null for a spec that does not split (null, or a pure ByteLevel
  /// without its regex).
  static PreTokenizer? fromSpec(Object? spec) {
    if (spec is! Map) return null;
    switch (spec['type']) {
      case 'Sequence':
        final parts = [
          for (final child in (spec['pretokenizers'] as List? ?? const []))
            ?fromSpec(child),
        ];
        if (parts.isEmpty) return null;
        return parts.length == 1 ? parts.single : _Sequence(parts);
      case 'Split':
        final pattern = spec['pattern'];
        final RegExp regex;
        if (pattern is Map && pattern['Regex'] is String) {
          regex = compileHfRegex(pattern['Regex'] as String);
        } else if (pattern is Map && pattern['String'] is String) {
          regex = RegExp(RegExp.escape(pattern['String'] as String));
        } else {
          return null;
        }
        return RegexSplit(
          regex,
          behavior: _behavior(spec['behavior']),
          invert: spec['invert'] as bool? ?? false,
        );
      case 'ByteLevel':
        final useRegex = spec['use_regex'] as bool? ?? true;
        final prefix = spec['add_prefix_space'] as bool? ?? false;
        if (!useRegex && !prefix) return null;
        return _ByteLevelSplit(useRegex: useRegex, addPrefixSpace: prefix);
      case 'Digits':
        return RegexSplit(
          RegExp(
            (spec['individual_digits'] as bool? ?? false) ? '[0-9]' : '[0-9]+',
          ),
          behavior: SplitBehavior.isolated,
        );
      case 'Metaspace':
        return _Metaspace(
          replacement: spec['replacement'] as String? ?? '▁',
          prepend: _metaspacePrepend(spec),
          splitOnReplacement: spec['split'] as bool? ?? true,
        );
      case 'Whitespace':
        return RegexSplit(
          RegExp(r'\w+|[^\w\s]+', unicode: true),
          behavior: SplitBehavior.removed,
          invert: true,
        );
      case 'WhitespaceSplit':
        return RegexSplit(
          RegExp(r'\s+', unicode: true),
          behavior: SplitBehavior.removed,
        );
      case 'Punctuation':
        return RegexSplit(
          RegExp(r'[\p{P}]', unicode: true),
          behavior: _behavior(spec['behavior']),
        );
      default:
        return null;
    }
  }

  static SplitBehavior _behavior(Object? name) => switch (name) {
    'Removed' => SplitBehavior.removed,
    'MergedWithPrevious' => SplitBehavior.mergedWithPrevious,
    'MergedWithNext' => SplitBehavior.mergedWithNext,
    'Contiguous' => SplitBehavior.contiguous,
    _ => SplitBehavior.isolated,
  };

  static String _metaspacePrepend(Map<dynamic, dynamic> spec) {
    final scheme = spec['prepend_scheme'];
    if (scheme is String) return scheme;
    return (spec['add_prefix_space'] as bool? ?? true) ? 'always' : 'never';
  }
}

enum SplitBehavior {
  removed,
  isolated,
  mergedWithPrevious,
  mergedWithNext,
  contiguous,
}

/// Rust `regex` / Oniguruma pattern → Dart [RegExp].
///
/// The only construct Dart lacks among the shipped tokenizers is a scoped
/// case-insensitive group, `(?i:'s|'t|…)`; its letters are expanded to
/// two-case classes.
RegExp compileHfRegex(String pattern) {
  const marker = '(?i:';
  if (!pattern.contains(marker)) return RegExp(pattern, unicode: true);
  final out = StringBuffer();
  var i = 0;
  while (i < pattern.length) {
    if (pattern.startsWith(marker, i)) {
      out.write('(?:');
      i += marker.length;
      var depth = 1;
      while (i < pattern.length && depth > 0) {
        final ch = pattern[i];
        if (ch == '\\' && i + 1 < pattern.length) {
          out.write(pattern.substring(i, i + 2));
          i += 2;
          continue;
        }
        if (ch == '(') depth++;
        if (ch == ')') depth--;
        final lower = ch.toLowerCase();
        final upper = ch.toUpperCase();
        if (depth > 0 && lower != upper) {
          out.write('[$lower$upper]');
        } else {
          out.write(ch);
        }
        i++;
      }
      continue;
    }
    out.write(pattern[i]);
    i++;
  }
  return RegExp(out.toString(), unicode: true);
}

class _Sequence extends PreTokenizer {
  const _Sequence(this.parts);
  final List<PreTokenizer> parts;

  @override
  List<String> split(List<String> pieces) {
    var out = pieces;
    for (final part in parts) {
      out = part.split(out);
    }
    return out;
  }
}

class RegexSplit extends PreTokenizer {
  const RegexSplit(this.regex, {required this.behavior, this.invert = false});

  final RegExp regex;
  final SplitBehavior behavior;
  final bool invert;

  @override
  List<String> split(List<String> pieces) {
    final out = <String>[];
    for (final piece in pieces) {
      _splitOne(piece, out);
    }
    return out;
  }

  void _splitOne(String text, List<String> out) {
    if (text.isEmpty) return;
    // (text, isDelimiter) runs covering the whole piece.
    final runs = <(String, bool)>[];
    var last = 0;
    for (final m in regex.allMatches(text)) {
      if (m.end == m.start) continue;
      if (m.start > last) runs.add((text.substring(last, m.start), invert));
      runs.add((text.substring(m.start, m.end), !invert));
      last = m.end;
    }
    if (last < text.length) runs.add((text.substring(last), invert));

    switch (behavior) {
      case SplitBehavior.removed:
        for (final (s, delim) in runs) {
          if (!delim) out.add(s);
        }
      case SplitBehavior.isolated:
        for (final (s, _) in runs) {
          out.add(s);
        }
      case SplitBehavior.contiguous:
        String? pending;
        for (final (s, delim) in runs) {
          if (delim) {
            pending = (pending ?? '') + s;
          } else {
            if (pending != null) out.add(pending);
            pending = null;
            out.add(s);
          }
        }
        if (pending != null) out.add(pending);
      case SplitBehavior.mergedWithPrevious:
        final buf = StringBuffer();
        for (final (s, delim) in runs) {
          buf.write(s);
          if (delim) {
            out.add(buf.toString());
            buf.clear();
          }
        }
        if (buf.isNotEmpty) out.add(buf.toString());
      case SplitBehavior.mergedWithNext:
        final buf = StringBuffer();
        for (final (s, delim) in runs) {
          if (delim && buf.isNotEmpty) {
            out.add(buf.toString());
            buf.clear();
          }
          buf.write(s);
        }
        if (buf.isNotEmpty) out.add(buf.toString());
    }
  }
}

final _gpt2Pattern = RegExp(
  r"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+",
  unicode: true,
);

class _ByteLevelSplit extends PreTokenizer {
  const _ByteLevelSplit({required this.useRegex, required this.addPrefixSpace});

  final bool useRegex;
  final bool addPrefixSpace;

  @override
  List<String> split(List<String> pieces) {
    var input = pieces;
    if (addPrefixSpace && input.isNotEmpty && !input.first.startsWith(' ')) {
      input = [' ${input.first}', ...input.skip(1)];
    }
    if (!useRegex) return input;
    return RegexSplit(
      _gpt2Pattern,
      behavior: SplitBehavior.removed,
      invert: true,
    ).split(input);
  }
}

class _Metaspace extends PreTokenizer {
  const _Metaspace({
    required this.replacement,
    required this.prepend,
    required this.splitOnReplacement,
  });

  final String replacement;
  final String prepend;
  final bool splitOnReplacement;

  @override
  List<String> split(List<String> pieces) {
    final out = <String>[];
    for (var i = 0; i < pieces.length; i++) {
      var text = pieces[i].replaceAll(' ', replacement);
      final shouldPrepend =
          prepend == 'always' || (prepend == 'first' && i == 0);
      if (shouldPrepend && !text.startsWith(replacement)) {
        text = '$replacement$text';
      }
      if (!splitOnReplacement) {
        if (text.isNotEmpty) out.add(text);
        continue;
      }
      out.addAll(
        RegexSplit(
          RegExp(RegExp.escape(replacement)),
          behavior: SplitBehavior.mergedWithNext,
        ).split([text]),
      );
    }
    return out;
  }
}
