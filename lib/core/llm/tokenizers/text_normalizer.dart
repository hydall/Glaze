/// The subset of HuggingFace `tokenizer.json` normalizers Glaze needs to count
/// tokens for the models it resolves to.
///
/// Built from the same JSON spec whether it comes straight from the downloaded
/// `tokenizer.json` or from Glaze's compact cache, so both paths agree.
abstract class TextNormalizer {
  const TextNormalizer();

  String apply(String text);

  /// Returns null for a spec that is null or a no-op.
  static TextNormalizer? fromSpec(Object? spec) {
    if (spec is! Map) return null;
    switch (spec['type']) {
      case 'Sequence':
        final parts = [
          for (final child in (spec['normalizers'] as List? ?? const []))
            ?fromSpec(child),
        ];
        if (parts.isEmpty) return null;
        return parts.length == 1 ? parts.single : _Sequence(parts);
      case 'Replace':
        final pattern = spec['pattern'];
        final content = spec['content'] as String? ?? '';
        if (pattern is Map && pattern['String'] is String) {
          return _Replace(pattern['String'] as String, content);
        }
        if (pattern is Map && pattern['Regex'] is String) {
          return _RegexReplace(
            RegExp(pattern['Regex'] as String, unicode: true),
            content,
          );
        }
        return null;
      case 'Prepend':
        return _Prepend(spec['prepend'] as String? ?? '');
      case 'Lowercase':
        return const _Lowercase();
      case 'Strip':
        return _Strip(
          left: spec['strip_left'] as bool? ?? true,
          right: spec['strip_right'] as bool? ?? true,
        );
      case 'NFKC':
      case 'NFKD':
        // Dart has no Unicode normalization. Fold the compatibility characters
        // that actually turn up in roleplay text (ellipsis, no-break space,
        // full-width ASCII); canonical composition is a no-op for text that is
        // already NFC, which is nearly all of it.
        return const _CompatibilityFold();
      default:
        // NFC/NFD, Precompiled (SentencePiece charsmap), BertNormalizer…:
        // identity for practical input.
        return null;
    }
  }
}

class _Sequence extends TextNormalizer {
  const _Sequence(this.parts);
  final List<TextNormalizer> parts;

  @override
  String apply(String text) {
    var out = text;
    for (final part in parts) {
      out = part.apply(out);
    }
    return out;
  }
}

class _Replace extends TextNormalizer {
  const _Replace(this.pattern, this.content);
  final String pattern;
  final String content;

  @override
  String apply(String text) => text.replaceAll(pattern, content);
}

class _RegexReplace extends TextNormalizer {
  const _RegexReplace(this.pattern, this.content);
  final RegExp pattern;
  final String content;

  @override
  String apply(String text) => text.replaceAll(pattern, content);
}

class _Prepend extends TextNormalizer {
  const _Prepend(this.prefix);
  final String prefix;

  @override
  String apply(String text) => text.isEmpty ? text : '$prefix$text';
}

class _Lowercase extends TextNormalizer {
  const _Lowercase();

  @override
  String apply(String text) => text.toLowerCase();
}

class _Strip extends TextNormalizer {
  const _Strip({required this.left, required this.right});
  final bool left;
  final bool right;

  @override
  String apply(String text) {
    if (left && right) return text.trim();
    if (left) return text.trimLeft();
    if (right) return text.trimRight();
    return text;
  }
}

class _CompatibilityFold extends TextNormalizer {
  const _CompatibilityFold();

  static const _map = <int, String>{
    0x00A0: ' ',
    0x2002: ' ',
    0x2003: ' ',
    0x2009: ' ',
    0x202F: ' ',
    0x2026: '...',
    0x2025: '..',
    0x2122: 'TM',
    0xFB00: 'ff',
    0xFB01: 'fi',
    0xFB02: 'fl',
    0xFB03: 'ffi',
    0xFB04: 'ffl',
    0x3000: ' ',
  };

  @override
  String apply(String text) {
    var needed = false;
    for (final unit in text.codeUnits) {
      if (_map.containsKey(unit) || (unit >= 0xFF01 && unit <= 0xFF5E)) {
        needed = true;
        break;
      }
    }
    if (!needed) return text;
    final out = StringBuffer();
    for (final unit in text.codeUnits) {
      final mapped = _map[unit];
      if (mapped != null) {
        out.write(mapped);
      } else if (unit >= 0xFF01 && unit <= 0xFF5E) {
        out.writeCharCode(unit - 0xFEE0);
      } else {
        out.writeCharCode(unit);
      }
    }
    return out.toString();
  }
}
