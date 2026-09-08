/// Pure-Dart port of the SillyTavern `janitor-lorebook` plugin's `separate.cjs`.
///
/// Isolates the injected **closed-lorebook** text from a captured JanitorAI
/// `generateAlpha` payload's system message. JanitorAI assembles
/// `messages[0].content` (role: system) as:
///
/// ```
/// [ jailbreak / system prefix ]            <- leading bracketed block(s)
/// <{{char}}'s Persona> ... </...Persona>   <- character card
/// <UserPersona> ... </UserPersona>         <- user persona
/// <Scenario> ... </Scenario>               <- scenario (optional)
/// <Example...> ... </Example...>           <- example dialogue (optional)
/// <triggered lorebook entries ...>         <- everything else (what we want)
/// ```
///
/// No Flutter / IO dependencies — this is the deterministic, unit-tested core
/// of the extractor.
library;

/// A wrapper block removed from the system content, kept for diagnostics.
class RemovedBlock {
  final String label;
  final String text;
  const RemovedBlock(this.label, this.text);
}

/// Result of [separate]: the isolated [lorebookText], the [removed] wrapper
/// blocks, and a blank-line split of the lorebook text into [entries].
class SeparationResult {
  final String systemContent;
  final String lorebookText;
  final List<RemovedBlock> removed;
  final List<String> entries;
  const SeparationResult({
    required this.systemContent,
    required this.lorebookText,
    required this.removed,
    required this.entries,
  });
}

String _norm(String s) =>
    s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

/// Reads the role:`system` message content from a captured `generateAlpha`
/// payload. Returns '' when absent.
String getSystemContent(Map<String, dynamic> payload) {
  final msgs = payload['messages'];
  if (msgs is! List) return '';
  for (final m in msgs) {
    if (m is Map && m['role'] == 'system' && m['content'] is String) {
      return m['content'] as String;
    }
  }
  return '';
}

// Regexes ported verbatim from separate.cjs. Dart uses [\s\S] for "any char
// including newline" (no /s flag needed) and supports inline-grouped flags via
// RegExp(caseSensitive/multiLine).
final _leadingJailbreak = RegExp(r'^\s*(?:\[[^\]]*\]\s*)+');
final _personaBlock =
    RegExp(r'<[^<>\n]*?Persona>[\s\S]*?</[^<>\n]*?Persona>', caseSensitive: false);
final _scenarioBlock =
    RegExp(r'<Scenario>[\s\S]*?</Scenario>', caseSensitive: false);
final _exampleBlock = RegExp(
    r'<Example[^<>\n]*>[\s\S]*?</Example[^<>\n]*>',
    caseSensitive: false);

/// Removes leading bracketed jailbreak/system prefix and the
/// `<...Persona>` / `<Scenario>` / `<Example>` blocks. Returns the stripped
/// text plus the removed blocks (labelled).
({String out, List<RemovedBlock> removed}) _stripWrappers(String text) {
  final removed = <RemovedBlock>[];
  var out = text;

  out = out.replaceFirstMapped(_leadingJailbreak, (m) {
    final t = m[0]!.trim();
    if (t.isNotEmpty) removed.add(RemovedBlock('jailbreak', t));
    return '';
  });

  out = out.replaceAllMapped(_personaBlock, (m) {
    final block = m[0]!;
    final label = RegExp(r'^<\s*userpersona', caseSensitive: false).hasMatch(block)
        ? 'userPersona'
        : 'card';
    removed.add(RemovedBlock(label, block));
    return '\n';
  });

  out = out.replaceAllMapped(_scenarioBlock, (m) {
    removed.add(RemovedBlock('scenario', m[0]!));
    return '\n';
  });

  out = out.replaceAllMapped(_exampleBlock, (m) {
    removed.add(RemovedBlock('example', m[0]!));
    return '\n';
  });

  return (out: out, removed: removed);
}

/// Drops lines from [text] that also appear (normalised) in [knownCard], to
/// scrub any card text that survived wrapper stripping. Only lines >= 12 chars
/// are considered (avoids dropping short shared phrases).
({String out, List<String> removed}) _subtractKnownCard(
    String text, String knownCard) {
  if (knownCard.trim().isEmpty) return (out: text, removed: const []);
  final known = <String>{};
  for (final line in knownCard.split('\n')) {
    final n = _norm(line);
    if (n.length >= 12) known.add(n);
  }
  final removed = <String>[];
  final kept = <String>[];
  for (final line in text.split('\n')) {
    final n = _norm(line);
    if (n.length >= 12 && known.contains(n)) {
      removed.add(line);
    } else {
      kept.add(line);
    }
  }
  return (out: kept.join('\n'), removed: removed);
}

/// Builds a whitespace/punctuation-tolerant regex source from a verbatim string.
///
/// The public-entry content is injected into `generateAlpha` verbatim, but the
/// server (and our own tidying) can change *whitespace* (collapse runs, swap
/// newlines for spaces, trim) and *glyphs* (straight vs. curly quotes/
/// apostrophes, hyphen vs. en/em dash). We match literally except that any
/// whitespace run matches any other, and quote/apostrophe/dash variants match
/// each other. Everything else (including regex metacharacters) is escaped.
/// Port of separate.cjs `loosePattern`.
String _loosePattern(String needle) => needle
    .replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\]'), (m) => '\\${m[0]}')
    .replaceAll(RegExp(r'\s+'), r'\s+')
    .replaceAll(RegExp(r'''['‘’ʼ]'''), r"['‘’ʼ]")
    .replaceAll(RegExp(r'["“”]'), r'["“”]')
    .replaceAll(RegExp(r'[-–—]'), r'[-–—]');

/// Removes PUBLIC-lorebook entry text from the isolated lorebook text.
///
/// A character's public and closed lorebooks are injected into the SAME
/// `generateAlpha` system message, so the extracted text contains both. The
/// public entries' `content` is injected **verbatim**, so we cut it back out
/// (with the whitespace/glyph tolerance of [_loosePattern]) — entries that
/// never triggered simply aren't found and are skipped. Port of separate.cjs
/// `stripPublicEntries`.
({String out, List<String> removed}) _stripPublicEntries(
    String text, List<String> publicContents) {
  if (publicContents.isEmpty) return (out: text, removed: const []);
  var out = text;
  final removed = <String>[];
  for (final content in publicContents) {
    final needle = content.trim();
    if (needle.length < 12) continue;
    RegExp re;
    try {
      re = RegExp(_loosePattern(needle), caseSensitive: false);
    } catch (_) {
      continue;
    }
    out = out.replaceAllMapped(re, (m) {
      removed.add(m[0]!);
      return '\n';
    });
  }
  return (out: out, removed: removed);
}

String _tidy(String text) => text
    .replaceAll(RegExp(r'[ \t]+\n'), '\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

/// Strips the leading bracketed jailbreak/system-prefix block(s) from [text].
/// Used by the full-prompt path so the model isn't fed the jailbreak prologue as
/// if it were a lorebook entry; the persona/scenario/entries are left intact.
String stripLeadingJailbreak(String text) =>
    text.replaceFirst(_leadingJailbreak, '').trim();

/// Splits the isolated lorebook text into discrete entry blocks on blank lines.
List<String> splitEntries(String text) => text
    .split(RegExp(r'\n\s*\n'))
    .map((b) => b.trim())
    .where((b) => b.isNotEmpty)
    .toList();

/// Pulls the character-card text (inner of `<{{char}}'s Persona>`, NOT the user
/// persona). Returns '' when absent.
String extractCard(Map<String, dynamic> payload) {
  final sys = getSystemContent(payload);
  final re = RegExp(
      r'<([^<>\n]*?)Persona>([\s\S]*?)</[^<>\n]*?Persona>',
      caseSensitive: false);
  for (final m in re.allMatches(sys)) {
    if (RegExp(r'^\s*user', caseSensitive: false).hasMatch(m[1]!)) continue;
    return m[2]!.trim();
  }
  return '';
}

/// Pulls the character name from the persona tag (`<Name's Persona>`).
String extractCharName(Map<String, dynamic> payload) {
  final sys = getSystemContent(payload);
  final m = RegExp(r'<([^<>\n]*?)Persona>', caseSensitive: false).firstMatch(sys);
  if (m != null) {
    final name = m[1]!.replaceAll(RegExp(r"['’]s\s*$", caseSensitive: false), '').trim();
    if (name.toLowerCase() != 'user') return name;
  }
  return '';
}

String extractScenario(Map<String, dynamic> payload) {
  final m = RegExp(r'<Scenario>([\s\S]*?)</Scenario>', caseSensitive: false)
      .firstMatch(getSystemContent(payload));
  return m != null ? m[1]!.trim() : '';
}

String extractExample(Map<String, dynamic> payload) {
  final m = RegExp(r'<Example[^<>\n]*?>([\s\S]*?)</Example[^<>\n]*?>',
          caseSensitive: false)
      .firstMatch(getSystemContent(payload));
  return m != null ? m[1]!.trim() : '';
}

/// The first assistant message in the payload (JanitorAI's first greeting).
String extractFirstMessage(Map<String, dynamic> payload) {
  final msgs = payload['messages'];
  if (msgs is! List) return '';
  for (final m in msgs) {
    if (m is Map && m['role'] == 'assistant' && m['content'] is String) {
      return (m['content'] as String).trim();
    }
  }
  return '';
}

/// Isolates the closed-lorebook text from [payload]. Pass the known card text
/// (e.g. [extractCard]) as [knownCard] to scrub any card lines that leaked past
/// wrapper stripping, and the verbatim entry contents of the character's PUBLIC
/// lorebooks as [publicContents] so they are always subtracted and never leak
/// into the closed book (both lorebooks are injected into the same system
/// message). Port of separate.cjs `separate(payload, knownCard, publicContents)`.
SeparationResult separate(
  Map<String, dynamic> payload, [
  String knownCard = '',
  List<String> publicContents = const [],
]) {
  final systemContent = getSystemContent(payload);
  final a = _stripWrappers(systemContent);
  final b = _subtractKnownCard(a.out, knownCard);
  final c = _stripPublicEntries(b.out, publicContents);
  final lorebookText = _tidy(c.out);
  final removed = [
    ...a.removed,
    if (b.removed.isNotEmpty) RemovedBlock('knownCard', b.removed.join('\n')),
    if (c.removed.isNotEmpty)
      RemovedBlock('publicLorebook', c.removed.join('\n\n')),
  ];
  return SeparationResult(
    systemContent: systemContent,
    lorebookText: lorebookText,
    removed: removed,
    entries: splitEntries(lorebookText),
  );
}
