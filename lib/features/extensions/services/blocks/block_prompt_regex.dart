import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/regex_service.dart';
import '../../../../core/models/character.dart';
import '../../../../core/models/persona.dart';
import '../../../../core/state/active_selection_provider.dart';
import '../../../chat/chat_provider.dart';

/// Mirrors the original extension's `getRegexedString(content, 2, { depth: 0,
/// isPrompt: true })` for a block with `applyRegex`: the active prompt regex
/// set (active preset plus global scripts) runs at depth 0, and the
/// transformed text is what gets stored.
Future<String> applyExtBlockPromptRegexes(
  Ref ref, {
  required String charId,
  required Character? character,
  required Persona? persona,
  required String content,
}) async {
  if (content.isEmpty) return content;
  final regexes = await ref.read(activeRegexesProvider.future);
  if (regexes.isEmpty) return content;
  final session = ref.read(chatProvider(charId)).value?.session;
  return applyRegexes(
    content,
    2,
    2,
    regexes,
    RegexApplyContext(
      char: character,
      persona: persona,
      sessionVars: session?.sessionVars ?? const {},
      globalVars: ref.read(globalVarsProvider),
      depth: 0,
    ),
    isPrompt: true,
  );
}
