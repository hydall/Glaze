import '../../models/chat_message.dart' show ChatMessage, TriggeredEntry;
import '../../models/ledger_prompt_injection_mode.dart';
import '../../models/ledger_prompt_injection_policy.dart';
import '../generation_context_inputs.dart';
import '../history_assembler.dart';
import '../macro_engine.dart';
import '../prompt/lorebook_context_resolver.dart';
import '../prompt/memory_block_injector.dart' show finalizeMemoryCoverage;
import '../prompt/memory_context_resolver.dart';
import '../prompt/recalled_messages_resolver.dart';
import '../prompt/effective_canon_prompt_materializer.dart';
import '../prompt/selective_ledger_projection_filter.dart';
import 'studio_context.dart';

final class StudioContextPreparer {
  const StudioContextPreparer();

  StudioContext prepare({
    required GenerationContextInputs inputs,
    required Set<String> visibleMessageIds,
    LedgerPromptInjectionPolicy ledgerPromptInjectionPolicy =
        const LedgerPromptInjectionPolicy(
          presetOptIn: true,
          mode: LedgerPromptInjectionMode.legacy,
        ),
    String consumerPath = 'studio',
    bool disableSourceWindowExclusion = false,

    /// When non-empty, overrides `inputs.apiConfig.reasoningTagStart/End` in
    /// the [MacroContext]. Passed from the Studio preset's
    /// `runtime.reasoningTagStart/End`.
    String? reasoningTagStartOverride,
    String? reasoningTagEndOverride,
  }) {
    final visibleLedgerMessages = inputs.history
        .where(
          (message) =>
              !message.isHidden &&
              !message.isTyping &&
              (message.role == 'user' || message.role == 'assistant') &&
              visibleMessageIds.contains(message.id),
        )
        .toList(growable: false);
    final scanStart =
        visibleLedgerMessages.length >
            ledgerPromptInjectionPolicy.reverseScanDepth
        ? visibleLedgerMessages.length -
              ledgerPromptInjectionPolicy.reverseScanDepth
        : 0;
    final selectionWindow = visibleLedgerMessages.sublist(scanStart);
    final ledger = _materializeLedger(
      inputs: inputs,
      policy: ledgerPromptInjectionPolicy,
      consumerPath: consumerPath,
      visibleMessages: selectionWindow,
    );
    final disabled =
        ledgerPromptInjectionPolicy.effectiveMode ==
        LedgerPromptInjectionMode.disabled;
    final characterKnowledge = disabled
        ? null
        : ledger == null
        ? inputs.characterKnowledgeContent
        : ledger.characterKnowledgeContent;
    final studioSessionState = disabled
        ? null
        : ledger == null
        ? inputs.studioSessionStateContent
        : ledger.studioSessionStateContent;
    final arcContent = disabled
        ? null
        : ledger == null
        ? inputs.arcContent
        : ledger.arcContent;
    final baseMacroContext = MacroContext(
      charName: inputs.character.name,
      charDescription: inputs.character.description,
      charScenario: inputs.character.scenario,
      charPersonality: inputs.character.personality,
      charMesExample: inputs.character.mesExample,
      userName: inputs.persona?.name ?? 'User',
      personaPrompt: inputs.persona?.prompt,
      reasoningStart: (reasoningTagStartOverride?.isNotEmpty == true)
          ? reasoningTagStartOverride
          : inputs.apiConfig.reasoningTagStart,
      reasoningEnd: (reasoningTagEndOverride?.isNotEmpty == true)
          ? reasoningTagEndOverride
          : inputs.apiConfig.reasoningTagEnd,
      sessionVars: inputs.sessionVars,
      globalVars: inputs.globalVars,
      charId: inputs.character.id,
      sessionId: inputs.sessionId ?? '',
      summaryContent: inputs.summaryContent,
      guidanceText: inputs.guidanceText,
      macroName: inputs.character.macroName,
      arcContent: arcContent,
      entitiesContent: inputs.entitiesContent,
      studioSessionState: studioSessionState,
    );
    final lore = const LorebookContextResolver().resolve(
      history: inputs.history,
      character: inputs.character,
      sessionId: inputs.sessionId,
      lorebooks: inputs.lorebooks,
      settings: inputs.lorebookSettings,
      activations: inputs.lorebookActivations,
      vectorEntries: inputs.vectorEntries,
      macroContext: baseMacroContext,
      preScannedEntries: inputs.preScannedEntries,
    );

    final memory = inputs.memorySelection == null
        ? null
        : const MemoryContextResolver().resolve(
            selection: inputs.memorySelection!,
            visibleMessageIds: visibleMessageIds,
            disableSourceWindowExclusion: disableSourceWindowExclusion,
            excerptingEnabled: inputs.memoryExcerptingEnabled,
            packingMode: inputs.memoryPackingMode,
            excerptTokensPerChunk: inputs.memoryExcerptTokensPerChunk,
            excerptChunksPerEntry: inputs.memoryExcerptChunksPerEntry,
            chunkFirstTopEntries: inputs.chunkFirstTopEntries,
            chunkFirstTopChunks: inputs.chunkFirstTopChunks,
            summaryExcerpt: inputs.summaryContent,
          );
    final memoryHardContent = memory?.content?.hardBlockContent;
    final memoryMacroContent =
        memory?.content?.macroContent ??
        inputs.memoryMacroContent ??
        inputs.memoryContent;
    final loreMacroContent = lore.loreMacroBuffer.join('\n\n');
    final macroContext = baseMacroContext.copyWith(
      charDescription: _prepend(
        lore.loreDescription,
        inputs.character.description,
      ),
      charPersonality: _prepend(
        lore.lorePersonality,
        inputs.character.personality,
      ),
      charScenario: _prepend(lore.loreScenario, inputs.character.scenario),
      lorebooksContent: loreMacroContent,
      memoryContent: memoryMacroContent,
    );
    final visibleHistory = inputs.history
        .where(
          (message) =>
              !message.isHidden &&
              !message.isTyping &&
              visibleMessageIds.contains(message.id),
        )
        .toList(growable: false);
    final history = HistoryAssembler(macroContext).assemble(visibleHistory);
    final recalled = const RecalledMessagesResolver().resolve(
      chunks: inputs.recalledMessageChunks,
      visibleMessageIds: visibleMessageIds,
      fallbackContent: inputs.recalledMessagesContent,
      disableSourceWindowExclusion: disableSourceWindowExclusion,
    );

    final slots = <StudioContextSlot, List<PromptMessage>>{
      for (final slot in StudioContextSlot.values) slot: <PromptMessage>[],
    };
    void add(
      StudioContextSlot slot,
      String? content, {
      String role = 'system',
      int? depth,
    }) {
      final resolved = content?.trim() ?? '';
      if (resolved.isEmpty) return;
      slots[slot]!.add(
        PromptMessage(role: role, content: resolved, depth: depth),
      );
    }

    final characterCard = <String>[
      'Name: ${inputs.character.name}',
      if ((macroContext.charDescription ?? '').trim().isNotEmpty)
        'Description:\n${macroContext.charDescription}',
      if ((inputs.character.systemPrompt ?? '').trim().isNotEmpty)
        'System prompt:\n${inputs.character.systemPrompt}',
      if ((inputs.character.postHistoryInstructions ?? '').trim().isNotEmpty)
        'Post-history instructions:\n${inputs.character.postHistoryInstructions}',
    ].join('\n\n');
    add(StudioContextSlot.characterCard, characterCard);
    add(StudioContextSlot.characterPersonality, macroContext.charPersonality);
    if (inputs.persona != null &&
        inputs.persona!.prompt?.trim().isNotEmpty == true) {
      add(
        StudioContextSlot.userPersona,
        'Name: ${inputs.persona!.name}\n\n${inputs.persona!.prompt}',
      );
    }
    add(StudioContextSlot.scenario, macroContext.charScenario);
    add(StudioContextSlot.exampleDialogue, inputs.character.mesExample);
    final authorsNote = inputs.authorsNote;
    if (authorsNote?.enabled == true) {
      add(
        StudioContextSlot.authorsNote,
        authorsNote!.content,
        role: authorsNote.role,
        depth: authorsNote.depth,
      );
    }
    add(
      StudioContextSlot.summary,
      inputs.summaryContent == null
          ? null
          : '${inputs.summaryPrefix ?? ''}${inputs.summaryContent}',
    );
    add(StudioContextSlot.memory, memoryHardContent ?? inputs.memoryContent);
    slots[StudioContextSlot.loreBefore]!.addAll(lore.loreBefore);
    slots[StudioContextSlot.loreAfter]!.addAll(lore.loreAfter);
    add(StudioContextSlot.loreMacro, loreMacroContent);
    add(StudioContextSlot.recalledMessages, recalled);
    add(StudioContextSlot.characterKnowledge, characterKnowledge);
    add(StudioContextSlot.studioSessionState, studioSessionState);
    add(StudioContextSlot.runtimeDynamic, inputs.guidanceText);
    add(StudioContextSlot.runtimeDynamic, arcContent);
    add(StudioContextSlot.runtimeDynamic, inputs.entitiesContent);
    for (final block in inputs.runtimePromptBlocks) {
      final content = replaceMacros(block.content, macroContext).text;
      add(
        StudioContextSlot.runtimeDynamic,
        content,
        role: block.role.isEmpty ? 'system' : block.role,
        depth: block.depth,
      );
    }

    final memoryCoverage = memory == null
        ? inputs.memoryCoverage
        : finalizeMemoryCoverage(
            inputs.memoryCoverage,
            memory.selection,
            memory.excerptSelection,
          );
    return StudioContext(
      slots: {
        for (final entry in slots.entries)
          entry.key: List<PromptMessage>.unmodifiable(entry.value),
      },
      history: List<PromptMessage>.unmodifiable(history),
      sessionVars: Map<String, String>.unmodifiable(inputs.sessionVars),
      globalVars: Map<String, String>.unmodifiable(inputs.globalVars),
      macroContext: macroContext,
      diagnostics: StudioContextDiagnostics(
        triggeredLorebooks: List<TriggeredEntry>.unmodifiable(
          lore.triggeredEntries,
        ),
        triggeredMemories: List<TriggeredEntry>.unmodifiable(
          memory?.triggeredEntries ?? inputs.triggeredMemories,
        ),
        memoryCoverage: Map<String, dynamic>.unmodifiable(memoryCoverage),
        vectorLoreTokens: lore.vectorLoreTokens,
        visibleMessageIds: Set<String>.unmodifiable(visibleMessageIds),
        ledgerProjectionDiagnostics: ledger?.diagnostics ?? const [],
        ledgerInjectionIdentity:
            ledger?.injectionCacheIdentity ??
            '${ledgerPromptInjectionPolicy.identity}/${inputs.effectiveCanonCacheIdentity}',
      ),
    );
  }

  EffectiveCanonPromptMaterialization? _materializeLedger({
    required GenerationContextInputs inputs,
    required LedgerPromptInjectionPolicy policy,
    required String consumerPath,
    required List<ChatMessage> visibleMessages,
  }) {
    final projection = inputs.effectiveCanonProjection;
    if (projection == null) return null;

    return EffectiveCanonPromptMaterializer.materializeSafely(
      SelectiveLedgerProjectionInput(
        policy: policy,
        consumerPath: consumerPath,
        projection: projection,
        visibleMessages: visibleMessages,
        selectedSwipeByMessageId: {
          for (final message in visibleMessages) message.id: message.swipeId,
        },
        focalUserName: inputs.persona?.name ?? '',
        freshness: inputs.ledgerProjectionFreshnessProvenCurrent
            ? LedgerProjectionFreshness.provenCurrent
            : LedgerProjectionFreshness.unknown,
      ),
      sessionId: inputs.sessionId ?? '',
    );
  }

  String? _prepend(List<String> prefixes, String? value) {
    if (prefixes.isEmpty) return value;
    final prefix = prefixes.join('\n\n');
    return value?.trim().isNotEmpty == true ? '$prefix\n\n$value' : prefix;
  }
}
