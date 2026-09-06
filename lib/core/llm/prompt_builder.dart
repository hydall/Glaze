import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../utils/cast_helpers.dart';

import '../models/character.dart';
import '../models/persona.dart';
import '../models/preset.dart';
import '../models/chat_message.dart';
import '../models/lorebook.dart';
import 'macro_engine.dart';
import 'game_time.dart';
import 'history_assembler.dart';
import 'context_calculator.dart';
import 'lorebook_scanner.dart';
import 'prompt_block_resolver.dart';
import 'prompt_regex_applicator.dart';
import 'regex_service.dart';
import 'fallback_prompt_builder.dart';
import 'tokenizer.dart';
import 'memory_excerpt_selector.dart';
import 'prompt/exact_lorebook_manifest.dart';
import 'prompt/lorebook_context_resolver.dart';
import 'prompt/lorebook_classifier.dart';
import 'prompt/memory_block_injector.dart';
import 'prompt/prompt_payload.dart';
import 'prompt/prompt_result.dart';
import 'prompt/recalled_message_chunk.dart';
import 'prompt/recalled_messages_resolver.dart';
import 'prompt/resolved_block.dart';
import '../models/ledger_prompt_injection_mode.dart';
import '../models/ledger_prompt_injection_policy.dart';
import 'prompt/effective_canon_prompt_materializer.dart';
import 'prompt/selective_ledger_projection_filter.dart';

export 'prompt/prompt_payload.dart';
export 'prompt/prompt_result.dart';
export 'prompt/runtime_prompt_block.dart';
export 'prompt/recalled_message_chunk.dart';
export 'prompt/recalled_messages_resolver.dart';
export 'prompt/resolved_block.dart';
export 'prompt/lorebook_classifier.dart';
export 'prompt/lorebook_context_resolver.dart';
export 'prompt/memory_context_resolver.dart';
export 'prompt/memory_block_injector.dart';
export 'prompt/exact_lorebook_manifest.dart';

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
  final projection = payload.effectiveCanonProjection;
  if (projection == null) return _buildPromptOnce(payload);

  final policy = payload.ledgerPromptInjectionPolicy;
  final mode = policy.effectiveMode;
  final baselineMaterialization =
      EffectiveCanonPromptMaterializer.materializeSafely(
        SelectiveLedgerProjectionInput(
          policy: LedgerPromptInjectionPolicy(
            presetOptIn: policy.presetOptIn,
            mode: mode == LedgerPromptInjectionMode.disabled
                ? LedgerPromptInjectionMode.disabled
                : LedgerPromptInjectionMode.legacy,
            algorithmVersion: policy.algorithmVersion,
            reverseScanDepth: policy.reverseScanDepth,
          ),
          consumerPath: payload.preset == null ? 'fallback' : 'ordinary',
          projection: projection,
          visibleMessages: const [],
          selectedSwipeByMessageId: const {},
          focalUserName: payload.persona?.name ?? '',
        ),
        sessionId: payload.sessionId ?? '',
        latestUserText: _latestLedgerText(payload.history, 'user'),
        latestAssistantText: _latestLedgerText(payload.history, 'assistant'),
      );
  final baselinePayload = payload.withLedgerMaterialization(
    baselineMaterialization,
  );

  // Disabled and shadow callers remain single pass. Both user-facing modes
  // take the same frozen visible window for relevance; only Gap Filler may
  // additionally suppress facts already covered by that history.
  if (mode == LedgerPromptInjectionMode.disabled ||
      mode == LedgerPromptInjectionMode.shadow) {
    return _buildPromptOnce(baselinePayload);
  }

  final baseline = _buildPromptOnce(baselinePayload);
  final visibleIds = baseline.breakdown.visibleMessageIds;
  final depth = policy.reverseScanDepth;
  final visible = payload.history
      .where(
        (message) =>
            visibleIds.contains(message.id) &&
            !message.isHidden &&
            !message.isTyping &&
            (message.role == 'user' || message.role == 'assistant'),
      )
      .toList(growable: false);
  final clamped = visible.length <= depth
      ? visible
      : visible.sublist(visible.length - depth);
  final selected = EffectiveCanonPromptMaterializer.materializeSafely(
    SelectiveLedgerProjectionInput(
      policy: policy,
      consumerPath: payload.preset == null ? 'fallback' : 'ordinary',
      projection: projection,
      visibleMessages: clamped,
      selectedSwipeByMessageId: {
        for (final message in clamped) message.id: message.swipeId,
      },
      focalUserName: payload.persona?.name ?? '',
      freshness: payload.ledgerProjectionFreshnessProvenCurrent
          ? LedgerProjectionFreshness.provenCurrent
          : LedgerProjectionFreshness.unknown,
    ),
    sessionId: payload.sessionId ?? '',
    latestUserText: _latestLedgerText(clamped, 'user'),
    latestAssistantText: _latestLedgerText(clamped, 'assistant'),
  );
  final rebuilt = _buildPromptOnce(payload.withLedgerMaterialization(selected));
  // Legacy uses relevance only, so it cannot suppress based on source
  // coverage. Gap Filler verifies that coverage evidence still survives the
  // second build before accepting its selected result.
  if (mode != LedgerPromptInjectionMode.gapFiller) return rebuilt;
  final suppressionEvidence = selected.diagnostics
      .where((item) => !item.selected)
      .expand((item) => item.matchingSourceIds)
      .toSet();
  if (!rebuilt.breakdown.visibleMessageIds.containsAll(suppressionEvidence)) {
    return baseline;
  }
  return rebuilt;
}

String _latestLedgerText(List<ChatMessage> history, String role) => history
    .lastWhere(
      (message) =>
          message.role == role && !message.isHidden && !message.isTyping,
      orElse: () => const ChatMessage(id: '', role: '', content: ''),
    )
    .content;

/// One-pass assembly primitive. Ledger fields must already be materialized.
PromptResult _buildPromptOnce(PromptPayload payload) {
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
    gameTime: payload.gameTime,
    gameDate: payload.gameDate,
    gameDay: payload.gameDay,
  );

  var currentSessionVars = Map<String, String>.from(payload.sessionVars);
  var currentGlobalVars = Map<String, String>.from(payload.globalVars);
  var currentMacroCtx = macroCtx;
  final notifyObj = NotifyObj();

  final depthBlocks = <ResolvedDepthBlock>[];
  final relativeBlocks = <ResolvedRelativeBlock>[];

  final deferMemoryMacro = payload.memorySelection != null;
  final loreContext = const LorebookContextResolver().resolve(
    history: payload.history,
    character: char,
    sessionId: payload.sessionId,
    lorebooks: payload.lorebooks,
    settings: payload.lorebookSettings,
    activations: payload.lorebookActivations,
    vectorEntries: payload.vectorEntries,
    macroContext: currentMacroCtx,
    preScannedEntries: payload.preScannedEntries,
  );
  final exactLorebookManifest = _buildExactLorebookManifest(
    entries: loreContext.mergedEntries,
    payload: payload,
    preset: preset,
    macroContext: currentMacroCtx,
    keywordEntries: loreContext.keywordEntries,
    vectorEntries: loreContext.vectorEntries,
  );
  // Capture attribution from the actual block assembly path.  This is an
  // assembly declaration, not an inference from matching prompt text.
  final blockLoreClassifications = <String, Set<String>>{};
  for (final block in preset.blocks) {
    if (!block.enabled || block.isStashed) continue;
    final content = block.content.toLowerCase();
    final classifications = <String>{
      if (content.contains('{{lorebooks}}')) 'lorebooksMacro',
      if (content.contains('{{scenario}}')) 'charScenario',
      if (content.contains('{{personality}}')) 'charPersonality',
      if (content.contains('{{description}}')) 'charDescription',
    };
    if (classifications.isNotEmpty) {
      blockLoreClassifications[normalizeBlockId(block.id)] = classifications;
    }
  }
  final loreBefore = loreContext.loreBefore;
  final loreAfter = loreContext.loreAfter;
  final macroLoreContent = loreContext.loreMacroBuffer.join('\n\n');

  // Apply char-field injections: prepend constant lore entries to the corresponding
  // MacroContext field so that {{scenario}}, {{personality}}, {{description}} macros
  // expand with the prepended content everywhere in the preset.
  String? patchedScenario = currentMacroCtx.charScenario;
  String? patchedPersonality = currentMacroCtx.charPersonality;
  String? patchedDescription = currentMacroCtx.charDescription;

  if (loreContext.loreScenario.isNotEmpty) {
    final prefix = loreContext.loreScenario.join('\n\n');
    patchedScenario = patchedScenario != null && patchedScenario.isNotEmpty
        ? '$prefix\n\n$patchedScenario'
        : prefix;
  }
  if (loreContext.lorePersonality.isNotEmpty) {
    final prefix = loreContext.lorePersonality.join('\n\n');
    patchedPersonality =
        patchedPersonality != null && patchedPersonality.isNotEmpty
        ? '$prefix\n\n$patchedPersonality'
        : prefix;
  }
  if (loreContext.loreDescription.isNotEmpty) {
    final prefix = loreContext.loreDescription.join('\n\n');
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
      sendEmptyBlock: rawBlock.sendEmptyBlock,
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
          sendEmptyBlock: rawBlock.sendEmptyBlock,
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
          sendEmptyBlock: rawBlock.sendEmptyBlock,
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
    triggeredLorebooks: loreContext.triggeredEntries,
    exactLorebookManifest: exactLorebookManifest,
    blockLoreClassifications: blockLoreClassifications,
    triggeredMemories: payload.triggeredMemories,
    macroTokens: macroTokens,
    vectorLoreTokens: loreContext.vectorLoreTokens,
  );
}

ExactLorebookManifest _buildExactLorebookManifest({
  required List<LorebookEntry> entries,
  required PromptPayload payload,
  required Preset preset,
  required MacroContext macroContext,
  required Map<String, ScannedEntry> keywordEntries,
  required Map<String, LorebookEntry> vectorEntries,
}) {
  final canon =
      payload.effectiveCanonRevisionNumber == null &&
          payload.effectiveCanonRevisionHash == null &&
          payload.effectiveCanonCacheIdentity.isEmpty
      ? null
      : ExactLorebookEffectiveCanonProvenance(
          revisionNumber: payload.effectiveCanonRevisionNumber ?? 0,
          revisionHash: payload.effectiveCanonRevisionHash ?? '',
          cacheIdentity: payload.effectiveCanonCacheIdentity,
        );
  return buildExactLorebookManifest(
    entries: entries,
    characterId: payload.character.id,
    personaId: payload.persona?.id ?? '',
    sessionId: payload.sessionId ?? '',
    presetSnapshotHash: computeHash(jsonEncode(preset.toJson())),
    macroContext: macroContext,
    sourceByEntryKey: {
      for (final entry in entries)
        '${entry.lorebookId}_${entry.id}':
            keywordEntries['${entry.lorebookId}_${entry.id}']?.constant == true
            ? 'constant'
            : keywordEntries.containsKey('${entry.lorebookId}_${entry.id}')
            ? 'keyword'
            : vectorEntries.containsKey('${entry.lorebookId}_${entry.id}')
            ? 'vector'
            : 'unknown',
    },
    classificationByEntryKey: {
      for (final entry in entries)
        '${entry.lorebookId}_${entry.id}': entry.position == 'matchGlobal'
            ? payload.lorebookSettings.injectionPosition
            : entry.position,
    },
    effectiveCanonProvenance: canon,
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
  ExactLorebookManifest? exactLorebookManifest,
  Map<String, Set<String>> blockLoreClassifications = const {},
  List<TriggeredEntry> triggeredMemories = const [],
  Map<String, int> macroTokens = const {},
  int vectorLoreTokens = 0,
}) {
  final messages = <PromptMessage>[];
  final assemblyReports = <ExactLorebookInjectionReport>[];
  final attributionBlocks = <StaticBlock>[];

  // Keep the attribution declaration alongside each resolved block until its
  // concrete emission site.  Do not recover it from rendered message text.
  final resolvedDepthBlocks = depthBlocks
      .map(
        (b) => (
          message: PromptMessage(
            role: b.role,
            content: b.content,
            blockId: b.id,
            depth: b.depth,
            isDepth: true,
            isSummary: b.isSummary,
            sendEmptyBlock: b.sendEmptyBlock,
          ),
          classifications: blockLoreClassifications[b.id] ?? const <String>{},
        ),
      )
      .toList();
  final resolvedDepthMsgs = resolvedDepthBlocks
      .map((block) => block.message)
      .toList();

  // Track whether loreBefore/loreAfter were injected via char_card trigger.
  // If the preset has no char_card block, they fall through to the end.
  bool loreBeforeInjected = false;
  bool loreAfterInjected = false;

  void recordAssembly(Iterable<String> classifications) {
    final manifest = exactLorebookManifest;
    if (manifest == null) return;
    final expected = classifications.toSet();
    for (final entry in manifest.entries) {
      if (!expected.contains(entry.classification) ||
          entry.renderedContent.trim().isEmpty) {
        continue;
      }
      assemblyReports.add(
        ExactLorebookInjectionReport(
          namespacedId: entry.namespacedId,
          placement: entry.injectionIndex,
          renderedContent: entry.renderedContent,
          classification: entry.classification,
        ),
      );
    }
  }

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
    recordAssembly(const {'worldInfoBefore'});
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
    recordAssembly(const {'worldInfoAfter'});
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
  final appendedClassifications = <String>{
    for (final block in appendedEntries) ...?blockLoreClassifications[block.id],
  };
  final appendedHistoryMessageIds = <String>{};

  for (final block in relativeBlocks) {
    // worldInfoBefore injects just before char_card (mirrors JS generationWorker.js:739)
    if (block.id == 'char_card') injectLoreBefore();

    if (block.id == 'chat_history') {
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
      if (appendedEntries.isNotEmpty) {
        final lastUser = historyMsgs.lastWhere(
          (message) => message.role == 'user' && message.isHistory,
          orElse: () => const PromptMessage(role: '', content: ''),
        );
        if (lastUser.sourceMessageId != null) {
          appendedHistoryMessageIds.add(lastUser.sourceMessageId!);
        }
      }
      final assembledHistory = interleaveDepthWithHistory(
        historyMsgs,
        resolvedDepthMsgs,
      );
      messages.addAll(
        insertContinueInstruction(
          assembledHistory,
          payload.continueInstruction,
        ),
      );
      for (final block in resolvedDepthBlocks) {
        if (block.message.content.trim().isNotEmpty) {
          recordAssembly(block.classifications);
        }
      }
      for (final db in resolvedDepthMsgs) {
        attributionBlocks.add(
          StaticBlock(id: db.blockId ?? 'preset', content: db.content),
        );
      }
    } else {
      final content = block.content;
      final accountingContent = block.contentForAccounting;

      // setvar-only blocks: no LLM-visible text, but definitions count toward preset.
      if (content.trim().isEmpty && !block.sendEmptyBlock) {
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

      recordAssembly(blockLoreClassifications[block.id] ?? const {});

      messages.add(
        PromptMessage(
          role: block.role,
          blockId: block.id,
          blockName: block.name,
          content: content,
          isSummary: block.isSummary,
          sendEmptyBlock: block.sendEmptyBlock,
        ),
      );

      // worldInfoAfter injects just after char_card (mirrors JS generationWorker.js:792)
      if (block.id == 'char_card') injectLoreAfter();
    }
  }

  // Fallback: if preset had no char_card block, inject remaining lore at the end
  injectLoreBefore();
  injectLoreAfter();

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
    excludeReasoningFromContextBudget:
        payload.apiConfig.excludeReasoningFromContextBudget,
    historyTrimMode: payload.apiConfig.historyTrimMode,
    historyAnchorId: payload.sessionVars[ChatSessionX.historyAnchorVarKey],
    historyTrimTriggerPercent: payload.apiConfig.historyTrimTriggerPercent,
    historyTrimStepPercent: payload.apiConfig.historyTrimStepPercent,
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
  final recalledMessagesContent = const RecalledMessagesResolver().resolve(
    chunks: payload.recalledMessageChunks,
    visibleMessageIds: recallVisibleMessageIds,
    fallbackContent: payload.recalledMessagesContent,
    disableSourceWindowExclusion: payload.disableSourceWindowExclusion,
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
      gameTime: GameTimeState(
        time: payload.gameTime,
        date: payload.gameDate,
        day: int.tryParse(payload.gameDay ?? ''),
      ),
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
        if (appendedHistoryMessageIds.contains(msg.sourceMessageId)) {
          recordAssembly(appendedClassifications);
        }
      }
      historySeen++;
    } else if (msg.content.trim().isNotEmpty || msg.sendEmptyBlock) {
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
  final injectionReports = _transformLorebookAssemblyReports(
    reports: assemblyReports,
    regexScripts: regexScripts,
    char: char,
    persona: persona,
    sessionVars: currentSessionVars,
    globalVars: currentGlobalVars,
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
    exactLorebookManifest: exactLorebookManifest
        ?.confirmedBy(injectionReports)
        .withProviderMessagesHash(
          computeHash(
            jsonEncode(
              buildApiMessages(
                finalMessagesWithRegex,
                reasoningHistoryCount: payload.apiConfig.reasoningHistoryCount,
              ),
            ),
          ),
        ),
    triggeredMemories: finalTriggeredMemories,
    memoryCoverage: finalMemoryCoverage,
  );
}

List<ExactLorebookInjectionReport> _transformLorebookAssemblyReports({
  required List<ExactLorebookInjectionReport> reports,
  required List<PresetRegex> regexScripts,
  required Character char,
  required Persona? persona,
  required Map<String, String> sessionVars,
  required Map<String, String> globalVars,
}) {
  if (reports.isEmpty) return const [];
  // Events originate at real assembly sites.  Deliberately never search the
  // final prompt (or preset) for matching content to infer attribution.
  final transformedReports = <ExactLorebookInjectionReport>[];
  final context = RegexApplyContext(
    char: char,
    persona: persona,
    sessionVars: sessionVars,
    globalVars: globalVars,
  );
  final byClassification = <String, List<ExactLorebookInjectionReport>>{};
  for (final report in reports) {
    byClassification.putIfAbsent(report.classification, () => []).add(report);
  }
  for (final group in byClassification.values) {
    group.sort((a, b) => a.placement.compareTo(b.placement));
    final joined = group.map((report) => report.renderedContent).join('\n\n');
    final transformed = regexScripts.isEmpty
        ? joined
        : applyRegexes(
            joined,
            group.first.classification.startsWith('worldInfo') ? 5 : 4,
            2,
            regexScripts,
            context,
            isPrompt: true,
          );
    // A transform that crossed entry boundaries (merged or removed parts)
    // cannot prove per-entry post-transform content. The assembly event
    // already happened at the emission site, so the entries stay confirmed
    // with their pre-transform content — coverage must never report a false
    // "not injected" because a regex pass reshaped the joined block.
    final parts = transformed.split('\n\n');
    if (parts.length != group.length) {
      transformedReports.addAll(group);
      continue;
    }
    for (var index = 0; index < group.length; index++) {
      if (parts[index].trim().isEmpty) continue;
      transformedReports.add(
        ExactLorebookInjectionReport(
          namespacedId: group[index].namespacedId,
          placement: group[index].placement,
          renderedContent: parts[index],
          classification: group[index].classification,
        ),
      );
    }
  }
  return transformedReports;
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
}) => const RecalledMessagesResolver().resolve(
  chunks: payload.recalledMessageChunks,
  visibleMessageIds: visibleMessageIds ?? payload.sourceWindowVisibleMessageIds,
  fallbackContent: payload.recalledMessagesContent,
  disableSourceWindowExclusion: payload.disableSourceWindowExclusion,
);

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
    imagePaths: original.imagePaths,
  );
}
