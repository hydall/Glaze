import '../models/tts_settings.dart';

enum TtsSegmentType { dialogue, action, other }

/// One piece of a message that is spoken as its own clip.
class TtsSegment {
  final TtsSegmentType type;
  final String text;
  const TtsSegment(this.type, this.text);

  @override
  bool operator ==(Object other) =>
      other is TtsSegment && other.type == type && other.text == text;

  @override
  int get hashCode => Object.hash(type, text);

  @override
  String toString() => '${type.name}: $text';
}

/// The settings that shape the spoken text, separated from [TtsSettings] so
/// the preparer stays a pure function.
class TtsTextOptions {
  final bool skipCodeblocks;
  final bool skipTags;
  final bool passAsterisks;
  final bool ignoreAsterisks;
  final bool narrateQuotedOnly;
  final bool narrateByParagraphs;
  final bool multiVoice;
  final String? regexPattern;
  final String separator;

  const TtsTextOptions({
    this.skipCodeblocks = true,
    this.skipTags = false,
    this.passAsterisks = false,
    this.ignoreAsterisks = false,
    this.narrateQuotedOnly = false,
    this.narrateByParagraphs = false,
    this.multiVoice = false,
    this.regexPattern,
    this.separator = ' ... ',
  });

  factory TtsTextOptions.fromSettings(
    TtsSettings s, {
    required String separator,
    bool forceParagraphs = false,
  }) => TtsTextOptions(
    skipCodeblocks: s.skipCodeblocks,
    skipTags: s.skipTags,
    passAsterisks: s.passAsterisks,
    ignoreAsterisks: s.ignoreAsterisks,
    narrateQuotedOnly: s.narrateQuotedOnly,
    narrateByParagraphs: s.narrateByParagraphs || forceParagraphs,
    multiVoice: s.multiVoice,
    regexPattern: s.applyRegex && s.regexPattern.trim().isNotEmpty
        ? s.regexPattern
        : null,
    separator: separator,
  );
}

/// Turns a chat message into the pieces a voice should read, in the same
/// order of steps as SillyTavern: drop code and tags, the user's regex,
/// asterisks, keep only quotes if asked, drop images, collapse whitespace —
/// then cut into paragraphs and, with several voices, into quotes, actions
/// and the rest.
class TtsTextPreparer {
  const TtsTextPreparer._();

  static List<TtsSegment> prepare(
    String raw,
    TtsTextOptions o, {
    String Function(String text)? processText,
  }) {
    var text = raw;
    if (o.skipCodeblocks) {
      text = text
          .replaceAll(RegExp(r'```.*?```', dotAll: true), '')
          .replaceAll(RegExp(r'~~~.*?~~~', dotAll: true), '');
    }
    if (o.skipTags) {
      text = text.replaceAll(RegExp(r'<(\w+)[^>]*>[\s\S]*?</\1\s*>'), '');
    }
    final regex = parseUserRegex(o.regexPattern);
    if (regex != null) text = text.replaceAll(regex, '');

    final paragraphs = o.narrateByParagraphs
        ? text.split('\n')
        : <String>[text];

    final out = <TtsSegment>[];
    for (var paragraph in paragraphs) {
      if (paragraph.trim().isEmpty) continue;
      if (o.narrateQuotedOnly) {
        paragraph = joinQuotedBlocks(paragraph, separator: o.separator);
      }
      final pieces = o.multiVoice
          ? splitSegments(paragraph)
          : [TtsSegment(TtsSegmentType.other, paragraph)];
      for (final piece in pieces) {
        if (piece.type == TtsSegmentType.action && o.ignoreAsterisks) {
          continue;
        }
        var t = _cleanAsterisks(piece.text, o);
        t = _stripMarkup(t);
        if (processText != null) t = processText(t);
        t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (!_hasSpeakableText(t)) continue;
        out.add(TtsSegment(piece.type, t));
      }
    }
    return out;
  }

  static String _cleanAsterisks(String text, TtsTextOptions o) {
    if (o.passAsterisks) return text;
    return o.ignoreAsterisks
        ? text.replaceAll(RegExp(r'\*[^*]*?(\*|$)'), '')
        : text.replaceAll('*', '');
  }

  static String _stripMarkup(String text) => text
      // Markdown images, then links down to their label.
      .replaceAll(RegExp(r'!\[.*?]\([^)]*\)'), '')
      .replaceAllMapped(
        RegExp(r'\[([^\]]+)]\([^)]*\)'),
        (m) => m.group(1) ?? '',
      )
      // Leftover HTML markup — the tags only, their text stays.
      .replaceAll(RegExp(r'</?[a-zA-Z][^<>]*>'), ' ')
      .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
      .replaceAll('`', '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"');

  static bool _hasSpeakableText(String t) =>
      RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(t);

  /// Cuts text into quoted dialogue, `*actions*` and everything else.
  /// Supports straight, curly, guillemet, CJK and full-width quotes.
  static List<TtsSegment> splitSegments(String text) {
    final re = RegExp(
      r'(\*[^*]*?\*)|(".*?")|(\u201C.*?\u201D)|(\u00AB.*?\u00BB)|'
      r'(\u300C.*?\u300D)|(\u300E.*?\u300F)|(\uFF02.*?\uFF02)',
      dotAll: true,
    );
    final out = <TtsSegment>[];
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        final other = text.substring(last, m.start).trim();
        if (other.isNotEmpty) out.add(TtsSegment(TtsSegmentType.other, other));
      }
      final matched = m.group(0)!;
      final type = m.group(1) != null
          ? TtsSegmentType.action
          : TtsSegmentType.dialogue;
      final inner = matched.substring(1, matched.length - 1).trim();
      if (inner.isNotEmpty) {
        // Asterisks are kept on actions so the asterisk options still apply.
        out.add(TtsSegment(type, type == TtsSegmentType.action ? '*$inner*' : inner));
      }
      last = m.end;
    }
    if (last < text.length) {
      final rest = text.substring(last).trim();
      if (rest.isNotEmpty) out.add(TtsSegment(TtsSegmentType.other, rest));
    }
    if (out.isEmpty && text.trim().isNotEmpty) {
      out.add(TtsSegment(TtsSegmentType.other, text.trim()));
    }
    return out;
  }

  static const _quotePairs = <String, String>{
    '„': '“',
    '“': '”',
    '«': '»',
    '»': '«',
    '‘': '’',
    '‚': '‘',
    '「': '」',
    '『': '』',
    '"': '"',
    '＂': '＂',
  };

  /// Keeps only the outermost quoted passages (quotes included), joined by
  /// [separator]. Unclosed quotes are ignored. Text without quotes comes
  /// back unchanged, as in SillyTavern.
  static String joinQuotedBlocks(String text, {String separator = ' ... '}) {
    final blocks = <String>[];
    final stack = <(String, int)>[];
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (stack.isNotEmpty && ch == stack.last.$1) {
        final open = stack.removeLast();
        if (stack.isEmpty) blocks.add(text.substring(open.$2, i + 1));
        continue;
      }
      final close = _quotePairs[ch];
      if (close != null) stack.add((close, i));
    }
    if (blocks.isEmpty) return text;
    return blocks.join(separator);
  }

  /// Parses `/pattern/flags` or a bare pattern. Returns null when invalid.
  static RegExp? parseUserRegex(String? source) {
    if (source == null || source.trim().isEmpty) return null;
    final s = source.trim();
    try {
      final m = RegExp(r'^/(.+)/([a-z]*)$', dotAll: true).firstMatch(s);
      if (m == null) return RegExp(s);
      final flags = m.group(2) ?? '';
      return RegExp(
        m.group(1)!,
        caseSensitive: !flags.contains('i'),
        multiLine: flags.contains('m'),
        dotAll: flags.contains('s'),
        unicode: flags.contains('u'),
      );
    } on FormatException {
      return null;
    }
  }
}
