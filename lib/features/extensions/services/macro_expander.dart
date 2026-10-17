import '../../../core/models/character.dart';

/// Snapshot of user/character context for macro expansion.
///
/// Kept as a simple value type so [expand] stays a pure function (no
/// Riverpod, no DB, no async) — call sites fetch the snapshot from their
/// own provider and pass it in.
class MacroContext {
  const MacroContext({
    this.character,
    this.persona,
    this.personaDescription,
    this.dynamicMacros = const {},
  });

  final Character? character;
  final String? persona;

  /// The persona's description (its prompt), for `{{persona}}`.
  final String? personaDescription;

  /// Per-call macros the original extension passes as `dynamicMacros`:
  /// `{{textToRewrite}}` for a rewrite, `{{additionalPrompt}}` for a call
  /// with an extra instruction. Keys are matched case-insensitively, and
  /// their values are inserted as they are — a `{{user}}` inside the text
  /// being rewritten is left alone.
  final Map<String, String> dynamicMacros;

  static const empty = MacroContext();
}

/// Substitutes SillyTavern-style `{{...}}` placeholders in [text].
///
/// Supported placeholders:
///
/// - `{{char}}` → [MacroContext.character] name
/// - `{{user}}` → [MacroContext.persona] (empty string when null)
/// - `{{persona}}` → [MacroContext.personaDescription], as in the main macro
///   engine and SillyTavern
/// - `{{description}}` → [MacroContext.character] description
/// - `{{personality}}` → [MacroContext.character] personality
/// - `{{scenario}}` → [MacroContext.character] scenario
///
/// The substitution is **case-insensitive** for resilience (LLM prompts
/// may use `{{User}}` or `{{CHAR}}`).
///
/// The function is intentionally tolerant: missing character/persona
/// fields expand to the empty string rather than throwing. This mirrors
/// upstream SillyTavern behavior and avoids breaking block generation
/// when an optional context is absent.
String expand(String text, MacroContext ctx) {
  if (text.isEmpty) return text;
  var result = text;
  // Dynamic values go in last, through markers, so the other macros never
  // run over text that came from the chat.
  final dynamicValues = <String>[];
  for (final entry in ctx.dynamicMacros.entries) {
    final marker = '\u0000${dynamicValues.length}\u0000';
    dynamicValues.add(entry.value);
    result = _replaceCi(result, '{{${entry.key}}}', marker);
  }
  result = _replaceCi(result, '{{char}}', ctx.character?.name ?? '');
  result = _replaceCi(result, '{{user}}', ctx.persona ?? '');
  result = _replaceCi(result, '{{persona}}', ctx.personaDescription ?? '');
  result = _replaceCi(result, '{{description}}', ctx.character?.description ?? '');
  result = _replaceCi(result, '{{personality}}', ctx.character?.personality ?? '');
  result = _replaceCi(result, '{{scenario}}', ctx.character?.scenario ?? '');
  for (var i = 0; i < dynamicValues.length; i++) {
    result = result.replaceAll('\u0000$i\u0000', dynamicValues[i]);
  }
  return result;
}

String _replaceCi(String input, String placeholder, String value) {
  final pattern = RegExp(RegExp.escape(placeholder), caseSensitive: false);
  return input.replaceAll(pattern, value);
}
