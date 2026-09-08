import 'dart:convert';

/// Best-effort repair of JSON that an LLM has emitted with common formatting
/// defects. Returns a string that is more likely to parse cleanly via
/// [jsonDecode]; does NOT guarantee validity.
///
/// Ported from Marinara `agent-executor.ts:repairJson`. Strips:
/// - `//` line comments and `/* */` block comments that appear OUTSIDE string
///   literals (a hand-rolled char scanner tracks `inString` / `escaped`
///   flags so comments inside JSON string values are preserved verbatim).
/// - `...` ellipsis placeholders that LLMs love to emit for "more items
///   here" (only outside strings).
/// - Trailing commas immediately before `]` or `}` (the classic
///   "last element in array has a comma" mistake). Detected inside the same
///   string-aware scanner, so a literal `, ]` / `, }` inside a string value
///   is preserved verbatim.
///
/// Use this right before `jsonDecode` when the upstream text was extracted
/// from an LLM response (e.g. via `_extractJsonObject`). If [jsonDecode]
/// still fails after repair, the caller should fall back to its
/// non-JSON path (e.g. prose extraction).
///
/// Limitation: stripping `...` produces a malformed array with a missing
/// middle element (`["a", , "z"]`); this function does NOT collapse missing
/// elements — the downstream `jsonDecode` is the final authority and the
/// caller should fall back to its non-JSON path when the slot is still
/// malformed. Marinara's `repairJson` has the same limitation.
///
/// Example:
/// ```dart
/// final raw = _extractJsonObject(text);
/// if (raw == null) return null;
/// try {
///   return jsonDecode(repairJson(raw));
/// } catch (_) {
///   return null;
/// }
/// ```
/// Extract the first JSON object substring from an LLM response that may be
/// wrapped in markdown code fences and/or surrounding prose. Returns the
/// `{ ... }` slice (from the first `{` to the last `}`), or `null` if no
/// brace-delimited object is present.
///
/// Fence handling: a leading/trailing ```` ```json ```` (or any/no language
/// tag) fence is stripped first. With no fence the regex simply does not match
/// and the brace scan runs on the trimmed input — so fenced and unfenced
/// inputs both resolve to the same inner object.
///
/// Pair with [repairJson] before `jsonDecode`:
/// ```dart
/// final raw = extractJsonObject(text);
/// if (raw == null) return null;
/// try {
///   return jsonDecode(repairJson(raw));
/// } catch (_) {
///   return null;
/// }
/// ```
///
/// Consolidated from the former `MemoryStudioService._extractJsonObject`
/// (fence-aware) and `StudioBlockRouter._extractJsonObject` (brace-only) —
/// Consolidated from three former copies:
/// `MemoryStudioService._extractJsonObject` (fence-aware),
/// `StudioBlockRouter._extractJsonObject` (brace-only), and
/// `StudioDecompositionService` (fence-stripping variant). The fence-aware
/// behavior is a superset of the brace-only one for both call sites.
String? extractJsonObject(String text) {
  var trimmed = text.trim();
  final fenced = RegExp(
    r'^```(?:json)?\s*([\s\S]*?)\s*```$',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (fenced != null) trimmed = fenced.group(1)?.trim() ?? trimmed;
  final start = trimmed.indexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  return trimmed.substring(start, end + 1);
}

/// Extracts the first complete JSON array from an LLM response that may be
/// wrapped in a markdown code fence or surrounding prose.
///
/// Unlike a first/last-bracket slice, the scan balances nested arrays and
/// objects and ignores brackets inside quoted strings, including escaped
/// quotes. The returned text is not validated as JSON: common defects such as
/// comments and trailing commas are intentionally left for [repairJson].
/// Returns `null` when no complete, structurally balanced array is present.
String? extractJsonArray(String text) {
  final start = text.indexOf('[');
  if (start < 0) return null;
  return _extractBalancedJsonRoot(text, start);
}

String? _extractBalancedJsonRoot(String text, int start) {
  final delimiters = <String>[];
  var inString = false;
  var escaped = false;

  for (var i = start; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
      continue;
    }
    if (ch == '[' || ch == '{') {
      delimiters.add(ch);
      continue;
    }
    if (ch != ']' && ch != '}') continue;
    if (delimiters.isEmpty) return null;
    final opening = delimiters.removeLast();
    if ((opening == '[' && ch != ']') || (opening == '{' && ch != '}')) {
      return null;
    }
    if (delimiters.isEmpty) return text.substring(start, i + 1);
  }
  return null;
}

String repairJson(String input) {
  if (input.isEmpty) return input;
  final buf = StringBuffer();
  var i = 0;
  var inString = false;
  var escaped = false;
  while (i < input.length) {
    final ch = input[i];
    if (inString) {
      buf.write(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      i++;
      continue;
    }
    // Outside a string.
    if (ch == '"') {
      inString = true;
      buf.write(ch);
      i++;
      continue;
    }
    // Line comment `// ...` up to end-of-line.
    if (ch == '/' && i + 1 < input.length && input[i + 1] == '/') {
      i += 2;
      while (i < input.length && input[i] != '\n' && input[i] != '\r') {
        i++;
      }
      continue;
    }
    // Block comment `/* ... */`.
    if (ch == '/' && i + 1 < input.length && input[i + 1] == '*') {
      i += 2;
      while (i + 1 < input.length &&
          !(input[i] == '*' && input[i + 1] == '/')) {
        i++;
      }
      i += 2; // consume `*/`
      continue;
    }
    // Ellipsis `...` (LLM "more items here" placeholder).
    if (ch == '.' &&
        i + 2 < input.length &&
        input[i + 1] == '.' &&
        input[i + 2] == '.') {
      i += 3;
      continue;
    }
    // Trailing comma: a `,` whose next non-whitespace char (outside any
    // string) is `]` or `}`. Done inside the scanner — NOT as a post-hoc
    // regex — so a literal `, ]` / `, }` INSIDE a JSON string value (e.g.
    // {"rule": "avoid lists like [a, b, ]"}) is never touched. We only
    // reach here when `inString` is false. Peek ahead over whitespace; if
    // the comma is trailing, drop it (skip the `,`, keep the whitespace so
    // line/column shapes stay close to the original).
    if (ch == ',') {
      var j = i + 1;
      while (j < input.length &&
          (input[j] == ' ' ||
              input[j] == '\t' ||
              input[j] == '\n' ||
              input[j] == '\r')) {
        j++;
      }
      if (j < input.length && (input[j] == ']' || input[j] == '}')) {
        // Skip the comma only; the whitespace run is re-emitted by the
        // normal path on the next iterations.
        i++;
        continue;
      }
    }
    buf.write(ch);
    i++;
  }
  return buf.toString();
}
