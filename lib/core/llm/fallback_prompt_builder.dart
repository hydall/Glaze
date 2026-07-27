import 'context_calculator.dart';
import 'history_assembler.dart';
import 'macro_engine.dart';
import 'prompt_builder.dart';
import 'tokenizer.dart';

PromptResult buildFallbackPrompt(PromptPayload payload) {
  final macroCtx = MacroContext(
    charName: payload.character.name,
    charDescription: payload.character.description,
    charScenario: payload.character.scenario,
    charPersonality: payload.character.personality,
    charMesExample: payload.character.mesExample,
    userName: payload.persona?.name ?? 'User',
    personaPrompt: payload.persona?.prompt,
    charId: payload.character.id,
    sessionId: '',
    sessionVars: payload.sessionVars,
    globalVars: payload.globalVars,
    macroName: payload.character.macroName,
  );

  final messages = <PromptMessage>[];
  messages.add(const PromptMessage(role: 'system', content: 'You are a helpful assistant.'));

  for (final msg in payload.history) {
    final macroResult = replaceMacros(msg.content, macroCtx);
    messages.add(
      PromptMessage(
        role: msg.role,
        content: macroResult.text,
        imagePath: msg.imageHidden ? null : msg.imagePath,
      ),
    );
  }

  return PromptResult(
    messages: messages,
    breakdown: TokenBreakdown(
      sourceTokens: {'preset': 6},
      staticTotal: 6,
      historyBudget: payload.apiConfig.contextSize - payload.apiConfig.maxTokens - 6,
      historyTokens: messages.fold(0, (sum, m) => sum + estimateTokens(m.content)),
      totalTokens: messages.fold(0, (sum, m) => sum + estimateTokens(m.content)),
      cutoffIndex: 0,
      trimmedHistory: messages.skip(1).toList(),
    ),
    sessionVars: payload.sessionVars,
    globalVars: payload.globalVars,
  );
}
