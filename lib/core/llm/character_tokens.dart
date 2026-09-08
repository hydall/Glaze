import '../models/character.dart';
import 'tokenizer.dart' as tok;

/// Heuristic token count for a local character, mirroring what the prompt
/// builder concatenates (name + the long text fields).
///
/// Computed once on import/save and persisted to `characters.tokenCount`; the
/// UI reads the cached value instead of re-encoding on every build. The
/// underlying [tok.estimateTokens] is itself memoized, so the rare live
/// fallback (un-migrated rows) is still cheap.
int estimateCharacterTokens(Character char) => estimateCharacterTokensFromParts(
      name: char.name,
      description: char.description,
      personality: char.personality,
      scenario: char.scenario,
      firstMes: char.firstMes,
      mesExample: char.mesExample,
    );

int estimateCharacterTokensFromParts({
  required String name,
  String? description,
  String? personality,
  String? scenario,
  String? firstMes,
  String? mesExample,
}) {
  var text = name;
  if (description != null) text += '\n$description';
  if (personality != null) text += '\n$personality';
  if (scenario != null) text += '\n$scenario';
  if (firstMes != null) text += '\n$firstMes';
  if (mesExample != null) text += '\n$mesExample';
  return tok.estimateTokens(text);
}
