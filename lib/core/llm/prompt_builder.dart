import 'package:flutter/foundation.dart';

import '../models/character.dart';
import '../models/persona.dart';
import '../models/preset.dart';
import '../models/chat_message.dart';
import '../models/lorebook.dart';
import 'macro_engine.dart';
import 'history_assembler.dart';
import 'context_calculator.dart';
import 'lorebook_coverage.dart';
import 'lorebook_scanner.dart';
import 'lorebook_merger.dart';
import 'prompt_block_resolver.dart';
import 'prompt_regex_applicator.dart';
import 'fallback_prompt_builder.dart';
import 'tokenizer.dart';
import 'memory_excerpt_selector.dart';
import 'prompt/lorebook_classifier.dart';
import 'prompt/memory_block_injector.dart';
import 'prompt/prompt_payload.dart';
import 'prompt/prompt_result.dart';
import 'prompt/recalled_message_chunk.dart';
import 'prompt/resolved_block.dart';

export 'prompt/prompt_payload.dart';
export 'prompt/prompt_result.dart';
export 'prompt/runtime_prompt_block.dart';
export 'prompt/recalled_message_chunk.dart';
export 'prompt/resolved_block.dart';
export 'prompt/lorebook_classifier.dart';
export 'prompt/memory_block_injector.dart';

const _stToInternalBlockId = <String, String>{
  'personaDescription': 'user_persona',
  'charDescription': 'char_card',
  'charPersonality': 'char_personality',
  'dialogueExamples': 'example_dialogue',
  'chatHistory': 'chat_history',
};

String normalizeBlockId(String blockId) {
  return _stToInternalBlockId[blockId] ?? blockId;
}

PromptResult buildPrompt(PromptPayload payload) {
  if (payload.preset == null) return buildFallbackPrompt(payload);

  final preset = payload.preset!;
  final char = payload.character;
  final persona = payload.persona;

  const defaultTagStart = '<think>';
  const defaultTagEnd = '</think>';
  // Vue-поведение: если preset пустой (null/""), берём теги из API settings (или дефолт).
  final effectiveReasoningTagStart = (preset.reasoningStart?.isNotEmpty == true)
      ? preset.reasoningStart!
      : (payload.apiConfig.reasoningTagStart?.isNotEmpty == true)
      ? payload.apiConfig.reasoningTagStart!
      : defaultTagStart;
  final effectiveReasoningTagEnd = (preset.reasoningEnd?.isNotEmpty == true)
      ? preset.reasoningEnd!
      : (payload.apiConfig.reasoningTagEnd?.isNotEmpty == true)
      ? payload.apiConfig.reasoningTagEnd!
      : defaultTagEnd;

  final macroCtx = MacroContext(
    charName: char.name,
    charDescription: char.description,
    charScenario: char.scenario,
    charPersonality: char.personality,
    charMesExample: char.mesExample,
    userName: persona?.name ?? 'User',
    personaPrompt: persona?.prompt,
    reasoningStart: effectiveReasoningTagStart,
    reasoningEnd: effectiveReasoningTagEnd,
    sessionVars: payload.sessionVars,
    globalVars: payload.globalVars,
    charId: char.id,
    sessionId: '',
    summaryContent: payload.summaryContent,
    guidanceText: payload.guidanceText,
    macroName: char.macroName,
    memoryContent: payload.memoryMacroContent,
    arcContent: payload.arcContent,
    entitiesContent: payload.entitiesContent,
    studioSessionState: payload.studioSessionStateContent,
  );

  var currentSessionVars = Map<String, String>.from(payload.sessionVars);
  var currentGlobalVars = Map<String, String>.from(payload.globalVars);
  var currentMacroCtx = macroCtx;
  final notifyObj = NotifyObj();

  final depthBlocks = <ResolvedDepthBlock>[];
  final relativeBlocks = <ResolvedRelativeBlock>[];

  final visibleHistory = payload.history
      .where((m) => !m.isHidden && !m.isTyping)
      .toList();
  final deferMemoryMacro = payload.memorySelection != null;

  final loreEntries =
      payload.preScannedEntries ??
      scanLorebooks(
        history: visibleHistory,
        char: char,
        textToScan:
            visibleHistory.where((m) => m.role == 'user').lastOrNull?.content ??
            '',
        chatId: payload.sessionId,
        lorebooks: payload.lorebooks,
        globalSettings: payload.lorebookSettings,
        activations: payload.lorebookActivations,
        applyPerBookLimits: false,
      );

  final vectorEntries = payload.vectorEntries.map((entry) {
    if (entry.lorebookId.isNotEmpty) return entry;
    final matches = payload.lorebooks.where(
      (book) => book.entries.any(
        (candidate) =>
            candidate.id == entry.id && candidate.content == entry.content,
      ),
    );
    final book = matches.length == 1 ? matches.single : null;
    return book == null
        ? entry
        : entry.copyWith(lorebookId: book.id, lorebookName: book.name);
  }).toList();

  final mergedEntries = mergeKeywordVector(
    keywordEntries: loreEntries,
    vectorEntries: vectorEntries,
    settings: payload.lorebookSettings,
  );

  final keywordIdToEntry = <String, ScannedEntry>{};
  for (final e in loreEntries) {
    keywordIdToEntry['${e.lorebookId}_${e.id}'] = e;
  }
  final coverageKeywordIdToEntry = <String, CoverageEntry>{};
  if (payload.lorebookSettings.searchType != 'vector') {
    final coverage = computeLorebookCoverage(
      history: visibleHistory,
      char: char,
      textToScan:
          visibleHistory.where((m) => m.role == 'user').lastOrNull?.content ??
          '',
      chatId: payload.sessionId,
      lorebooks: payload.lorebooks,
      globalSettings: payload.lorebookSettings,
      activations: payload.lorebookActivations,
    );
    for (final e in coverage.entries) {
      final isKeywordLike =
          e.constant ||
          (e.activated &&
              e.matchedKeys.isNotEmpty &&
              !e.matchedKeys.contains('[vector]'));
      if (isKeywordLike) {
        coverageKeywordIdToEntry['${e.lorebookId}_${e.id}'] = e;
      }
    }
  }
  final vectorIdToEntry = <String, LorebookEntry>{};
  for (final e in vectorEntries) {
    vectorIdToEntry['${e.lorebookId}_${e.id}'] = e;
  }

  final vectorLoreContent = mergedEntries
      .where((entry) {
        final key = '${entry.lorebookId}_${entry.id}';
        return vectorIdToEntry.containsKey(key) &&
            !keywordIdToEntry.containsKey(key);
      })
      .map((entry) => entry.content)
      .join('\n\n');
  final vectorLoreTokens = vectorLoreContent.isEmpty
      ? 0
      : estimateTokens(vectorLoreContent);

  final triggeredLorebooks = <TriggeredEntry>[];
  for (final merged in mergedEntries) {
    final mergedKey = '${merged.lorebookId}_${merged.id}';
    final kw = keywordIdToEntry[mergedKey];
    if (kw != null) {
      triggeredLorebooks.add(
        TriggeredEntry(
          id: kw.id,
          name: kw.comment.isNotEmpty ? kw.comment : kw.id,
          lorebookName: kw.lorebookName,
          lorebookId: kw.lorebookId,
          source: kw.constant ? 'constant' : 'keyword',
        ),
      );
      continue;
    }
    final coverageKw = coverageKeywordIdToEntry[mergedKey];
    if (coverageKw != null) {
      triggeredLorebooks.add(
        TriggeredEntry(
          id: coverageKw.id,
          name: coverageKw.comment.isNotEmpty
              ? coverageKw.comment
              : coverageKw.id,
          lorebookName: coverageKw.lorebookName,
          lorebookId: coverageKw.lorebookId,
          source: coverageKw.constant ? 'constant' : 'keyword',
        ),
      );
      continue;
    }
    final vec = vectorIdToEntry[mergedKey];
    if (vec != null) {
      triggeredLorebooks.add(
        TriggeredEntry(
          id: vec.id,
          name: vec.comment.isNotEmpty ? vec.comment : vec.id,
          lorebookName: vec.lorebookName,
          lorebookId: vec.lorebookId,
          source: 'vector',
        ),
      );
    }
  }

  final classified = classifyLorebooks(
    mergedEntries,
    currentMacroCtx,
    payload.lorebookSettings,
  );
  final loreBefore = classified.loreBefore;
  final loreAfter = classified.loreAfter;
  final macroLoreContent = classified.loreMacroBuffer.join('\n\n');

  // Apply char-field injections: prepend constant lore entries to the corresponding
  // MacroContext field so that {{scenario}}, {{personality}}, {{description}} macros
  // expand with the prepended content everywhere in the preset.
  String? patchedScenario = currentMacroCtx.charScenario;
  String? patchedPersonality = currentMacroCtx.charPersonality;
  String? patchedDescription = currentMacroCtx.charDescription;

  if (classified.loreScenario.isNotEmpty) {
    final prefix = classified.loreScenario.join('\n\n');
    patchedScenario = patchedScenario != null && patchedScenario.isNotEmpty
        ? '$prefix\n\n$patchedScenario'
        : prefix;
  }
  if (classified.lorePersonality.isNotEmpty) {
    final prefix = classified.lorePersonality.join('\n\n');
    patchedPersonality =
        patchedPersonality != null && patchedPersonality.isNotEmpty
        ? '$prefix\n\n$patchedPersonality'
        : prefix;
  }
  if (classified.loreDescription.isNotEmpty) {
    final prefix = classified.loreDescription.join('\n\n');
    patchedDescription =
        patchedDescription != null && patchedDescription.isNotEmpty
        ? '$prefix\n\n$patchedDescription'
        : prefix;
  }

  // Populate lorebooksContent in MacroContext so macro_engine can expand {{lorebooks}}
  // inline at the exact position of the placeholder inside any preset block.
  currentMacroCtx = currentMacroCtx.copyWith(
    lorebooksContent: macroLoreContent,
    memoryContent: deferMemoryMacro ? deferredMemoryPlaceholder : null,
    charScenario: patchedScenario,
    charPersonality: patchedPersonality,
    charDescription: patchedDescription,
  );

  for (final rawBlock in preset.blocks) {
    final id = normalizeBlockId(rawBlock.id);
    if (!rawBlock.enabled || rawBlock.isStashed) continue;

    final resolved = resolveBlockContent(
      id: id,
      rawContent: rawBlock.content,
      role: rawBlock.role,
      char: char,
      persona: persona,
      macroCtx: currentMacroCtx,
      sessionVars: currentSessionVars,
      globalVars: currentGlobalVars,
      notifyObj: notifyObj,
      summaryContent: payload.summaryContent,
      // Prefix is a per-preset setting on the summary block (falls back to the
      // runtime payload value, then the resolver default).
      summaryPrefix: rawBlock.prefix ?? payload.summaryPrefix,
      authorsNote: payload.authorsNote,
    );

    if (notifyObj.varsChanged) {
      currentSessionVars = Map<String, String>.from(notifyObj.sessionVars);
      currentGlobalVars = Map<String, String>.from(notifyObj.globalVars);
      currentMacroCtx = currentMacroCtx.copyWith(
        sessionVars: currentSessionVars,
        globalVars: currentGlobalVars,
      );
      notifyObj.varsChanged = false;
    }

    if (resolved == null) continue;

    final blockIsSummary =
        id == 'summary' || rawBlock.content.contains('{{summary}}');

    // Author's Note is positioned like any other block: its depth / insertion
    // mode come from the preset block (per-preset), while content and role are
    // injected from the chat session by resolveBlockContent. So it falls
    // through to the generic depth/relative handling below.
    if (rawBlock.insertionMode == 'depth' && id != 'chat_history') {
      depthBlocks.add(
        ResolvedDepthBlock(
          id: id,
          role: resolved.role,
          content: resolved.content,
          depth: rawBlock.depth ?? 0,
          isSummary: blockIsSummary,
        ),
      );
    } else {
      relativeBlocks.add(
        ResolvedRelativeBlock(
          id: id,
          name: rawBlock.name,
          role: resolved.role,
          content: resolved.content,
          contentForAccounting: resolved.contentForAccounting,
          isSummary: blockIsSummary,
          appendToLastMessage: rawBlock.appendToLastMessage,
        ),
      );
    }
  }

  if (payload.characterDepthPrompt.isNotEmpty) {
    final dpContent = replaceMacros(
      payload.characterDepthPrompt,
      currentMacroCtx,
    ).text;
    if (dpContent.trim().isNotEmpty) {
      depthBlocks.add(
        ResolvedDepthBlock(
          id: 'char_depth_prompt',
          role: payload.characterDepthPromptRole.isNotEmpty
              ? payload.characterDepthPromptRole
              : 'system',
          content: dpContent,
          depth: payload.characterDepthPromptDepth,
        ),
      );
    }
  }

  for (final block in payload.runtimePromptBlocks) {
    final content = replaceMacros(block.content, currentMacroCtx).text.trim();
    if (content.isEmpty) continue;
    depthBlocks.add(
      ResolvedDepthBlock(
        id: 'runtime_prompt:${block.id}',
        role: block.role.isNotEmpty ? block.role : 'system',
        content: content,
        depth: block.depth,
      ),
    );
  }

  final macroTokens = <String, int>{};
  if (currentMacroCtx.lorebooksContent != null &&
      currentMacroCtx.lorebooksContent!.isNotEmpty) {
    macroTokens['lorebooks'] = estimateTokens(
      currentMacroCtx.lorebooksContent!,
    );
  }
  if (currentMacroCtx.summaryContent != null &&
      currentMacroCtx.summaryContent!.isNotEmpty) {
    macroTokens['summary'] = estimateTokens(currentMacroCtx.summaryContent!);
  }
  if (currentMacroCtx.memoryContent != null &&
      currentMacroCtx.memoryContent!.isNotEmpty) {
    macroTokens['memory'] =
        currentMacroCtx.memoryContent == deferredMemoryPlaceholder
        ? 0
        : estimateTokens(currentMacroCtx.memoryContent!);
  }
  if (currentMacroCtx.charDescription != null &&
      currentMacroCtx.charDescription!.isNotEmpty) {
    macroTokens['description'] = estimateTokens(
      currentMacroCtx.charDescription!,
    );
  }
  if (currentMacroCtx.charPersonality != null &&
      currentMacroCtx.charPersonality!.isNotEmpty) {
    macroTokens['personality'] = estimateTokens(
      currentMacroCtx.charPersonality!,
    );
  }
  if (currentMacroCtx.charScenario != null &&
      currentMacroCtx.charScenario!.isNotEmpty) {
    macroTokens['scenario'] = estimateTokens(currentMacroCtx.charScenario!);
  }
  if (currentMacroCtx.personaPrompt != null &&
      currentMacroCtx.personaPrompt!.isNotEmpty) {
    macroTokens['persona'] = estimateTokens(currentMacroCtx.personaPrompt!);
  }
  if (currentMacroCtx.charMesExample != null &&
      currentMacroCtx.charMesExample!.isNotEmpty) {
    macroTokens['mesExamples'] = estimateTokens(
      currentMacroCtx.charMesExample!,
    );
  }

  return _assembleMessages(
    relativeBlocks: relativeBlocks,
    depthBlocks: depthBlocks,
    loreBefore: loreBefore,
    loreAfter: loreAfter,
    history: payload.history,
    macroCtx: currentMacroCtx,
    currentSessionVars: currentSessionVars,
    currentGlobalVars: currentGlobalVars,
    preset: preset,
    payload: payload,
    char: char,
    persona: persona,
    triggeredLorebooks: triggeredLorebooks,
    triggeredMemories: payload.triggeredMemories,
    macroTokens: macroTokens,
    vectorLoreTokens: vectorLoreTokens,
  );
}

PromptResult _assembleMessages({
  required List<ResolvedRelativeBlock> relativeBlocks,
  required List<ResolvedDepthBlock> depthBlocks,
  required List<PromptMessage> loreBefore,
  required List<PromptMessage> loreAfter,
  required List<ChatMessage> history,
  required MacroContext macroCtx,
  required Map<String, String> currentSessionVars,
  required Map<String, String> currentGlobalVars,
  required Preset preset,
  required PromptPayload payload,
  required Character char,
  Persona? persona,
  List<TriggeredEntry> triggeredLorebooks = const [],
  List<TriggeredEntry> triggeredMemories = const [],
  Map<String, int> macroTokens = const {},
  int vectorLoreTokens = 0,
}) {
  final messages = <PromptMessage>[];
  final attributionBlocks = <StaticBlock>[];
  String? mergeBuffer;
  String? mergeRole;

  final resolvedDepthMsgs = depthBlocks
      .map(
        (b) => PromptMessage(
          role: b.role,
          content: b.content,
          blockId: b.id,
          depth: b.depth,
          isDepth: true,
          isSummary: b.isSummary,
        ),
      )
      .toList();

  // Track whether loreBefore/loreAfter were injected via char_card trigger.
  // If the preset has no char_card block, they fall through to the end.
  bool loreBeforeInjected = false;
  bool loreAfterInjected = false;

  void injectLoreBefore() {
    if (loreBeforeInjected || loreBefore.isEmpty) return;
    final combined = loreBefore.map((e) => e.content).join('\n\n');
    messages.add(
      PromptMessage(
        role: 'system',
        content: combined,
        isLorebook: true,
        blockId: 'worldInfoBefore',
        blockName: 'Lorebook (Before)',
      ),
    );
    attributionBlocks.add(
      StaticBlock(id: 'worldInfoBefore', content: combined),
    );
    loreBeforeInjected = true;
  }

  void injectLoreAfter() {
    if (loreAfterInjected || loreAfter.isEmpty) return;
    final combined = loreAfter.map((e) => e.content).join('\n\n');
    messages.add(
      PromptMessage(
        role: 'system',
        content: combined,
        isLorebook: true,
        blockId: 'worldInfoAfter',
        blockName: 'Lorebook (After)',
      ),
    );
    attributionBlocks.add(StaticBlock(id: 'worldInfoAfter', content: combined));
    loreAfterInjected = true;
  }

  // Collect blocks with appendToLastMessage set. Macros are already expanded
  // in block.content at this point (resolveBlockContent ran in buildPrompt
  // before relativeBlocks was built). See docs/INVARIANTS.md INV-PSx.
  final appendedEntries = <ResolvedRelativeBlock>[];
  for (final block in relativeBlocks) {
    if (block.id == 'chat_history') continue;
    if (!block.appendToLastMessage) continue;
    if (block.content.trim().isEmpty) continue;
    appendedEntries.add(block);
  }

  for (final block in relativeBlocks) {
    // worldInfoBefore injects just before char_card (mirrors JS generationWorker.js:739)
    if (block.id == 'char_card') injectLoreBefore();

    if (block.id == 'chat_history') {
      if (mergeBuffer != null) {
        messages.add(
          PromptMessage(
            role: mergeRole ?? 'system',
            blockId: 'preset',
            content: mergeBuffer,
          ),
        );
        mergeBuffer = null;
      }
      // worldInfoAfter injects just before chat_history (mirrors JS generationWorker.js:680)
      injectLoreAfter();

      final historyMacroCtx = MacroContext(
        charName: macroCtx.charName,
        charDescription: macroCtx.charDescription,
        charScenario: macroCtx.charScenario,
        charPersonality: macroCtx.charPersonality,
        charMesExample: macroCtx.charMesExample,
        userName: macroCtx.userName,
        personaPrompt: macroCtx.personaPrompt,
        reasoningStart: macroCtx.reasoningStart,
        reasoningEnd: macroCtx.reasoningEnd,
        sessionVars: currentSessionVars,
        globalVars: currentGlobalVars,
        charId: macroCtx.charId,
        sessionId: macroCtx.sessionId,
        macroName: macroCtx.macroName,
      );
      final historyMsgs = HistoryAssembler(historyMacroCtx).assemble(history);
      final appendedForHistory = appendedEntries
          .map((b) => (name: b.name, content: b.content))
          .toList();
      applyAppendToLastMessage(historyMsgs, appendedForHistory);
      messages.addAll(
        interleaveDepthWithHistory(historyMsgs, resolvedDepthMsgs),
      );
      for (final db in resolvedDepthMsgs) {
        attributionBlocks.add(
          StaticBlock(id: db.blockId ?? 'preset', content: db.content),
        );
      }
    } else {
      final content = block.content.trim();
      final accountingContent = block.contentForAccounting.trim();

      // setvar-only blocks: no LLM-visible text, but definitions count toward preset.
      if (content.isEmpty) {
        if (accountingContent.isNotEmpty) {
          attributionBlocks.add(
            StaticBlock(id: block.id, content: accountingContent),
          );
        }
        if (block.id == 'char_card') injectLoreAfter();
        continue;
      }

      // attributionBlocks feed the token breakdown. We pass the
      // "accounting" content (dynamic macros blanked out) so that the
      // preset's static chrome is attributed to sourceTokens['preset']
      // and NOT double-counted under sourceTokens['memory'] /
      // sourceTokens['summary'] / sourceTokens['lorebooks']. The
      // dynamic injections are counted separately via dedicated
      // StaticBlocks (hard-block injection) and macroTokens.
      attributionBlocks.add(
        StaticBlock(id: block.id, content: accountingContent),
      );

      // appendToLastMessage blocks are merged into the last user message in
      // applyAppendToLastMessage (see appendedEntries above). They must NOT
      // also be added to messages here — that would send the same content
      // twice. See docs/INVARIANTS.md INV-PS9.
      if (block.appendToLastMessage) continue;

      if (preset.mergePrompts && block.role != 'assistant') {
        if (mergeBuffer != null) {
          mergeBuffer = '$mergeBuffer\n\n$content';
        } else {
          mergeBuffer = content;
          mergeRole = preset.mergeRole;
        }
      } else {
        if (mergeBuffer != null) {
          messages.add(
            PromptMessage(
              role: mergeRole ?? 'system',
              blockId: 'preset',
              content: mergeBuffer,
            ),
          );
          mergeBuffer = null;
        }
        messages.add(
          PromptMessage(
            role: block.role,
            blockId: block.id,
            blockName: block.name,
            content: content,
            isSummary: block.isSummary,
          ),
        );
      }

      // worldInfoAfter injects just after char_card (mirrors JS generationWorker.js:792)
      if (block.id == 'char_card') injectLoreAfter();
    }
  }

  // Fallback: if preset had no char_card block, inject remaining lore at the end
  injectLoreBefore();
  injectLoreAfter();
  if (mergeBuffer != null) {
    messages.add(
      PromptMessage(
        role: mergeRole ?? 'system',
        blockId: 'preset',
        content: mergeBuffer,
      ),
    );
  }

  // Memory block injection.
  // - payload.memoryContent set, payload.memorySelection == null:
  //     legacy path — inject hard block before cutoff. Source-window
  //     exclusion has already been applied (or wasn't requested) by
  //     whichever upstream producer assembled the content.
  // - payload.memorySelection set:
  //     defer injection until after the cutoff is known, then refilter
  //     against the visible window. The block is injected as a deferred
  //     marker so attributionBlocks and the message list stay consistent.
  final hasDeferredMemorySelection = payload.memorySelection != null;

  if (!hasDeferredMemorySelection &&
      payload.memoryContent != null &&
      payload.memoryContent!.isNotEmpty) {
    if (payload.memoryInjectionTarget == 'hard_block') {
      // Skip the hard block if the preset already handles memory via
      // {{memory}} macro or via an explicit `id: 'memory'` block.
      // (See docs/INVARIANTS.md INV-PS5.)
      final hasMemoryBlock =
          messages.any((m) => m.blockId == 'memory') ||
          appendedEntries.any((b) => b.id == 'memory');
      if (!hasMemoryBlock) {
        injectMemoryBlock(messages, attributionBlocks, payload.memoryContent!);
      }
    }
    // 'macro' target: skip hard block, user must place {{memory}} in preset
  }

  if (payload.characterKnowledgeContent != null &&
      payload.characterKnowledgeContent!.isNotEmpty) {
    injectCharacterKnowledgeBlock(
      messages,
      attributionBlocks,
      payload.characterKnowledgeContent!,
    );
  }

  // Studio Session State: inject <studio_session_state> canon block so
  // the LLM sees committed entity/relationship/arc/world state overriding
  // character-card baseline. Placed before recalled_messages so it has
  // higher authority in the context window.
  // Rationale: canon state is injected as hidden/system prompt only, never as
  // a chat message. It overrides character-card baseline when conflicting.
  // Skip the hard block if the preset already handles studio state via the
  // {{studio_state}} macro — the expanded content carries the
  // <studio_session_state> marker. (Mirrors the {{memory}} dedup at INV-PS5.)
  if (payload.studioSessionStateContent != null &&
      payload.studioSessionStateContent!.isNotEmpty) {
    final hasStudioStateBlock = messages.any(
      (m) => m.content.contains('<studio_session_state>'),
    );
    if (!hasStudioStateBlock) {
      injectStudioSessionStateBlock(
        messages,
        attributionBlocks,
        payload.studioSessionStateContent!,
      );
    }
  }

  final lorebookReserve = calculateLorebookReserve(payload);

  final calculator = ContextCalculator(
    contextSize: payload.apiConfig.contextSize,
    maxTokens: payload.apiConfig.maxTokens,
    reasoningHistoryCount: payload.apiConfig.reasoningHistoryCount,
  );
  var historyOnly = messages.where((m) => m.isHistory).toList();

  // Pre-account for memory tokens so the initial history cutoff matches
  // the post-memory-injection cutoff. Without this, the first calculate()
  // uses memoryTokens=0, producing a wider visible window than the final
  // breakdown — messages in that "phantom zone" get excluded from memory
  // (sourceWindowExclusion) yet also dropped from history, so the model
  // sees neither. We use the selection's totalTokens (actual sum of picked
  // entries) as the estimate; excerpting may reduce this further, but the
  // visible window stays conservative (fewer excluded messages is always
  // safe — the model still sees them in history).
  final estimatedMemoryTokens = payload.memorySelection?.totalTokens ?? 0;

  var breakdown = calculator.calculate(
    staticBlocks: attributionBlocks,
    historyMessages: historyOnly,
    lorebookReserveTokens: lorebookReserve,
    macroTokens: macroTokens,
    vectorLoreTokens: vectorLoreTokens,
    memoryTokens: estimatedMemoryTokens,
  );

  // Inject <recalled_messages> after the first cutoff calculation so raw
  // message recall can exclude chunks whose source messages are already
  // visible in the active history window. Studio supplies an explicit source
  // window; non-Studio uses the calculated token cutoff window.
  final recallVisibleMessageIds =
      payload.sourceWindowVisibleMessageIds.isNotEmpty
      ? payload.sourceWindowVisibleMessageIds
      : breakdown.visibleMessageIds;
  final recalledMessagesContent = effectiveRecalledMessagesContent(
    payload,
    visibleMessageIds: recallVisibleMessageIds,
  );
  if (recalledMessagesContent != null && recalledMessagesContent.isNotEmpty) {
    injectRecalledMessagesBlock(
      messages,
      attributionBlocks,
      recalledMessagesContent,
    );
    historyOnly = messages.where((m) => m.isHistory).toList();
    breakdown = calculator.calculate(
      staticBlocks: attributionBlocks,
      historyMessages: historyOnly,
      lorebookReserveTokens: lorebookReserve,
      macroTokens: macroTokens,
      vectorLoreTokens: vectorLoreTokens,
      memoryTokens: estimatedMemoryTokens,
    );
  }
  var finalMemorySelection = payload.memorySelection;
  MemoryExcerptSelection? finalExcerptSelection;
  var memoryMacroMissing = false;

  // Deferred memory finalization: refilter the v2 selection against the
  // visible window now that the cutoff is known, then inject the hard
  // block and update the breakdown with the post-cutoff memory cost.
  if (hasDeferredMemorySelection && payload.memorySelection != null) {
    final result = finalizeDeferredMemory(
      payload: payload,
      baseBreakdown: breakdown,
      messages: messages,
      appendedEntries: appendedEntries,
      attributionBlocks: attributionBlocks,
      historyOnly: historyOnly,
      macroTokens: macroTokens,
      calculator: calculator,
      lorebookReserve: lorebookReserve,
      vectorLoreTokens: vectorLoreTokens,
    );
    breakdown = result.breakdown;
    finalMemorySelection = result.finalMemorySelection;
    finalExcerptSelection = result.finalExcerptSelection;
    memoryMacroMissing = result.memoryMacroMissing;
  }

  final finalMessages = <PromptMessage>[];
  orderContinuityContextBlocks(messages);
  var historySeen = 0;
  for (final msg in messages) {
    if (msg.isHistory) {
      if (historySeen >= breakdown.cutoffIndex) {
        // Use live history messages so deferred {{memory}} replacement on
        // appendToLastMessage blocks is not lost to a stale trimmed copy.
        finalMessages.add(msg);
      }
      historySeen++;
    } else if (msg.content.trim().isNotEmpty) {
      finalMessages.add(msg);
    }
  }

  final presetRegexes = preset.regexes.where((r) => !r.disabled).toList();
  final globalRegexes = payload.globalRegexes
      .where((r) => !r.disabled)
      .toList();
  final regexScripts = [...presetRegexes, ...globalRegexes];

  final finalMessagesWithRegex = regexScripts.isEmpty
      ? finalMessages
      : applyPromptRegexes(
          messages: finalMessages,
          char: char,
          persona: persona,
          sessionVars: currentSessionVars,
          globalVars: currentGlobalVars,
          regexScripts: regexScripts,
        );

  final finalMemoryCoverage = finalizeMemoryCoverage(
    payload.memoryCoverage,
    finalMemorySelection,
    finalExcerptSelection,
    memoryMacroMissing: memoryMacroMissing,
  );
  final finalTriggeredMemories = finalizeTriggeredMemories(
    payload.triggeredMemories,
    finalMemorySelection,
    finalExcerptSelection,
  );

  return PromptResult(
    messages: finalMessagesWithRegex,
    breakdown: breakdown,
    sessionVars: currentSessionVars,
    globalVars: currentGlobalVars,
    triggeredLorebooks: triggeredLorebooks,
    triggeredMemories: finalTriggeredMemories,
    memoryCoverage: finalMemoryCoverage,
  );
}

/// Filters [PromptPayload.recalledMessageChunks] by the source-window
/// visibility override, then formats the surviving chunks into a
/// `<recalled_messages>` block. Falls back to
/// [PromptPayload.recalledMessagesContent] when no structured chunks exist.
///
/// When [PromptPayload.sourceWindowVisibleMessageIds] is non-empty, chunks
/// whose *any* [RecalledMessageChunk.messageIds] overlaps with it are
/// excluded (their content is already visible in the prompt history).
/// When empty, the base token-cutoff window is assumed to have already
/// filtered, so all chunks pass through.
@visibleForTesting
String? effectiveRecalledMessagesContent(
  PromptPayload payload, {
  Set<String>? visibleMessageIds,
}) {
  if (payload.recalledMessageChunks.isEmpty) {
    return payload.recalledMessagesContent;
  }
  final visible = visibleMessageIds ?? payload.sourceWindowVisibleMessageIds;
  final chunks = payload.disableSourceWindowExclusion || visible.isEmpty
      ? payload.recalledMessageChunks
      : payload.recalledMessageChunks
            .where(
              (chunk) =>
                  chunk.messageIds.isEmpty ||
                  !chunk.messageIds.any(visible.contains),
            )
            .toList(growable: false);
  if (chunks.isEmpty) return null;

  final block = StringBuffer();
  block.writeln('<recalled_messages>');
  block.writeln(
    'Earlier accepted raw-message evidence. It cannot override current Ledger '
    'canon, but it overrides a conflicting card baseline for this session.',
  );
  block.writeln(
    'Semantically relevant raw message chunks from earlier in this chat. '
    'Do not explicitly reference "remembering" these — use them as ground '
    'truth context.',
  );
  for (final chunk in chunks) {
    final text = chunk.text.trim();
    if (text.isEmpty) continue;
    block.writeln('---');
    block.writeln(text);
  }
  block.writeln('</recalled_messages>');
  final content = block.toString().trim();
  return content == '<recalled_messages>\n</recalled_messages>'
      ? null
      : content;
}

/// Appends the contents of preset blocks with `appendToLastMessage = true` to
/// the last user-role history message. No-op when [historyMsgs] has no user
/// message or no appendable blocks. Macros in the block content must already
/// be expanded before this is called (handled in [buildPrompt]).
///
/// See docs/INVARIANTS.md INV-PS9 for the full contract.
@visibleForTesting
void applyAppendToLastMessage(
  List<PromptMessage> historyMsgs,
  List<({String name, String content})> appendedEntries,
) {
  if (appendedEntries.isEmpty || historyMsgs.isEmpty) return;

  final lastUserIdx = historyMsgs.lastIndexWhere(
    (m) => m.role == 'user' && m.isHistory,
  );
  if (lastUserIdx < 0) return;

  final original = historyMsgs[lastUserIdx];
  final joined = appendedEntries
      .map((b) => b.content.trim())
      .where((s) => s.isNotEmpty)
      .join('\n\n');
  if (joined.isEmpty) return;

  final blockNames = appendedEntries
      .map((b) => b.name.isNotEmpty ? b.name : 'block')
      .join(', ');

  historyMsgs[lastUserIdx] = PromptMessage(
    role: original.role,
    content: '${original.content}\n\n$joined',
    isHistory: true,
    blockName: '${original.blockName ?? 'Last user'} + $blockNames',
    sourceMessageId: original.sourceMessageId,
    reasoningContent: original.reasoningContent,
    imagePath: original.imagePath,
  );
}
