import 'dart:convert';

import 'json_repair.dart';

/// Tag wrapping the persistent beauty-state JSON that the LLM appends to the
/// end of an assistant response. Chosen to be unique enough not to collide
/// with HTML/CSS artifacts that may appear in the same response.
const beautyStateTag = 'glaze_beauty_state';

/// Session variable key under which the latest parsed beauty state is stored
/// in [ChatSession.sessionVars]. Preset blocks read it via
/// `{{getvar::glaze_beauty_state}}`.
const beautyStateVarKey = 'glaze_beauty_state';

/// Hardcoded color for the Lumia OOC meta-weaver's `<lumiaooc>` blocks.
/// Applied deterministically in code (see [wrapLumiaOocColors]) so the
/// cleaner LLM no longer has to color it itself — the prompt rules and the
/// `reserved.lumia_ooc` JSON field were removed to avoid the model forgetting
/// to wrap the block.
const lumiaOocColor = '#9370DB';

final RegExp _beautyStateRegex = RegExp(
  '<$beautyStateTag>([\\s\\S]*?)</$beautyStateTag>',
  caseSensitive: false,
);

/// Result of parsing beauty-state markers from an assistant response.
class BeautyStateParseResult {
  /// Text with every `<glaze_beauty_state>...</glaze_beauty_state>` tag
  /// stripped (so it never reaches the chat bubble).
  final String cleanedText;

  /// Parsed state as a JSON-encoded string suitable for storing in
  /// [ChatSession.sessionVars] under [beautyStateVarKey]. `null` when no
  /// well-formed marker was found in the response.
  final String? stateJson;

  /// True when at least one marker was found (regardless of whether the JSON
  /// payload parsed cleanly). Used for diagnostics.
  final bool markerFound;

  const BeautyStateParseResult({
    required this.cleanedText,
    required this.stateJson,
    required this.markerFound,
  });
}

/// Extracts and strips the LAST `<glaze_beauty_state>{...}</glaze_beauty_state>`
/// marker from an LLM response.
///
/// Contract:
/// * The LLM is instructed to append exactly one marker at the END of its
///   response, but we tolerate multiple markers by taking the LAST one
///   (last-write-wins semantics — the model occasionally re-emits the tag
///   after a CSS artifact block).
/// * The marker body is parsed as JSON via [repairJson] + [jsonDecode] so
///   common LLM formatting defects (trailing commas, `//` comments, ellipsis
///   placeholders) do not lose the whole state. When the payload still fails
///   to parse, [BeautyStateParseResult.stateJson] is `null` — the caller
///   leaves the previous session var untouched (state is sticky).
/// * Every marker occurrence (well-formed or not) is removed from
///   [BeautyStateParseResult.cleanedText].
///
/// Pure & synchronous — safe to call from any isolate / test.
BeautyStateParseResult parseBeautyState(String text) {
  final matches = _beautyStateRegex.allMatches(text).toList();
  if (matches.isEmpty) {
    return BeautyStateParseResult(
      cleanedText: text,
      stateJson: null,
      markerFound: false,
    );
  }

  final last = matches.last;
  String? stateJson;
  final raw = last.group(1)?.trim() ?? '';
  if (raw.isNotEmpty) {
    try {
      final repaired = repairJson(raw);
      final decoded = jsonDecode(repaired);
      if (decoded is Map<String, dynamic>) {
        stateJson = jsonEncode(decoded);
      } else if (decoded is Map) {
        stateJson = jsonEncode(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      stateJson = null;
    }
  }

  final cleaned = text.replaceAll(_beautyStateRegex, '').trim();
  return BeautyStateParseResult(
    cleanedText: cleaned,
    stateJson: stateJson,
    markerFound: true,
  );
}

/// Result of applying beauty-state extraction to an assistant response.
///
/// Carries the [text] with markers stripped and the [vars] map with the
/// parsed beauty-state JSON merged in (under [beautyStateVarKey]).
class BeautyStateResult {
  final String text;
  final Map<String, String>? vars;
  const BeautyStateResult({required this.text, required this.vars});
}

/// Strips any `<glaze_beauty_state>...</glaze_beauty_state>` marker from
/// the assistant response and merges the parsed JSON state into the pending
/// session vars (success-only persistence — INV-C5 still holds because this
/// is only called from the two success-path `writeAssistant` call sites).
/// When no marker is found, returns [text] and [vars] unchanged.
BeautyStateResult applyBeautyState(
  String text,
  Map<String, String>? pendingVars,
) {
  final parsed = parseBeautyState(text);
  if (!parsed.markerFound) {
    return BeautyStateResult(text: text, vars: pendingVars);
  }
  final vars = parsed.stateJson == null
      ? pendingVars
      : <String, String>{...?pendingVars, beautyStateVarKey: parsed.stateJson!};
  return BeautyStateResult(text: parsed.cleanedText, vars: vars);
}

/// Matches `<lumiaooc>...</lumiaooc>` blocks (case-insensitive, multiline).
final RegExp _lumiaOocBlockRegex = RegExp(
  r'<lumiaooc>([\s\S]*?)</lumiaooc>',
  caseSensitive: false,
);

/// Detects an existing `<font color="...">` tag at the start of the inner
/// content, so we do not double-wrap an already-colored block.
final RegExp _leadingFontTagRegex = RegExp(
  r'^\s*<font\s+color=',
  caseSensitive: false,
);

final RegExp _bareLumiaOocLineRegex = RegExp(
  r'(^|\n)([ \t]*)(?:Lumia|Люмия)[ \t]*(?:\(|\[)?(?:OOC|ООС)(?:\)|\])?[ \t]*:[ \t]*(.+?)(?=\n{2,}|$)',
  caseSensitive: false,
  multiLine: true,
  dotAll: true,
);

final RegExp _unclosedLumiaOocRegex = RegExp(
  r'<lumiaooc>(?![\s\S]*?</lumiaooc>)([\s\S]*)$',
  caseSensitive: false,
);

/// Deterministically wraps the text inside every `<lumiaooc>...</lumiaooc>`
/// block in [lumiaOocColor], unless it is already wrapped in a `<font>` tag.
///
/// This replaces the previous LLM-driven coloring rule that lived in the
/// `cleaner_beauty` preset block and the fallback cleaner prompt. The cleaner
/// model frequently forgot to apply the color, leaving Lumia's OOC note
/// uncolored. Because Lumia never appears mid-narrative (only inside her own
/// OOC wrapper), a deterministic post-processing pass is sufficient and
/// idempotent.
///
/// Pure & synchronous — safe to call from any isolate / test. Preserves the
/// `<lumiaooc>` wrapper, the block position, and inner whitespace/newlines.
final RegExp _fencedCodeRegex = RegExp(r'```[\s\S]*?```');

String _normalizeLumiaOocChunk(String text) {
  final canonicalBlocks = <String>[];
  final protected = text.replaceAllMapped(_lumiaOocBlockRegex, (match) {
    canonicalBlocks.add(match.group(0)!);
    return '\u0000LUMIA${canonicalBlocks.length - 1}\u0000';
  });
  var normalized = protected.replaceAllMapped(_bareLumiaOocLineRegex, (m) {
    final prefix = m.group(1) ?? '';
    final indent = m.group(2) ?? '';
    final body = (m.group(3) ?? '').trim();
    return '$prefix$indent<lumiaooc>$body</lumiaooc>';
  });
  for (var index = 0; index < canonicalBlocks.length; index++) {
    normalized = normalized.replaceFirst(
      '\u0000LUMIA$index\u0000',
      canonicalBlocks[index],
    );
  }
  normalized = normalized.replaceAllMapped(_unclosedLumiaOocRegex, (m) {
    return '<lumiaooc>${m.group(1) ?? ''}</lumiaooc>';
  });
  if (!normalized.toLowerCase().contains('<lumiaooc>')) return normalized;
  return normalized.replaceAllMapped(_lumiaOocBlockRegex, (m) {
    final inner = m.group(1) ?? '';
    if (_leadingFontTagRegex.hasMatch(inner)) return m.group(0)!;
    final full = m.group(0)!;
    final openEnd = full.indexOf('>');
    final closeStart = full.lastIndexOf('</');
    if (openEnd < 0 || closeStart < 0 || closeStart <= openEnd) {
      return '<lumiaooc><font color="$lumiaOocColor">$inner</font></lumiaooc>';
    }
    final openTag = full.substring(0, openEnd + 1);
    final closeTag = full.substring(closeStart);
    return '$openTag<font color="$lumiaOocColor">$inner</font>$closeTag';
  });
}

String wrapLumiaOocColors(String text) {
  final output = StringBuffer();
  var cursor = 0;
  for (final match in _fencedCodeRegex.allMatches(text)) {
    output.write(_normalizeLumiaOocChunk(text.substring(cursor, match.start)));
    output.write(match.group(0));
    cursor = match.end;
  }
  output.write(_normalizeLumiaOocChunk(text.substring(cursor)));
  return output.toString();
}
