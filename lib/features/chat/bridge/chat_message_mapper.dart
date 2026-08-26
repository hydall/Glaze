import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/regex_service.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/utils/think_tags.dart';

part 'chat_message_mapper.freezed.dart';

@freezed
abstract class ChatMessageMapperContext with _$ChatMessageMapperContext {
  const factory ChatMessageMapperContext({
    String? currentCharName,
    String? currentCharColor,
    String? currentPersonaName,
    String? charAvatarDataUrl,
    String? personaAvatarDataUrl,
    required bool isGenerating,

    /// Post-stream work is active. This is intentionally distinct from
    /// [isGenerating], which covers only the main response stream.
    @Default(false) bool isPostGenRunning,
    @Default({}) Set<String> coveredMemoryIds,
    @Default({}) Set<String> pendingMemoryIds,
    @Default({}) Set<String> draftMemoryIds,
    @Default(0) int greetingTotal,

    /// messageId → aggregated block status ('running'|'done'|'error')
    @Default({}) Map<String, String> blockStatusByMessageId,

    /// Id of the assistant message a `continueMessage()` run is extending.
    /// Mirrors `ChatState.continuationTargetId`; drives the `Continuing…`
    /// footer on that bubble (INV-CM6).
    String? continuationTargetId,
  }) = _ChatMessageMapperContext;
}

class ChatMessageMapper {
  static Map<String, dynamic> toMap(
    ChatMessage m,
    ChatMessageMapperContext ctx, {
    bool isLast = false,
    int? messageIndex,
    bool isStreamingUpdate = false,
    List<PresetRegex>? displayRegexes,
    Character? character,
    Persona? persona,
  }) {
    final isAssistant = m.role == 'assistant' || m.role == 'character';
    final isUser = m.role == 'user';

    String content = m.content;
    // Expand macros for display (mirrors reference Glaze ChatMessage.vue,
    // where replaceMacros runs on the rendered text before regexes). Without
    // this, macros typed manually into a sent/edited message stay literal in
    // the chat even though they resolve in the prompt sent to the LLM.
    if (character != null) {
      content = replaceMacros(
        content,
        MacroContext(
          charName: character.name,
          charDescription: character.description,
          charScenario: character.scenario,
          charPersonality: character.personality,
          charMesExample: character.mesExample,
          userName: persona?.name ?? 'User',
          personaPrompt: persona?.prompt,
          charId: character.id,
          sessionId: '',
          macroName: character.macroName,
        ),
      ).text;
    }
    final List<TriggeredEntry> triggeredRegexes = [];
    if (displayRegexes != null && displayRegexes.isNotEmpty) {
      final placement = isUser ? 1 : 2;
      final regexCtx = RegexApplyContext(char: character, persona: persona);
      content = applyRegexes(
        content,
        placement,
        1,
        displayRegexes,
        regexCtx,
        isMarkdown: true,
        triggered: triggeredRegexes,
      );
    }

    final messagePersonaName = m.personaName?.trim();
    final userMessagePersonaName = messagePersonaName == 'You'
        ? null
        : m.personaName;

    String? displayName;
    String? avatarColor;
    if (isAssistant) {
      displayName = ctx.currentCharName ?? m.personaName ?? 'Character';
      avatarColor = ctx.currentCharColor;
    } else if (isUser) {
      displayName = userMessagePersonaName ?? ctx.currentPersonaName ?? 'You';
    } else {
      displayName = m.personaName ?? 'System';
    }

    String? memoryStatus;
    if (m.memoryCoverage.isNotEmpty) {
      final needsRebuild = m.memoryCoverage['needsRebuild'] as bool? ?? false;
      final stale = m.memoryCoverage['stale'] as bool? ?? false;
      if (needsRebuild) {
        memoryStatus = 'REBUILD';
      } else if (stale) {
        memoryStatus = 'STALE';
      }
    }
    if (memoryStatus == null && ctx.coveredMemoryIds.contains(m.id)) {
      memoryStatus = 'MEM';
    }
    if (memoryStatus == null && ctx.pendingMemoryIds.contains(m.id)) {
      memoryStatus = 'PENDING';
    }
    if (memoryStatus == null && ctx.draftMemoryIds.contains(m.id)) {
      memoryStatus = 'DRAFT';
    }

    // What the editor must show. `text` below carries the *display* form —
    // macros expanded, display regexes applied — and the WebView keeps it in
    // `dataset.rawText`. Feeding that into the edit textarea would let a
    // display-only rewrite be saved back over the message: a `markdownOnly`
    // regex that turns `{TRK|…}` into a styled HTML card would replace the
    // marker in storage, and the next render would have nothing left to match.
    // The stored content rides along whenever it differs so `startEdit` can
    // open the source instead of the rendering.
    final displayText = stripThinkTags(content);
    final sourceText = stripThinkTags(m.content);

    return {
      'id': m.id,
      'role': m.role,
      'text': displayText,
      if (sourceText != displayText) 'sourceText': sourceText,
      'timestamp': m.timestamp,
      'isUser': isUser,
      'isAssistant': isAssistant,
      'isSystem': m.role == 'system',
      'displayName': displayName,
      'avatarColor': ?avatarColor,
      if (m.imagePath != null) 'imagePath': m.imagePath,
      if (m.imagePath != null) 'imageHidden': m.imageHidden,
      if (m.personaName != null && (!isUser || userMessagePersonaName != null))
        'personaName': m.personaName,
      if (m.swipes.isNotEmpty) 'swipeIndex': m.swipeId,
      if (m.swipes.isNotEmpty) 'swipeTotal': m.swipes.length,
      // Nested swipes (blue sub-swipes): agentSwipes[].
      if (m.agentSwipes.isNotEmpty) 'agentSwipeIndex': m.agentSwipeId,
      if (m.agentSwipes.isNotEmpty) 'agentSwipeTotal': m.agentSwipes.length,
      if (m.agentSwipes.length > 1)
        'agentSwipeKinds': m.agentSwipes.map((s) => s.kind).toList(),
      // Show the blue switcher when there are ≥2 agent swipes (any kind).
      // This includes final+cleaned (POST-cleaner) and 2+ finals (regen).
      if (m.agentSwipes.length > 1)
        'agentSwipeFinalCount': m.agentSwipes.length,
      if (m.genTime != null) 'genTime': m.genTime,
      if (m.time != null && m.time!.isNotEmpty) 'gameTime': m.time,
      if (m.tokens != null) 'tokens': m.tokens,
      'isError': m.isError,
      if (m.isTyping) 'isTyping': true,
      if (m.reasoning != null && m.reasoning!.isNotEmpty)
        'reasoning': m.reasoning,
      if (m.studioOutputs.isNotEmpty) 'studioOutputs': m.studioOutputs,
      if (m.memoryCoverage['studioOutputsExpanded'] == true)
        'studioOutputsExpanded': true,
      'isHidden': m.isHidden,
      if (isLast) 'isLast': true,
      'messageIndex': ?messageIndex,
      if (m.guidanceText != null && m.guidanceText!.isNotEmpty)
        'guidanceText': m.guidanceText,
      if (m.guidanceType != 'GENERATION') 'guidanceType': m.guidanceType,
      if (m.greetingIndex != null) 'greetingIndex': m.greetingIndex,
      if (m.greetingIndex != null && ctx.greetingTotal > 1)
        'greetingTotal': ctx.greetingTotal,
      'memoryStatus': ?memoryStatus,
      'blockStatus': ?ctx.blockStatusByMessageId[m.id],
      if (m.triggeredLorebooks.isNotEmpty)
        'triggeredLorebooks': _triggeredToJson(m.triggeredLorebooks),
      if (m.triggeredMemories.isNotEmpty)
        'triggeredMemories': _triggeredToJson(m.triggeredMemories),
      if (triggeredRegexes.isNotEmpty)
        'triggeredRegexes': _triggeredToJson(triggeredRegexes),
      'isGenerating': ctx.isGenerating,
      'isPostGenRunning': ctx.isPostGenRunning,
      if (ctx.continuationTargetId != null && ctx.continuationTargetId == m.id)
        'isContinuing': true,
    };
  }

  static List<Map<String, String>> _triggeredToJson(
    List<TriggeredEntry> entries,
  ) {
    return entries
        .map(
          (e) => {
            'id': e.id,
            'name': e.name,
            'lorebookName': e.lorebookName,
            'lorebookId': e.lorebookId,
            'source': e.source,
            'pattern': e.pattern,
          },
        )
        .toList();
  }
}
