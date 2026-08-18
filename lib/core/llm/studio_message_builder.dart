import '../models/studio_config.dart';
import '../models/studio_preset_block_groups.dart';
import 'history_assembler.dart';
import 'studio_brief_deduper.dart';
import 'studio_controller_ontology.dart';
import 'studio_prompt_text.dart';
import 'studio_stage_brief.dart';
import 'studio/studio_brief_macro_renderer.dart';
import 'studio/studio_history_limiter.dart';
import 'studio/studio_runtime_block_expander.dart';
import 'studio/studio_context.dart';

/// Builds the per-agent, batch, and final-generator message lists for the
/// Studio chat-time pipeline. Extracted from `MemoryStudioService` (plan §2.7).
///
/// Thin orchestrator — delegates block expansion to [StudioRuntimeBlockExpander],
/// history trimming to [StudioHistoryLimiter], and brief-macro rendering to
/// [StudioBriefMacroRenderer].
class StudioMessageBuilder {
  final StudioPromptText _promptText;
  final StudioBriefDeduper _briefDeduper;
  late final StudioBriefMacroRenderer _briefMacroRenderer =
      StudioBriefMacroRenderer(_briefDeduper);
  late final StudioRuntimeBlockExpander _blockExpander =
      StudioRuntimeBlockExpander(_briefMacroRenderer);

  StudioMessageBuilder(this._promptText, this._briefDeduper);

  List<Map<String, dynamic>> buildAgentMessages({
    required StudioAgent agent,
    required StudioContext context,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required List<StudioStageBrief> priorBriefs,
    required bool isFinalResponse,
    String mainResponse = '',
    int finalContextOverride = 0,
    // Trailing chat messages for an intermediate agent. 0 = the agent spec's
    // own size. Passed explicitly because an agent carries no context size of
    // its own (§4).
    int trackerContextOverride = 0,
    int reasoningHistoryCount = 0,
    bool excludeReasoningFromContextBudget = false,
  }) {
    final point = _blockExpander.injectionPointForRun(agent, isFinalResponse);
    final spec = StudioControllerOntology.specForAgent(agent);
    final specId = spec?.id;
    final isPostProc = agent.phase == 'post_processing';
    final routedBlocks =
        studioPreset.blocks
            .where((b) => !_blockExpander.isRuntimeComputedBlock(b))
            .where((b) {
              if (b.injectionPoint == 'specificAgent') {
                return !isFinalResponse &&
                    !isPostProc &&
                    b.targetAgentId == specId;
              }
              return b.injectionPoint == point;
            })
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    final resolvedBlocks = resolveEnabledStudioPresetBlocks(routedBlocks);
    // Depth-anchored instructions (insertionMode: 'depth') are not part of the
    // ordinary order-sequenced concatenation below — they are interleaved
    // INSIDE the chat-history array at a specific depth from the end, the
    // same way the classic (non-Studio) preset pipeline handles Author's Note
    // / `insertionMode: 'depth'` blocks (see `interleaveDepthWithHistory` in
    // `history_assembler.dart`). Pull them out here, after group-boundary
    // resolution (so folded group wrappers are already applied) and before
    // the main loop, so they aren't also emitted as ordinary messages.
    final depthBlocks = resolvedBlocks
        .where(
          (b) =>
              b.type == StudioBlockType.instruction &&
              b.insertionMode == 'depth',
        )
        .toList();
    final blocks = depthBlocks.isEmpty
        ? resolvedBlocks
        : resolvedBlocks.where((b) => !depthBlocks.contains(b)).toList();
    final depthMessages = depthBlocks.isEmpty
        ? const <PromptMessage>[]
        : _resolveDepthMessages(
            depthBlocks,
            context: context,
            priorBriefs: priorBriefs,
            studioPreset: studioPreset,
          );
    final hasExplicitBriefMacros =
        isFinalResponse &&
        blocks.any(
          (block) => _briefMacroRenderer.hasStudioBriefMacro(block.content),
        );
    final messages = <Map<String, dynamic>>[];

    for (final block in blocks) {
      // Type-based resolution takes precedence over mode/id. The codec sets
      // `type` and `contextSlot` correctly for every preset, but block ids vary
      // (final_chat_history, loom_chat_history, etc.) so id matching alone is
      // unreliable. Checking type first fixes presets whose context blocks have
      // a non-empty mode (e.g. Loom Direct sets mode: 'direct' on history).
      if (block.type == StudioBlockType.history) {
        final history = isFinalResponse
            ? StudioHistoryLimiter.limitFinalHistory(
                context.history,
                studioPreset,
                pipelineOverride: finalContextOverride,
                reasoningHistoryCount: reasoningHistoryCount,
                excludeReasoningFromContextBudget:
                    excludeReasoningFromContextBudget,
              )
            : StudioHistoryLimiter.limitTrackerHistory(
                context.history,
                trackerContextOverride > 0
                    ? trackerContextOverride
                    : StudioControllerOntology.contextSizeOf(
                        StudioControllerOntology.specForAgent(agent),
                      ),
              );
        if (isFinalResponse &&
            (reasoningHistoryCount == -1 || reasoningHistoryCount > 0)) {
          messages.addAll(
            _historyWithReasoning(
              history,
              reasoningHistoryCount,
              depthMessages: depthMessages,
            ),
          );
        } else {
          messages.addAll(
            interleaveDepthWithHistory(
              history,
              depthMessages,
            ).map((m) => m.toApiMap()),
          );
        }
        continue;
      }
      if (block.type == StudioBlockType.context && block.contextSlot != null) {
        messages.addAll(
          context.messagesFor(block.contextSlot!).map((m) => m.toApiMap()),
        );
        continue;
      }
      if (block.type == StudioBlockType.priorBriefs) {
        if (!isFinalResponse || hasExplicitBriefMacros) continue;
        final sanitized = priorBriefs
            .where((brief) => brief.brief.trim().isNotEmpty)
            .map(
              (brief) =>
                  _briefDeduper.sanitizePriorBriefForFinal(brief, studioPreset),
            )
            .toList();
        final deduped = _briefDeduper.dedupePriorBriefs(sanitized);
        messages.addAll(
          deduped
              .where((brief) => brief.brief.trim().isNotEmpty)
              .map(
                (brief) => {
                  'role': _blockExpander.normalizeInstructionRole(block.role),
                  'content':
                      'Studio agent brief: ${brief.agentName}\n${brief.brief}',
                },
              ),
        );
        continue;
      }
      // Instruction blocks: resolve by mode, with a legacy id-based fallback
      // for context slots that still have an empty mode.
      if (block.mode.isEmpty) {
        final blockId = block.id;
        if (blockId == 'static_context') {
          messages.addAll(context.staticContext.map((m) => m.toApiMap()));
        } else if (blockId == 'chat_history') {
          final history = isFinalResponse
              ? StudioHistoryLimiter.limitFinalHistory(
                  context.history,
                  studioPreset,
                  pipelineOverride: finalContextOverride,
                  reasoningHistoryCount: reasoningHistoryCount,
                  excludeReasoningFromContextBudget:
                      excludeReasoningFromContextBudget,
                )
              : StudioHistoryLimiter.limitTrackerHistory(
                  context.history,
                  trackerContextOverride > 0
                      ? trackerContextOverride
                      : StudioControllerOntology.contextSizeOf(
                          StudioControllerOntology.specForAgent(agent),
                        ),
                );
          if (isFinalResponse &&
              (reasoningHistoryCount == -1 || reasoningHistoryCount > 0)) {
            messages.addAll(
              _historyWithReasoning(
                history,
                reasoningHistoryCount,
                depthMessages: depthMessages,
              ),
            );
          } else {
            messages.addAll(
              interleaveDepthWithHistory(
                history,
                depthMessages,
              ).map((m) => m.toApiMap()),
            );
          }
        } else if (blockId == 'dynamic_context') {
          messages.addAll(context.dynamicContext.map((m) => m.toApiMap()));
        } else {
          final slot = _slotForBlockId(blockId);
          if (slot != null) {
            messages.addAll(context.messagesFor(slot).map((m) => m.toApiMap()));
          } else {
            final content = _blockExpander
                .expandStudioBlockContent(
                  block.content,
                  context: context,
                  priorBriefs: priorBriefs,
                  preset: studioPreset,
                )
                .trim();
            if (content.isNotEmpty) {
              _addInstructionMessage(messages, block.role, content);
            }
          }
        }
        continue;
      }
      switch (block.mode) {
        case 'direct':
          final control = StringBuffer()
            ..writeln(
              _blockExpander
                  .expandStudioBlockContent(
                    block.content,
                    context: context,
                    priorBriefs: priorBriefs,
                    preset: studioPreset,
                  )
                  .trim(),
            );
          if (!isFinalResponse) {
            if (spec != null) {
              control
                ..writeln()
                ..writeln(_promptText.intermediateRuntimeEnvelope(spec, agent));
            }
          }
          if (isFinalResponse &&
              (hasExplicitBriefMacros || priorBriefs.isNotEmpty)) {
            control
              ..writeln()
              ..writeln(_promptText.finalBriefUsageNote());
          }
          if (isFinalResponse) {
            final styleContract = _promptText.finalHardStyleContract(
              studioPreset,
            );
            if (styleContract.isNotEmpty) {
              control
                ..writeln()
                ..writeln(styleContract);
            }
          }
          _addInstructionMessage(messages, block.role, control.toString());
          break;
        case 'pregenBrief':
          if (!isFinalResponse || hasExplicitBriefMacros) break;
          final sanitized = priorBriefs
              .where((brief) => brief.brief.trim().isNotEmpty)
              .map(
                (brief) => _briefDeduper.sanitizePriorBriefForFinal(
                  brief,
                  studioPreset,
                ),
              )
              .toList();
          final deduped = _briefDeduper.dedupePriorBriefs(sanitized);
          messages.addAll(
            deduped
                .where((brief) => brief.brief.trim().isNotEmpty)
                .map(
                  (brief) => {
                    'role': _blockExpander.normalizeInstructionRole(block.role),
                    'content':
                        'Studio agent brief: ${brief.agentName}\n${brief.brief}',
                  },
                ),
          );
          break;
        case 'agentResponse':
          break;
      }
    }

    if (mainResponse.trim().isNotEmpty) {
      messages.add({
        'role': 'user',
        'content':
            '<assistant_response>\n${mainResponse.trim()}\n</assistant_response>\n\n'
            'The text above inside <assistant_response> is the generator\'s '
            'current reply. Edit, rewrite, or fix it according to your '
            'instructions. Output ONLY the final rewritten reply (no '
            'explanations, no <assistant_response> wrapper, no markdown '
            'fences). If no edit is needed, output the text verbatim.',
      });
    }
    return messages;
  }

  void _addInstructionMessage(
    List<Map<String, dynamic>> messages,
    String role,
    String content,
  ) {
    final resolved = content.trim();
    if (resolved.isEmpty) return;
    // Group boundaries are folded into authored block content before macro
    // expansion. If the last macro expands empty, only the closing tag remains.
    // Keep the physical wrapper attached to the preceding system message rather
    // than emitting a tag-only API message.
    final closing = _standaloneClosingTag.firstMatch(resolved);
    final tagName = closing?.group(1);
    if (tagName != null &&
        messages.isNotEmpty &&
        _hasUnclosedOpeningTag(messages, tagName)) {
      final previous = messages.last;
      if (previous['role'] == 'system' && previous['content'] is String) {
        previous['content'] =
            '${previous['content'].toString().trimRight()}\n$resolved';
        return;
      }
    }
    messages.add({
      'role': _blockExpander.normalizeInstructionRole(role),
      'content': resolved,
    });
  }

  static final _standaloneClosingTag = RegExp(r'^</([A-Za-z][\w-]*)>$');

  bool _hasUnclosedOpeningTag(
    List<Map<String, dynamic>> messages,
    String tagName,
  ) {
    final escaped = RegExp.escape(tagName);
    final opening = RegExp('<$escaped(?:\\s[^>]*)?>');
    final closing = RegExp('</$escaped>');
    var balance = 0;
    for (final message in messages) {
      if (message['role'] != 'system' || message['content'] is! String) {
        continue;
      }
      final content = message['content'] as String;
      balance += opening.allMatches(content).length;
      balance -= closing.allMatches(content).length;
    }
    return balance > 0;
  }

  StudioContextSlot? _slotForBlockId(String blockId) => switch (blockId) {
    'char_card' => StudioContextSlot.characterCard,
    'char_personality' => StudioContextSlot.characterPersonality,
    'user_persona' => StudioContextSlot.userPersona,
    'scenario' => StudioContextSlot.scenario,
    'example_dialogue' => StudioContextSlot.exampleDialogue,
    'authors_note' => StudioContextSlot.authorsNote,
    'memory' => StudioContextSlot.memory,
    'summary' => StudioContextSlot.summary,
    'lore_before' => StudioContextSlot.loreBefore,
    'lore_after' => StudioContextSlot.loreAfter,
    'lore_macro' => StudioContextSlot.loreMacro,
    'recalled_messages' => StudioContextSlot.recalledMessages,
    'character_knowledge' => StudioContextSlot.characterKnowledge,
    'studio_session_state' => StudioContextSlot.studioSessionState,
    'runtime_dynamic' => StudioContextSlot.runtimeDynamic,
    _ => null,
  };

  List<Map<String, dynamic>> _historyWithReasoning(
    List<PromptMessage> history,
    int reasoningHistoryCount, {
    List<PromptMessage> depthMessages = const [],
  }) {
    // Reasoning selection must run on the raw (unshifted) history so "last N
    // assistant turns" still means the same thing once depth-anchored blocks
    // get interleaved in below — depth insertion changes each message's
    // resulting list index, but not which of the ORIGINAL history messages
    // are the most recent assistant turns.
    final reasoningByMessage = <PromptMessage, String>{};
    final includeAll = reasoningHistoryCount == -1;
    var remaining = reasoningHistoryCount;
    for (
      var i = history.length - 1;
      i >= 0 && (includeAll || remaining > 0);
      i--
    ) {
      final message = history[i];
      if (message.role != 'assistant') continue;
      final reasoning = message.reasoningContent?.trim();
      if (reasoning?.isNotEmpty == true) {
        reasoningByMessage[message] = reasoning!;
        if (!includeAll) remaining--;
      }
    }
    final interleaved = interleaveDepthWithHistory(history, depthMessages);
    return interleaved.map<Map<String, dynamic>>((message) {
      final apiMap = message.toApiMap();
      final reasoning = reasoningByMessage[message];
      if (reasoning != null) apiMap['reasoning_content'] = reasoning;
      return apiMap;
    }).toList();
  }

  /// Resolves depth-anchored instruction blocks the same way an ordinary
  /// `direct`-mode instruction is resolved (macro expansion + role
  /// normalization), turning each into a [PromptMessage] ready for
  /// [interleaveDepthWithHistory].
  List<PromptMessage> _resolveDepthMessages(
    List<StudioPresetBlock> depthBlocks, {
    required StudioContext context,
    required List<StudioStageBrief> priorBriefs,
    required StudioPreset studioPreset,
  }) {
    final result = <PromptMessage>[];
    for (final block in depthBlocks) {
      final content = _blockExpander
          .expandStudioBlockContent(
            block.content,
            context: context,
            priorBriefs: priorBriefs,
            preset: studioPreset,
          )
          .trim();
      if (content.isEmpty) continue;
      result.add(
        PromptMessage(
          role: _blockExpander.normalizeInstructionRole(block.role),
          content: content,
          blockId: block.id,
          depth: block.depth ?? 0,
          isDepth: true,
        ),
      );
    }
    return result;
  }

  /// Shared messages for a batch: `static_context` + `dynamic_context` +
  /// `chat_history` (trimmed to [batchContextSize]).
  List<Map<String, dynamic>> buildSharedBatchMessages({
    required StudioContext context,
    required int batchContextSize,
  }) {
    final messages = <Map<String, dynamic>>[
      ...context.staticContext.map((message) => message.toApiMap()),
      ...context.dynamicContext.map((message) => message.toApiMap()),
    ];
    final history = StudioHistoryLimiter.limitTrackerHistory(
      context.history,
      batchContextSize,
    );
    messages.addAll(history.map((message) => message.toApiMap()));
    return messages;
  }

  /// Per-agent task text for a batch run: only the blocks addressed to THIS
  /// agent, plus its runtime envelope.
  ///
  /// Shared pre-gen instructions are deliberately absent — they are emitted
  /// once into the batch's `<role>` element (see [batchRoleText]). Repeating
  /// them here put every shared block into the prompt once per agent on top of
  /// the `<role>` copy — seven times over for a six-controller group — and all
  /// of those copies sat in `<agents>`, the volatile tail that the provider's
  /// prompt cache never covers. It also made the six `<agent_task>` bodies
  /// mostly identical, burying the part that actually differs between them.
  String buildPerAgentTaskText({
    required StudioAgent agent,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required StudioContext context,
  }) {
    final specId = StudioControllerOntology.specForAgent(agent)?.id;
    final routedBlocks =
        studioPreset.blocks
            .where(
              (b) =>
                  b.injectionPoint == 'specificAgent' &&
                  b.targetAgentId == specId,
            )
            .where((b) => !_blockExpander.isRuntimeComputedBlock(b))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    final blocks = resolveEnabledStudioPresetBlocks(routedBlocks);
    final buffer = StringBuffer();
    for (final block in blocks) {
      final content = _blockExpander
          .expandStudioBlockContent(
            block.content,
            context: context,
            preset: studioPreset,
          )
          .trim();
      if (content.isEmpty) continue;
      buffer
        ..writeln(content)
        ..writeln();
    }
    final spec = StudioControllerOntology.specForAgent(agent);
    if (spec != null) {
      buffer.writeln(_promptText.intermediateRuntimeEnvelope(spec, agent));
    }
    return buffer.toString().trim();
  }

  /// Role text for the `<role>` element: the shared pre-gen instruction text
  /// broadcast to every controller (specific-agent and context blocks excluded).
  String batchRoleText(
    StudioConfig config,
    StudioPreset studioPreset,
    StudioContext context,
  ) {
    final routedBlocks =
        studioPreset.blocks
            .where((b) => b.injectionPoint == 'pregen')
            .where((b) => b.mode == 'direct')
            .where((b) => !_blockExpander.isRuntimeComputedBlock(b))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    final blocks = resolveEnabledStudioPresetBlocks(routedBlocks);
    final buffer = StringBuffer();
    for (final block in blocks) {
      final content = _blockExpander
          .expandStudioBlockContent(
            block.content,
            context: context,
            preset: studioPreset,
          )
          .trim();
      if (content.isNotEmpty) buffer.writeln(content);
    }
    return buffer.toString().trim();
  }
}
