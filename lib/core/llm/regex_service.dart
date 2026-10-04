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
  final MacroContext? macroContext;

  const RegexApplyContext({
    this.char,
    this.persona,
    this.sessionVars = const {},
    this.globalVars = const {},
    this.depth,
    this.totalMessages = 0,
    this.macroContext,
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
  bool ignoreEphemerality = false,
  List<TriggeredEntry>? triggered,
}) {
  var result = text;

  for (final script in scripts) {
    if (script.disabled) continue;

    final sPlacement = script.placement;
    if (sPlacement.isNotEmpty && !sPlacement.contains(placementFilter)) {
      if (!(script.promptOnly && isPrompt)) {
        continue;
      }
    }
    // ST semantics: "Only Format Display" (markdownOnly) and "Only Format
    // Prompt" (promptOnly) are two independent opt-ins, not one exclusive
    // switch — `getRegexedString` ORs the two clauses. A script that ticks
    // both therefore runs in the display pass *and* in the prompt pass.
    // Requiring both at once made such a script dead everywhere, because no
    // caller passes `isMarkdown` and `isPrompt` together.
    //
    // The storage pass (run-on-edit) passes neither flag, and still skips
    // both kinds: a display- or prompt-scoped rewrite must never be baked
    // into the stored message.
    if (script.promptOnly || script.markdownOnly) {
      final wantsThisPass =
          (script.promptOnly && isPrompt) ||
          (script.markdownOnly && isMarkdown);
      if (!wantsThisPass) continue;
    }

    final sEphemerality = script.ephemerality;
    if (!ignoreEphemerality &&
        sEphemerality.isNotEmpty &&
        !sEphemerality.contains(ephemeralityFilter)) {
      continue;
    }

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
        triggered.add(
          TriggeredEntry(
            id: script.id,
            name: script.name,
            source: 'regex',
            pattern: script.regex,
          ),
        );
      }
    }
  }

  return result;
}

String _applySingleScript(
  String text,
  PresetRegex script,
  RegexApplyContext ctx,
) {
  var processed = text;

  var pattern = script.regex;
  final replacement = _decodeReplacementEscapes(script.replacement);
  final macroCtx = _macroContextFor(ctx);

  // ST's `filterString`: every trim string is macro-substituted, and the
  // trimming applies to the *matched* text that gets spliced into the
  // replacement — never to parts of the message the script did not match.
  final trimStrings = [
    for (final token in script.trimOut.split('\n'))
      if (token.trim().isNotEmpty)
        macroCtx == null ? token : replaceMacros(token, macroCtx).text,
  ];

  if (script.substituteRegex != 0 && macroCtx != null) {
    pattern = _substituteFindRegex(pattern, script.substituteRegex, ctx);
  }

  // `macroRules` is the Glaze-side twin of ST's `substituteRegex`: it only
  // controls the *find* field. Macros in the replacement are handled below,
  // per match, exactly like ST's `runRegexScript`.
  if (script.macroRules != '0' &&
      script.substituteRegex == 0 &&
      macroCtx != null) {
    if (script.macroRules == '2') {
      pattern = pattern
          .replaceAllMapped(
            RegExp(r'{{user}}', caseSensitive: false),
            (_) => _escapeRegex(macroCtx.userName),
          )
          .replaceAllMapped(
            RegExp(r'{{char}}', caseSensitive: false),
            (_) => _escapeRegex(macroCtx.charName),
          );
    }
    pattern = replaceMacros(pattern, macroCtx).text;
  }

  if (pattern.isEmpty) return processed;

  final safety = classifyRegexSafety(pattern);
  if (safety == RegexSafety.pathological) {
    debugPrint(
      '[regex] skipping pathological pattern "${script.name}": $pattern',
    );
    return processed;
  }

  final parsed = _parseRegexPattern(pattern);
  try {
    final regex = RegExp(
      parsed.pattern,
      multiLine: parsed.multiLine,
      dotAll: parsed.dotAll,
      caseSensitive: parsed.caseSensitive,
    );

    // Always use replaceAllMapped so backreferences ($1, \1, {{match}},
    // $<name>) are resolved.  Dart's String.replaceAll does NOT interpret
    // $1/$2 in the replacement string — they stay as literal text.
    // Previous code skipped resolution when substituteRegex != 0, but
    // ST scripts routinely combine substituteRegex with capture groups.
    //
    // Macros in the replacement are expanded *after* the capture groups are
    // filled in and on every match, mirroring ST's `runRegexScript`, which
    // ends with `return substituteParams(replaceWithGroups)`. ST does this
    // unconditionally — `substituteRegex` (our `macroRules`) only governs the
    // find field — so a card-rendering script whose "Replace With" contains
    // `{{user}}` / `{{char}}` resolves without any extra toggle.
    processed = processed.replaceAllMapped(regex, (match) {
      final resolved = _resolveReplacement(replacement, match, trimStrings);
      // Fast path: the macro engine runs dozens of regexes, and a script like
      // "replace every space" fires this callback thousands of times per
      // message. No brace, no macro — nothing for it to do.
      if (macroCtx == null || !resolved.contains('{')) return resolved;
      return replaceMacros(resolved, macroCtx).text;
    });
  } catch (_) {}

  return processed;
}

/// The macro context used for macro substitution inside a regex script, or
/// null when the caller supplied neither an explicit context nor a character
/// (macros are then left untouched).
MacroContext? _macroContextFor(RegexApplyContext ctx) {
  if (ctx.macroContext != null) return ctx.macroContext;
  final char = ctx.char;
  if (char == null) return null;
  return MacroContext(
    charName: char.name,
    userName: ctx.persona?.name ?? 'User',
    charId: char.id,
    sessionId: '',
    macroName: char.macroName,
    sessionVars: ctx.sessionVars,
    globalVars: ctx.globalVars,
  );
}

String _substituteFindRegex(String pattern, int mode, RegexApplyContext ctx) {
  final macroCtx = _macroContextFor(ctx);
  if (macroCtx == null) return pattern;
  if (mode == 1) {
    return replaceMacros(pattern, macroCtx).text;
  }
  if (mode == 2) {
    var out = pattern
        .replaceAllMapped(
          RegExp(r'{{user}}', caseSensitive: false),
          (_) => _escapeRegex(macroCtx.userName),
        )
        .replaceAllMapped(
          RegExp(r'{{char}}', caseSensitive: false),
          (_) => _escapeRegex(macroCtx.charName),
        );
    return replaceMacros(out, macroCtx).text;
  }
  return pattern;
}

/// Resolves backreferences (`$1`, `\1`), `{{match}}`, and named groups
/// (`$<name>`), trimming [trimStrings] out of every spliced-in match.
///
/// Mirrors ST's `runRegexScript`: `{{match}}` is rewritten to `$0` up front and
/// all references are then resolved in a single pass, so text pulled in from
/// the message is never rescanned for further backreferences. Each inserted
/// value goes through ST's `filterString` (the trim strings).
String _resolveReplacement(
  String template,
  Match match,
  List<String> trimStrings,
) {
  final groupCount = match.groupCount;

  String filtered(String? value) {
    var out = value ?? '';
    if (out.isEmpty) return out;
    for (final trim in trimStrings) {
      out = out.replaceAll(trim, '');
    }
    return out;
  }

  String? groupAt(int index) {
    if (index < 0 || index > groupCount) return null;
    return match.group(index);
  }

  final withMatchMacro = template.replaceAll(
    RegExp(r'\{\{match\}\}', caseSensitive: false),
    r'$0',
  );

  return withMatchMacro.replaceAllMapped(
    RegExp(r'\$(\d+)|\$<([^>]+)>|\\(\d+)'),
    (m) {
      final named = m.group(2);
      if (named != null) {
        final regMatch = match;
        if (regMatch is! RegExpMatch) return '';
        try {
          return filtered(regMatch.namedGroup(named));
        } on ArgumentError {
          // The pattern has no group by that name — ST yields an empty
          // string rather than failing the whole replacement.
          return '';
        }
      }
      final numbered = int.tryParse(m.group(1) ?? m.group(3) ?? '');
      if (numbered == null) return '';
      return filtered(groupAt(numbered));
    },
  );
}

({String pattern, bool multiLine, bool dotAll, bool caseSensitive})
_parseRegexPattern(String raw) {
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
  return RegExp.escape(s);
}

/// Decodes escape sequences in a "Replace With" template before it is applied,
/// mirroring SillyTavern's behavior for the replacement field.
///
/// - `\uXXXX` and `\u{XXXX}` → the corresponding code point.
/// - `\n`, `\t`, `\r`, `\\` → newline / tab / carriage return / backslash.
/// - `\0`..`\9` are left untouched so `_resolveReplacement` can treat them as
///   capture-group backreferences.
String _decodeReplacementEscapes(String input) {
  if (input.isEmpty || !input.contains('\\')) return input;

  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final c = input[i];
    if (c != '\\' || i == input.length - 1) {
      out.write(c);
      i++;
      continue;
    }

    final next = input[i + 1];

    if (next == 'u') {
      var consumed = false;
      if (i + 2 < input.length && input[i + 2] == '{') {
        final close = input.indexOf('}', i + 3);
        if (close != -1) {
          final code = int.tryParse(input.substring(i + 3, close), radix: 16);
          if (code != null && code > 0 && code <= 0x10FFFF) {
            out.write(String.fromCharCodes([code]));
            i = close + 1;
            consumed = true;
          }
        }
      } else if (i + 5 < input.length) {
        final hex = input.substring(i + 2, i + 6);
        if (RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hex)) {
          final code = int.tryParse(hex, radix: 16);
          if (code != null && code > 0) {
            out.write(String.fromCharCodes([code]));
            i += 6;
            consumed = true;
          }
        }
      }
      if (consumed) continue;
      out.write(c);
      i++;
      continue;
    }

    // Digit following a backslash is a capture-group reference, not an escape.
    if (RegExp(r'[0-9]').hasMatch(next)) {
      out.write(c);
      i++;
      continue;
    }

    switch (next) {
      case 'n':
        out.write('\n');
        i += 2;
      case 't':
        out.write('\t');
        i += 2;
      case 'r':
        out.write('\r');
        i += 2;
      case '\\':
        out.write(r'\');
        i += 2;
      default:
        out.write(c);
        i++;
    }
  }
  return out.toString();
}
