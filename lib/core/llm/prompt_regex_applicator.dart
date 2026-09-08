import '../models/character.dart';
import '../models/persona.dart';
import '../models/preset.dart';
import 'history_assembler.dart';
import 'regex_service.dart';

/// Applies preset + global regex scripts to the final prompt message list.
///
/// History messages receive per-message depth context and placement `1`
/// (user) / `2` (assistant). Non-history messages receive placement `4`
/// (static) or `5` (lorebook) with a shared context (no depth).
///
/// Returns a new list; the input [messages] is not mutated.
List<PromptMessage> applyPromptRegexes({
  required List<PromptMessage> messages,
  required Character char,
  Persona? persona,
  required Map<String, String> sessionVars,
  required Map<String, String> globalVars,
  required List<PresetRegex> regexScripts,
}) {
  if (regexScripts.isEmpty) return messages;

  final historyCount = messages.where((m) => m.isHistory).length;
  final baseCtx = RegexApplyContext(
    char: char,
    persona: persona,
    sessionVars: sessionVars,
    globalVars: globalVars,
  );

  final result = <PromptMessage>[];
  var historySeen = 0;

  for (final msg in messages) {
    if (msg.isHistory) {
      final placement = msg.role == 'user' ? 1 : 2;
      final depth = historyCount - 1 - historySeen;
      final ctx = RegexApplyContext(
        char: char,
        persona: persona,
        sessionVars: sessionVars,
        globalVars: globalVars,
        depth: depth,
      );
      result.add(
        PromptMessage(
          role: msg.role,
          content: applyRegexes(
            msg.content,
            placement,
            2,
            regexScripts,
            ctx,
            isPrompt: true,
          ),
          blockId: msg.blockId,
          isLorebook: msg.isLorebook,
          blockName: msg.blockName,
          isHistory: msg.isHistory,
          isDepth: msg.isDepth,
          depth: msg.depth,
          sourceMessageId: msg.sourceMessageId,
          reasoningContent: msg.reasoningContent,
          imagePath: msg.imagePath,
        ),
      );
      historySeen++;
    } else {
      final placement = msg.isLorebook ? 5 : 4;
      result.add(
        PromptMessage(
          role: msg.role,
          content: applyRegexes(
            msg.content,
            placement,
            2,
            regexScripts,
            baseCtx,
            isPrompt: true,
          ),
          blockId: msg.blockId,
          isLorebook: msg.isLorebook,
          blockName: msg.blockName,
          isHistory: msg.isHistory,
          isDepth: msg.isDepth,
          depth: msg.depth,
          sourceMessageId: msg.sourceMessageId,
          reasoningContent: msg.reasoningContent,
          imagePath: msg.imagePath,
        ),
      );
    }
  }
  return result;
}
