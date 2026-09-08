import 'package:flutter/foundation.dart';

import '../models/preset.dart';
import '../models/character.dart';
import '../models/persona.dart';
import '../models/chat_message.dart' show TriggeredEntry;
import 'macro_engine.dart';
import 'regex_validator.dart';

class RegexApplyContext {
  final Character? char;
  final Persona? persona;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;
  final int? depth;
  final int totalMessages;

  const RegexApplyContext({
    this.char,
    this.persona,
    this.sessionVars = const {},
    this.globalVars = const {},
    this.depth,
    this.totalMessages = 0,
  });
}

String applyRegexes(
  String text,
  int placementFilter,
  int ephemeralityFilter,
  List<PresetRegex> scripts,
  RegexApplyContext ctx, {
  bool isMarkdown = false,
  bool isPrompt = false,
  List<TriggeredEntry>? triggered,
}) {
  var result = text;

  for (final script in scripts) {
    if (script.disabled) continue;

    final sPlacement = script.placement;
    if (sPlacement.isNotEmpty && !sPlacement.contains(placementFilter)) {
      if (!(script.promptOnly && isPrompt)) continue;
    }
    if (script.promptOnly && !isPrompt) continue;
    if (script.markdownOnly && !isMarkdown) continue;

    final sEphemerality = script.ephemerality;
    if (sEphemerality.isNotEmpty && !sEphemerality.contains(ephemeralityFilter)) continue;

    if (ctx.depth != null) {
      final minD = script.minDepth;
      final maxD = script.maxDepth;
      if (minD != null && ctx.depth! < minD) continue;
      if (maxD != null && ctx.depth! > maxD) continue;
    }

    final before = result;
    result = _applySingleScript(result, script, ctx);

    // Mirror Glaze's tracking: a script counts as "triggered" only when it
    // actually changed the text. Used to surface which regex fired on a
    // message in the triggered-items sheet.
    if (triggered != null && result != before) {
      if (!triggered.any((t) => t.id == script.id)) {
        triggered.add(TriggeredEntry(
          id: script.id,
          name: script.name,
          source: 'regex',
          pattern: script.regex,
        ));
      }
    }
  }

  return result;
}

String _applySingleScript(String text, PresetRegex script, RegexApplyContext ctx) {
  var processed = text;

  if (script.trimOut.isNotEmpty) {
    final tokens = script.trimOut.split('\n').where((t) => t.trim().isNotEmpty);
    for (final token in tokens) {
      processed = processed.replaceAll(token, '');
    }
  }

  var pattern = script.regex;
  var replacement = script.replacement;

  if (script.substituteRegex != 0 && ctx.char != null) {
    pattern = _substituteFindRegex(pattern, script.substituteRegex, ctx);
  }

  if (script.macroRules != '0' && ctx.char != null) {
    final macroCtx = MacroContext(
      charName: ctx.char!.name,
      userName: ctx.persona?.name ?? 'User',
      charId: ctx.char!.id,
      sessionId: '',
      macroName: ctx.char!.macroName,
    );

    if (script.macroRules == '1') {
      if (script.substituteRegex == 0) {
        pattern = replaceMacros(pattern, macroCtx).text;
      }
      replacement = replaceMacros(replacement, macroCtx).text;
    } else if (script.macroRules == '2') {
      if (script.substituteRegex == 0) {
        pattern = pattern
            .replaceAllMapped(RegExp(r'{{user}}', caseSensitive: false), (_) => _escapeRegex(ctx.persona?.name ?? 'User'))
            .replaceAllMapped(RegExp(r'{{char}}', caseSensitive: false), (_) => _escapeRegex(ctx.char!.name));
        pattern = replaceMacros(pattern, macroCtx).text;
      }
      replacement = replaceMacros(replacement, macroCtx).text;
    }
  }

  if (pattern.isEmpty) return processed;

  final safety = classifyRegexSafety(pattern);
  if (safety == RegexSafety.pathological) {
    debugPrint('[regex] skipping pathological pattern "${script.name}": $pattern');
    return processed;
  }

  final parsed = _parseRegexPattern(pattern);
  try {
    final regex = RegExp(parsed.pattern, multiLine: parsed.multiLine, dotAll: parsed.dotAll, caseSensitive: parsed.caseSensitive);

    // Always use replaceAllMapped so backreferences ($1, \1, {{match}},
    // $<name>) are resolved.  Dart's String.replaceAll does NOT interpret
    // $1/$2 in the replacement string — they stay as literal text.
    // Previous code skipped resolution when substituteRegex != 0, but
    // ST scripts routinely combine substituteRegex with capture groups.
    processed = processed.replaceAllMapped(
      regex,
      (match) => _resolveReplacement(replacement, match),
    );
  } catch (_) {}

  return processed;
}

String _substituteFindRegex(String pattern, int mode, RegexApplyContext ctx) {
  if (ctx.char == null) return pattern;
  final macroCtx = MacroContext(
    charName: ctx.char!.name,
    userName: ctx.persona?.name ?? 'User',
    charId: ctx.char!.id,
    sessionId: '',
    macroName: ctx.char!.macroName,
  );
  if (mode == 1) {
    return replaceMacros(pattern, macroCtx).text;
  }
  if (mode == 2) {
    var out = pattern
        .replaceAllMapped(RegExp(r'{{user}}', caseSensitive: false), (_) => _escapeRegex(ctx.persona?.name ?? 'User'))
        .replaceAllMapped(RegExp(r'{{char}}', caseSensitive: false), (_) => _escapeRegex(ctx.char!.name));
    return replaceMacros(out, macroCtx).text;
  }
  return pattern;
}

/// Resolves backreferences (`$1`, `\1`), `{{match}}`, and named groups (`$<name>`).
String _resolveReplacement(String template, Match match) {
  final groupCount = match.groupCount;
  var result = template;

  result = result.replaceAll('{{match}}', match.group(0) ?? '');
  if (match is RegExpMatch) {
    final regMatch = match;
    result = result.replaceAllMapped(
      RegExp(r'\$<([^>]+)>'),
      (m) => regMatch.namedGroup(m.group(1)!) ?? '',
    );
  }

  for (int i = groupCount; i >= 0; i--) {
    final captured = match.group(i) ?? '';
    result = result.replaceAll('\$$i', captured);
    result = result.replaceAll('\\$i', captured);
  }

  return result;
}

({String pattern, bool multiLine, bool dotAll, bool caseSensitive}) _parseRegexPattern(String raw) {
  if (raw.startsWith('/') && raw.length > 1) {
    final lastSlash = raw.lastIndexOf('/');
    if (lastSlash > 0) {
      final pattern = raw.substring(1, lastSlash);
      final flags = raw.substring(lastSlash + 1);
      return (
        pattern: pattern,
        multiLine: flags.contains('m'),
        dotAll: flags.contains('s'),
        caseSensitive: !flags.contains('i'),
      );
    }
  }
  return (pattern: raw, multiLine: false, dotAll: false, caseSensitive: true);
}

String _escapeRegex(String s) {
  return s.replaceAll(RegExp(r'[/\-\\^$*+?.()|[\]{}]'), r'\$&');
}
