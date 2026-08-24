import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../db/repositories/chat_repo.dart';
import '../db/repositories/tracker_snapshot_repo.dart';
import '../models/agent_operation_record.dart';
import '../models/chat_message.dart';
import '../models/character.dart';
import '../models/persona.dart';
import '../models/pipeline_settings.dart';
import '../utils/think_tags.dart';
import 'aux_llm_client.dart';
import 'aux_retry_runner.dart';
import 'beauty_state_parser.dart';
import 'cleaner/audit_prompt_builder.dart';
import 'cleaner/cleaner_prompt_builder.dart';
import 'cleaner/cleaner_text_guard.dart';
import 'macro_engine.dart';
import 'shared/message_range_formatter.dart';
import 'studio/studio_aux_prompt_assembler.dart';
import 'transport/llm_capture_context.dart';
import '../models/studio_config.dart';

// Re-export extracted specialists for backward compat (tests import these
// symbols from post_cleaner_service.dart).
export 'cleaner/audit_prompt_builder.dart' show AuditPromptBuilder;
export 'cleaner/cleaner_prompt_builder.dart' show CleanerPromptBuilder;
export 'cleaner/cleaner_text_guard.dart' show CleanerTextGuard;

/// POST-cleaner service (Stage 4).
///
/// After generation completes, this service rewrites the final assistant
/// message to remove clichés, repetitive phrasings, and common AI-isms.
/// The rewrite is silent — the text in chat is replaced without a diff or
/// swipe UI. The original text is preserved as a swipe so the user can
/// still access it.
///
/// Uses [AuxLlmClient] for the auxiliary LLM call and
/// [ChatRepo.appendAgentSwipe] for the atomic DB update.
/// Falls back to the original text on any error.
class PostCleanerService {
  final AuxLlmClient _llm;
  final ChatRepo _chatRepo;
  final TrackerSnapshotRepo _snapshotRepo;
  final void Function(ChatSession) onSessionUpdated;
  final void Function() _invalidateChatHistory;

  PostCleanerService({
    required this._llm,
    required this._chatRepo,
    required this._snapshotRepo,
    required this.onSessionUpdated,
    required this._invalidateChatHistory,
  });

  /// Run the POST-cleaner on the last assistant message.
  ///
  /// Returns the cleaned text, or the original if cleaning was disabled,
  /// failed, or the LLM returned an empty/refusal response.
  /// [broadcastBlocks] are verbatim cross-cutting preset rules (output language
  /// + prose-quality guards) captured at Studio build time. When present they
  /// drive the cleaner using the user's OWN rules instead of the hardcoded
  /// English-only cliché list, and pin the output language so the rewrite does
  /// not silently translate or break language-specific formatting.
  /// [recentMessages] is the bounded chat history before the assistant response,
  /// used for conservative local continuity checks (who said what, who is
  /// present, clothing, positions, recent actions).
  Future<PostCleanerResult> runCleaner({
    required String sessionId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required String assistantText,
    String? messageId,
    List<String> broadcastBlocks = const [],
    List<ChatMessage> recentMessages = const [],
    List<String>? auditIssues,
    CancelToken? cancelToken,
    void Function(String accumulatedText)? onCleanedChunk,
    String beautyBrief = '',
    String? beautyState,
    List<StudioPresetBlock> cleanerBlocks = const [],
    MacroContext? macroCtx,
  }) async {
    // Post-cleaner is always-on (Studio-only). Continuity checks and
    // character/world audits always run.

    // Strip any hidden reasoning (`<think>…</think>` / `<thinking>…`) that the
    // generator left inside the saved message content. If it reaches the
    // cleaner prompt the model often echoes / re-expands it, blowing the
    // output length past the safety ratio (→ silently skipped, no swipe). We
    // clean the visible prose only and compare lengths against this stripped
    // baseline, not the raw stored text.
    assistantText = stripThinkTags(assistantText);

    final token = cancelToken ?? CancelToken();
    if (token.isCancelled) {
      return PostCleanerResult(
        status: 'aborted',
        cleanedText: wrapLumiaOocColors(assistantText),
      );
    }

    if (assistantText.trim().isEmpty) {
      return PostCleanerResult(
        status: 'ok',
        cleanedText: wrapLumiaOocColors(assistantText),
      );
    }

    try {
      if (token.isCancelled) {
        return PostCleanerResult(
          status: 'aborted',
          cleanedText: wrapLumiaOocColors(assistantText),
        );
      }

      final outcome = await _askLlmForCleanedText(
        config: config,
        settings: settings,
        assistantText: assistantText,
        sessionId: sessionId,
        messageId: messageId,
        broadcastBlocks: broadcastBlocks,
        recentMessages: recentMessages,
        auditIssues: auditIssues,
        cancelToken: token,
        onCleanedChunk: onCleanedChunk,
        beautyBrief: beautyBrief,
        beautyState: beautyState,
        cleanerBlocks: cleanerBlocks,
        macroCtx: macroCtx,
      );

      if (token.isCancelled) {
        return PostCleanerResult(
          status: 'aborted',
          cleanedText: wrapLumiaOocColors(assistantText),
          attempts: outcome.attempts,
          totalElapsedMs: outcome.totalElapsedMs,
        );
      }

      // Also strip reasoning the cleaner model itself may have emitted in its
      // reply (some sidecar models wrap output in raw `<think>` blocks).
      final cleaned = outcome.text == null
          ? null
          : stripThinkTags(outcome.text!);
      if (cleaned == null || cleaned.trim().isEmpty) {
        if (!outcome.isOk) {
          return PostCleanerResult(
            status: _statusLabel(outcome.status),
            cleanedText: wrapLumiaOocColors(assistantText),
            error: outcome.attempts.isNotEmpty
                ? outcome.attempts.last.error
                : null,
            attempts: outcome.attempts,
            totalElapsedMs: outcome.totalElapsedMs,
            model: config.model,
          );
        }
        return PostCleanerResult(
          status: 'ok',
          cleanedText: wrapLumiaOocColors(assistantText),
          attempts: outcome.attempts,
          totalElapsedMs: outcome.totalElapsedMs,
          model: config.model,
        );
      }

      // Safety: if the cleaned text is drastically shorter or longer, skip.
      final ratio = cleaned.length / assistantText.length;
      if (ratio < 0.3 || ratio > 3.0) {
        debugPrint(
          '[PostCleaner] skipped: length ratio $ratio out of bounds '
          '(original=${assistantText.length}, cleaned=${cleaned.length})',
        );
        return PostCleanerResult(
          status: 'skipped',
          cleanedText: wrapLumiaOocColors(assistantText),
          attempts: outcome.attempts,
          totalElapsedMs: outcome.totalElapsedMs,
          model: config.model,
        );
      }

      // Safety: reject the rewrite if it dropped protected markup that was
      // present in the original assistant response. Cheap presence-only check
      // (ported from Marinara `text-rewrite-safety.ts`): if the original had
      // inline HTML/XML tags or fenced code blocks and the cleaned version no
      // longer has any, the cleaner stripped formatting it was told to
      // preserve — keep the original. Also protects meta-OOC blocks
      // (e.g. `<lumiaooc>`, `<oocnote>`, any `<*ooc*>` — meta-commentary
      // emitted by the Main Writer under the Studio meta-weaver
      // architecture) — if the original had one and the cleaned version
      // dropped it, keep the original. This guards against the common
      // LLM failure mode of flattening formatting when asked to "rewrite for
      // clarity". Does NOT verify the *same* tags/fences survive, just that
      // *some* survive — structural equality is the cleaner prompt's job.
      if (CleanerTextGuard.textRewriteDropsProtectedMarkup(
            assistantText,
            cleaned,
          ) ||
          CleanerTextGuard.lumiaoocDropped(assistantText, cleaned)) {
        debugPrint(
          '[PostCleaner] skipped: rewrite dropped protected markup '
          '(HTML/XML tags or fenced code blocks present in original but '
          'absent in cleaned)',
        );
        return PostCleanerResult(
          status: 'skipped',
          cleanedText: wrapLumiaOocColors(assistantText),
          attempts: outcome.attempts,
          totalElapsedMs: outcome.totalElapsedMs,
          model: config.model,
        );
      }

      // Strip any <glaze_beauty_state> marker the cleaner emitted and
      // extract the updated state JSON. The marker is parsed here (not in
      // the pipeline) so the caller receives already-clean text + state.
      final beautyParsed = parseBeautyState(cleaned);
      // Deterministically wrap <lumiaooc> blocks in Lumia's signature color.
      // The cleaner LLM no longer owns this rule (it frequently forgot it);
      // see wrapLumiaOocColors docs.
      final finalCleanedText = wrapLumiaOocColors(beautyParsed.cleanedText);

      return PostCleanerResult(
        status: 'ok',
        cleanedText: finalCleanedText,
        originalText: assistantText,
        wasCleaned: finalCleanedText != assistantText,
        attempts: outcome.attempts,
        totalElapsedMs: outcome.totalElapsedMs,
        model: config.model,
        beautyStateJson: beautyParsed.stateJson,
        beautyMarkerFound: beautyParsed.markerFound,
      );
    } on TimeoutException {
      return PostCleanerResult(
        status: 'timeout',
        cleanedText: wrapLumiaOocColors(assistantText),
      );
    } catch (e) {
      if (token.isCancelled || (e is DioException && CancelToken.isCancel(e))) {
        return PostCleanerResult(
          status: 'aborted',
          cleanedText: wrapLumiaOocColors(assistantText),
        );
      }
      debugPrint('[PostCleaner] error: $e');
      return PostCleanerResult(
        status: 'error',
        cleanedText: wrapLumiaOocColors(assistantText),
        error: '$e',
      );
    }
  }

  // ── Backward-compat static facades ──────────────────────────────────────
  // Tests call PostCleanerService.buildCleanerPrompt / buildAuditPrompt /
  // parseAuditJson / textRewriteDropsProtectedMarkup / lumiaoocDropped
  // directly. These facades delegate to the extracted specialist classes so
  // tests keep working without import changes.

  @visibleForTesting
  static bool textRewriteDropsProtectedMarkup(String original, String edited) =>
      CleanerTextGuard.textRewriteDropsProtectedMarkup(original, edited);

  @visibleForTesting
  static bool lumiaoocDropped(String original, String edited) =>
      CleanerTextGuard.lumiaoocDropped(original, edited);

  static String _statusLabel(AgentOperationStatus status) {
    return switch (status) {
      AgentOperationStatus.ok => 'ok',
      AgentOperationStatus.disabled => 'disabled',
      AgentOperationStatus.aborted => 'aborted',
      AgentOperationStatus.timeout => 'timeout',
      AgentOperationStatus.httpError => 'error',
      AgentOperationStatus.invalidOutput => 'error',
      AgentOperationStatus.error => 'error',
    };
  }

  Future<AuxCallOutcome> _askLlmForCleanedText({
    required AuxApiConfig config,
    required PipelineSettings settings,
    required String assistantText,
    required String sessionId,
    String? messageId,
    List<String> broadcastBlocks = const [],
    List<ChatMessage> recentMessages = const [],
    List<String>? auditIssues,
    required CancelToken cancelToken,
    void Function(String accumulatedText)? onCleanedChunk,
    String beautyBrief = '',
    String? beautyState,
    List<StudioPresetBlock> cleanerBlocks = const [],
    MacroContext? macroCtx,
  }) async {
    final prompt = buildStudioCleanerPrompt(
      assistantText: assistantText,
      broadcastBlocks: broadcastBlocks,
      recentMessages: recentMessages,
      auditIssues: auditIssues,
      maxCharsPerMessage: settings.cleaner.postCleanerMaxCharsPerMessage,
      bannedWords: settings.cleaner.postCleanerBannedWords,
      avoidInstructions: settings.cleaner.postCleanerAvoidInstructions,
      styleInstructions: settings.cleaner.postCleanerStyleInstructions,
      beautyBrief: beautyBrief,
      beautyState: beautyState,
      cleanerBlocks: cleanerBlocks,
      macroCtx: macroCtx,
    );

    final effectiveMaxTokens = settings.cleaner.postCleanerMaxTokens > 0
        ? settings.cleaner.postCleanerMaxTokens
        : (assistantText.length ~/ 2).clamp(1000, 16000);

    // When the caller passes an onCleanedChunk callback, stream the rewrite
    // so the UI can render it progressively instead of replacing the text in
    // one shot. Otherwise use the non-streaming path (same as before).
    if (onCleanedChunk != null) {
      return _llm.callStreamWithLog(
        config: config,
        prompt: prompt,
        maxTokens: effectiveMaxTokens,
        temperature: settings.cleaner.postCleanerTemperature,
        timeoutMs: _llm.resolveCleanerTimeout(settings),
        cancelToken: cancelToken,
        onChunk: onCleanedChunk,
        requestReasoning: settings.cleaner.postCleanerDisableReasoning
            ? false
            : settings.cleaner.postCleanerRequestReasoning,
        omitReasoning: settings.cleaner.postCleanerDisableReasoning
            ? true
            : settings.cleaner.postCleanerOmitReasoning,
        omitReasoningEffort: settings.cleaner.postCleanerOmitReasoningEffort,
        captureContext: LlmCaptureContext(
          stage: 'cleaner.rewrite',
          sessionId: sessionId,
          messageId: messageId,
          logicalCallId: messageId == null ? null : 'cleaner:$messageId',
          relatedArtifactId: messageId,
        ),
      );
    }

    return _llm.callOnceWithLog(
      config: config,
      prompt: prompt,
      maxTokens: effectiveMaxTokens,
      temperature: settings.cleaner.postCleanerTemperature,
      timeoutMs: _llm.resolveCleanerTimeout(settings),
      cancelToken: cancelToken,
      requestReasoning: settings.cleaner.postCleanerDisableReasoning
          ? false
          : settings.cleaner.postCleanerRequestReasoning,
      omitReasoning: settings.cleaner.postCleanerDisableReasoning
          ? true
          : settings.cleaner.postCleanerOmitReasoning,
      omitReasoningEffort: settings.cleaner.postCleanerOmitReasoningEffort,
      captureContext: LlmCaptureContext(
        stage: 'cleaner.rewrite',
        sessionId: sessionId,
        messageId: messageId,
        logicalCallId: messageId == null ? null : 'cleaner:$messageId',
        relatedArtifactId: messageId,
      ),
    );
  }

  /// Backward-compat facade — delegates to [CleanerPromptBuilder].
  /// Tests call `PostCleanerService.buildCleanerPrompt` directly.
  @visibleForTesting
  static String buildCleanerPrompt({
    required String assistantText,
    List<String> broadcastBlocks = const [],
    List<ChatMessage> recentMessages = const [],
    List<String>? auditIssues,
    int maxCharsPerMessage = 3000,
    String bannedWords = '',
    String avoidInstructions = '',
    String styleInstructions = '',
    String beautyBrief = '',
    String? beautyState,
  }) => CleanerPromptBuilder.buildCleanerPrompt(
    assistantText: assistantText,
    broadcastBlocks: broadcastBlocks,
    recentMessages: recentMessages,
    auditIssues: auditIssues,
    maxCharsPerMessage: maxCharsPerMessage,
    bannedWords: bannedWords,
    avoidInstructions: avoidInstructions,
    styleInstructions: styleInstructions,
    beautyBrief: beautyBrief,
    beautyState: beautyState,
  );

  /// Builds the cleaner prompt from preset blocks when available, falling
  /// back to [CleanerPromptBuilder] when no preset blocks are supplied.
  ///
  /// When [cleanerBlocks] is non-empty and [macroCtx] is provided, the prompt
  /// is assembled from the preset's `cleaner` section blocks with macros
  /// resolved. Runtime data (recent messages, audit issues, assistant text)
  /// and broadcast blocks are appended as a code-owned suffix. The beauty
  /// brief/state are injected via custom replacements so a `cleaner_beauty`
  /// block can use `{{beautyBrief}}` and `{{getvar::glaze_beauty_state}}`.
  @visibleForTesting
  static String buildStudioCleanerPrompt({
    required String assistantText,
    List<String> broadcastBlocks = const [],
    List<ChatMessage> recentMessages = const [],
    List<String>? auditIssues,
    int maxCharsPerMessage = 3000,
    String bannedWords = '',
    String avoidInstructions = '',
    String styleInstructions = '',
    String beautyBrief = '',
    String? beautyState,
    List<StudioPresetBlock> cleanerBlocks = const [],
    MacroContext? macroCtx,
  }) {
    if (cleanerBlocks.isEmpty || macroCtx == null) {
      return CleanerPromptBuilder.buildCleanerPrompt(
        assistantText: assistantText,
        broadcastBlocks: broadcastBlocks,
        recentMessages: recentMessages,
        auditIssues: auditIssues,
        maxCharsPerMessage: maxCharsPerMessage,
        bannedWords: bannedWords,
        avoidInstructions: avoidInstructions,
        styleInstructions: styleInstructions,
        beautyBrief: beautyBrief,
        beautyState: beautyState,
      );
    }

    final customReplacements = <String, String>{};
    if (beautyBrief.trim().isNotEmpty) {
      customReplacements['{{beautyBrief}}'] = beautyBrief.trim();
    } else {
      customReplacements['{{beautyBrief}}'] = '';
    }

    final skipBlockIds = <String>{'cleaner_audit'};

    final suffix = StringBuffer();

    if (broadcastBlocks.isNotEmpty) {
      final rules = broadcastBlocks
          .map((b) => b.trim())
          .where((b) => b.isNotEmpty)
          .toList();
      if (rules.isNotEmpty) {
        suffix
          ..writeln()
          ..writeln(
            'AUTHORITATIVE RULES (from the active Studio preset — follow these exactly; '
            'they OVERRIDE the generic guidance above, especially for output '
            'language and formatting):',
          )
          ..writeln()
          ..writeln(rules.join('\n\n---\n\n'))
          ..writeln();
      }
    }

    if (recentMessages.isNotEmpty) {
      final history = formatRecentMessages(recentMessages, maxCharsPerMessage);
      if (history.isNotEmpty) {
        suffix
          ..writeln('RECENT CHAT HISTORY:')
          ..writeln(history)
          ..writeln();
      }
    }

    if (auditIssues != null && auditIssues.isNotEmpty) {
      suffix
        ..writeln('CHARACTER CONSISTENCY NOTES (from auditor — fix these):')
        ..writeln(auditIssues.map((i) => '- $i').join('\n'))
        ..writeln()
        ..writeln(
          'Apply minimal fixes for these issues while also cleaning style.',
        )
        ..writeln(
          'Do not add new content to resolve them. Prefer rephrasing that '
          'preserves the prose\'s voice; only delete or neutralize when '
          'rephrasing would bloat the text.',
        )
        ..writeln();
    }

    if (bannedWords.trim().isNotEmpty ||
        avoidInstructions.trim().isNotEmpty ||
        styleInstructions.trim().isNotEmpty) {
      suffix
        ..writeln(
          'GLOBAL STYLE OVERRIDES (user-defined cross-chat rules — apply '
          'ALONGSIDE the authoritative rules above; do not contradict them):',
        )
        ..writeln();
      if (bannedWords.trim().isNotEmpty) {
        suffix
          ..writeln(
            'BANNED WORDS (never use these, even if the original has them):',
          )
          ..writeln(bannedWords.trim())
          ..writeln();
      }
      if (avoidInstructions.trim().isNotEmpty) {
        suffix
          ..writeln('AVOID (specific patterns to steer away from):')
          ..writeln(avoidInstructions.trim())
          ..writeln();
      }
      if (styleInstructions.trim().isNotEmpty) {
        suffix
          ..writeln('PREFER (style direction to lean into):')
          ..writeln(styleInstructions.trim())
          ..writeln();
      }
    }

    if (recentMessages.isNotEmpty) {
      suffix
        ..writeln('Continuity rules:')
        ..writeln(
          '- Before editing style, silently check the assistant response '
          'against RECENT CHAT HISTORY.',
        )
        ..writeln(
          '- Fix only clear local continuity contradictions that are directly '
          'contradicted by the provided context: who said what, who is '
          'present, current position, clothing, held objects, object '
          'ownership, and recent actions.',
        )
        ..writeln('- If the context is ambiguous, keep the original wording.')
        ..writeln('- Do not invent missing details.')
        ..writeln(
          '- Do not add new events, explanations, dialogue, memories, or '
          'motivations.',
        )
        ..writeln(
          '- Prefer minimal edits: fix the contradiction while keeping the '
          'sentence vivid. Rephrase rather than delete when possible; only '
          'shorten or neutralize when rephrasing would bloat the text.',
        )
        ..writeln(
          '- If correcting a continuity issue requires adding a new '
          'paragraph or scene event, do not fix it — only clean style.',
        )
        ..writeln();
    }

    suffix
      ..writeln()
      ..writeln('Assistant response to clean:')
      ..write(assistantText);

    return const StudioAuxPromptAssembler().assemble(
      blocks: cleanerBlocks,
      injectionPoint: 'cleaner',
      macroCtx: macroCtx,
      customReplacements: customReplacements,
      runtimeSuffix: suffix.toString(),
      skipBlockIds: skipBlockIds,
    );
  }

  /// Applies the cleaned text to the session: appends a blue 'cleaned' agent
  /// swipe carrying [cleanedText] to the last assistant message via
  /// [ChatRepo.appendAgentSwipe]. The original 'final' text remains available
  /// as the parent swipe and is lazy-migrated on first clean.
  ///
  /// [genTime] is the cleaner's own elapsed time (e.g. `"12.3s"`), surfaced as
  /// a per-swipe badge on the cleaned sub-swipe (Fix 3). [tokens] is the
  /// cleaned text's token count (Fix 4). When null, the badge is omitted by
  /// the mapper and renderer — pass non-null to keep the badge visible.
  ///
  /// After the append, clones the parent agent-swipe's tracker snapshot into
  /// the new 'cleaned' anchor so navigating to the blue sub-swipe restores the
  /// correct tracker state (the cleaner rewrites prose, not trackers).
  Future<void> applyCleanedText({
    required String sessionId,
    required String messageId,
    required String cleanedText,
    String? genTime,
    int? tokens,
  }) async {
    final chatRepo = _chatRepo;
    final updated = await chatRepo.appendAgentSwipe(
      sessionId: sessionId,
      messageId: messageId,
      content: cleanedText,
      kind: 'cleaned',
      genTime: genTime,
      tokens: tokens,
    );
    if (!updated) return;

    // Refresh cache + reactive streams.
    final session = await chatRepo.getById(sessionId);
    if (session != null) {
      onSessionUpdated(session);
    }
    _invalidateChatHistory();

    // Clone the parent agent-swipe's tracker snapshot into the new 'cleaned'
    // anchor. The cleaner rewrites prose — tracker state is unchanged, so the
    // 'cleaned' sub-swipe inherits the parent 'final's trackers. Read the
    // post-append message to get the exact swipeId + new agentSwipeId (handles
    // lazy-backfill for legacy messages).
    try {
      final msg = session?.messages.where((m) => m.id == messageId).firstOrNull;
      if (msg == null || msg.agentSwipeId <= 0) return;
      final parentAgentSwipeId = msg.agentSwipeId - 1;
      final snapshotRepo = _snapshotRepo;
      final parent = await snapshotRepo.getByAnchor(
        sessionId: sessionId,
        messageId: messageId,
        swipeId: msg.swipeId,
        agentSwipeId: parentAgentSwipeId,
      );
      if (parent != null) {
        await snapshotRepo.upsertTrackers(
          sessionId: sessionId,
          messageId: messageId,
          swipeId: msg.swipeId,
          agentSwipeId: msg.agentSwipeId,
          trackers: parent.trackers,
        );
      }
    } catch (e) {
      debugPrint('[PostCleaner] snapshot clone failed: $e');
    }
  }

  /// Pass 0: Character/World Auditor.
  ///
  /// Diagnostic sidecar pass that checks [assistantText] against the full
  /// generation context (character card, persona, lorebooks, memory, summary,
  /// arcs, entities, recent history) and returns a compact list of
  /// contradictions. Does NOT rewrite text.
  ///
  /// Returns:
  /// - `[]` — no contradictions found.
  /// - `['issue 1', ...]` — list of specific contradictions.
  /// - `null` — audit call failed, JSON unparseable, or was aborted. Caller
  ///   should skip audit notes and run the cleaner as Phase 1.
  Future<AuditResult> runCharacterAudit({
    required String sessionId,
    String? messageId,
    required String assistantText,
    required Character character,
    Persona? persona,
    String? lorebooksContent,
    String? memoryContent,
    String? summaryContent,
    String? arcContent,
    String? entitiesContent,
    List<ChatMessage> recentMessages = const [],
    required PipelineSettings settings,
    required AuxApiConfig config,
    CancelToken? cancelToken,
    List<StudioPresetBlock> cleanerBlocks = const [],
    String? beautyState,
  }) async {
    if (assistantText.trim().isEmpty) {
      return const AuditResult(issues: []);
    }

    final token = cancelToken ?? CancelToken();
    if (token.isCancelled) return const AuditResult(issues: null);

    try {
      if (token.isCancelled) return const AuditResult(issues: null);

      // Extract cleaner_audit block content from preset if available.
      String auditBlockContent = '';
      for (final b in cleanerBlocks) {
        if (b.id == 'cleaner_audit' && b.enabled) {
          auditBlockContent = b.content;
          break;
        }
      }

      final prompt = AuditPromptBuilder.buildAuditPrompt(
        assistantText: assistantText,
        character: character,
        persona: persona,
        lorebooksContent: lorebooksContent,
        memoryContent: memoryContent,
        summaryContent: summaryContent,
        arcContent: arcContent,
        entitiesContent: entitiesContent,
        recentMessages: recentMessages,
        maxCharsPerMessage: settings.cleaner.postCleanerMaxCharsPerMessage,
        beautyState: beautyState,
        auditBlockContent: auditBlockContent,
      );

      // Auditor: cheap, JSON-only, low temperature, small token budget.
      // Bump maxTokens when preset-driven (Beauty Shard needs room).
      final maxTokens = auditBlockContent.isNotEmpty ? 2048 : 1024;
      final outcome = await _llm.callOnceWithLog(
        config: config,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: 0.0,
        timeoutMs: _llm.resolveCleanerTimeout(settings),
        cancelToken: token,
        captureContext: LlmCaptureContext(
          stage: 'cleaner.audit',
          sessionId: sessionId,
          messageId: messageId,
          logicalCallId: messageId == null ? null : 'cleaner-audit:$messageId',
          relatedArtifactId: messageId,
        ),
      );

      if (token.isCancelled) return const AuditResult(issues: null);

      final text = outcome.text;
      if (text == null || text.trim().isEmpty) {
        if (!outcome.isOk) return const AuditResult(issues: null);
        return const AuditResult(issues: []);
      }

      return AuditPromptBuilder.parseAuditResult(text);
    } on TimeoutException {
      return const AuditResult(issues: null);
    } catch (e) {
      if (token.isCancelled || (e is DioException && CancelToken.isCancel(e))) {
        return const AuditResult(issues: null);
      }
      debugPrint('[PostCleanerAudit] error: $e');
      return const AuditResult(issues: null);
    }
  }

  /// Backward-compat facade — delegates to [AuditPromptBuilder].
  /// Tests call `PostCleanerService.buildAuditPrompt` directly.
  @visibleForTesting
  static String buildAuditPrompt({
    required String assistantText,
    required Character character,
    Persona? persona,
    String? lorebooksContent,
    String? memoryContent,
    String? summaryContent,
    String? arcContent,
    String? entitiesContent,
    List<ChatMessage> recentMessages = const [],
    int maxCharsPerMessage = 3000,
  }) => AuditPromptBuilder.buildAuditPrompt(
    assistantText: assistantText,
    character: character,
    persona: persona,
    lorebooksContent: lorebooksContent,
    memoryContent: memoryContent,
    summaryContent: summaryContent,
    arcContent: arcContent,
    entitiesContent: entitiesContent,
    recentMessages: recentMessages,
    maxCharsPerMessage: maxCharsPerMessage,
  );

  /// Backward-compat facade — delegates to [AuditPromptBuilder].
  /// Tests call `PostCleanerService.parseAuditJson` directly.
  @visibleForTesting
  static List<String>? parseAuditJson(String raw) =>
      AuditPromptBuilder.parseAuditJson(raw);
}

/// Result of a POST-cleaner run.
class PostCleanerResult {
  final String status;
  final String cleanedText;
  final String? originalText;
  final bool wasCleaned;
  final String? error;
  final List<AgentOperationAttempt> attempts;
  final int totalElapsedMs;
  final String? model;
  final String? beautyStateJson;
  final bool beautyMarkerFound;

  const PostCleanerResult({
    required this.status,
    required this.cleanedText,
    this.originalText,
    this.wasCleaned = false,
    this.error,
    this.attempts = const [],
    this.totalElapsedMs = 0,
    this.model,
    this.beautyStateJson,
    this.beautyMarkerFound = false,
  });
}
