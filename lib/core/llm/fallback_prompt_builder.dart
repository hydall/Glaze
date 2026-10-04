import '../models/chat_message.dart';
import 'context_calculator.dart';
import 'history_assembler.dart';
import 'macro_engine.dart';
import 'prompt_builder.dart';

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
    gameTime: payload.gameTime,
    gameDate: payload.gameDate,
    gameDay: payload.gameDay,
  );

  const systemMessage = PromptMessage(
    role: 'system',
    content: 'You are a helpful assistant.',
  );
  final history = <PromptMessage>[];

  for (final msg in payload.history.where(
    (message) => !message.isHidden && !message.isTyping,
  )) {
    final macroResult = replaceMacros(msg.content, macroCtx);
    history.add(
      PromptMessage(
        role: msg.role,
        content: macroResult.text,
        reasoningContent: msg.reasoning,
        isHistory: true,
        sourceMessageId: msg.id,
        imagePaths: msg.imageHidden ? const [] : msg.attachments,
      ),
    );
  }

  final calculator = ContextCalculator(
    contextSize: payload.apiConfig.contextSize,
    maxTokens: payload.apiConfig.maxTokens,
    reasoningHistoryCount: payload.apiConfig.reasoningHistoryCount,
    excludeReasoningFromContextBudget:
        payload.apiConfig.excludeReasoningFromContextBudget,
    historyTrimMode: payload.apiConfig.historyTrimMode,
    historyAnchorId: payload.sessionVars[ChatSessionX.historyAnchorVarKey],
    historyTrimTriggerPercent: payload.apiConfig.historyTrimTriggerPercent,
    historyTrimStepPercent: payload.apiConfig.historyTrimStepPercent,
  );
  final ledgerMessages = <PromptMessage>[
    if (payload.characterKnowledgeContent case final content?
        when content.isNotEmpty)
      PromptMessage(
        role: 'system',
        content: content,
        blockId: 'current_character_state',
      ),
    if (payload.studioSessionStateContent case final content?
        when content.isNotEmpty)
      PromptMessage(
        role: 'system',
        content: content,
        blockId: 'studio_session_state',
      ),
    if (payload.arcContent case final content? when content.isNotEmpty)
      PromptMessage(role: 'system', content: content, blockId: 'arc_state'),
  ];
  final breakdown = calculator.calculate(
    staticBlocks: [
      const StaticBlock(
        id: 'fallback_system',
        content: 'You are a helpful assistant.',
      ),
      for (final message in ledgerMessages)
        StaticBlock(id: message.blockId ?? 'preset', content: message.content),
    ],
    historyMessages: history,
  );

  return PromptResult(
    messages: [
      systemMessage,
      ...ledgerMessages,
      ...insertContinueInstruction(
        breakdown.trimmedHistory,
        payload.continueInstruction,
      ),
    ],
    breakdown: breakdown,
    sessionVars: payload.sessionVars,
    globalVars: payload.globalVars,
  );
}
