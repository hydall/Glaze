import 'package:unorm_dart/unorm_dart.dart' as unorm;

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
      case 'NFC':
        return const _Unicode(unorm.nfc);
      case 'NFD':
        return const _Unicode(unorm.nfd);
      case 'NFKC':
        return const _Unicode(unorm.nfkc);
      case 'NFKD':
        return const _Unicode(unorm.nfkd);
      default:
        // Precompiled (SentencePiece charsmap), BertNormalizer…: identity for
        // practical input.
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

/// A Unicode normalization form. Claude's tokenizer runs NFKC, which folds
/// the styled letters character cards like to use (𝓝𝓪𝓶𝓮, ⓐⓑⓒ, ｆｕｌｌ ｗｉｄｔｈ)
/// into plain ones — without it those count several times over.
class _Unicode extends TextNormalizer {
  const _Unicode(this.form);
  final String Function(String) form;

  @override
  String apply(String text) {
    // ASCII is invariant under every form, and it is most of what is counted.
    for (final unit in text.codeUnits) {
      if (unit >= 0x80) return form(text);
    }
    return text;
  }
}
