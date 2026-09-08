import '../../../core/models/character.dart';

/// Snapshot of user/character context for macro expansion.
///
/// Kept as a simple value type so [expand] stays a pure function (no
/// Riverpod, no DB, no async) — call sites fetch the snapshot from their
/// own provider and pass it in.
class MacroContext {
  const MacroContext({this.character, this.persona});

  final Character? character;
  final String? persona;

  static const empty = MacroContext();
}

/// Substitutes SillyTavern-style `{{...}}` placeholders in [text].
///
/// Supported placeholders:
///
/// - `{{char}}` → [MacroContext.character] name
/// - `{{user}}` → [MacroContext.persona] (empty string when null)
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
  result = _replaceCi(result, '{{char}}', ctx.character?.name ?? '');
  result = _replaceCi(result, '{{user}}', ctx.persona ?? '');
  result = _replaceCi(result, '{{description}}', ctx.character?.description ?? '');
  result = _replaceCi(result, '{{personality}}', ctx.character?.personality ?? '');
  result = _replaceCi(result, '{{scenario}}', ctx.character?.scenario ?? '');
  return result;
}

String _replaceCi(String input, String placeholder, String value) {
  final pattern = RegExp(RegExp.escape(placeholder), caseSensitive: false);
  return input.replaceAll(pattern, value);
}
