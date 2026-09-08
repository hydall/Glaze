import '../models/studio_config.dart';
import 'history_assembler.dart';
import 'prompt_builder.dart';
import 'studio_brief_deduper.dart';
import 'studio_context_bucketizer.dart';
import 'studio_prompt_text.dart';
import 'studio_stage_brief.dart';
import 'studio/studio_brief_macro_renderer.dart';
import 'studio/studio_history_limiter.dart';
import 'studio/studio_runtime_block_expander.dart';

/// Builds the per-agent, batch, and final-generator message lists for the
/// Studio chat-time pipeline. Extracted from `MemoryStudioService` (plan §2.7).
///
/// Thin orchestrator — delegates block expansion to [StudioRuntimeBlockExpander],
/// history trimming to [StudioHistoryLimiter], and brief-macro rendering to
/// [StudioBriefMacroRenderer]. Constructor signature preserved for test compat.
class StudioMessageBuilder {
  final StudioContextBucketizer _bucketizer;
  final StudioPromptText _promptText;
  final StudioBriefDeduper _briefDeduper;
  late final StudioBriefMacroRenderer _briefMacroRenderer =
      StudioBriefMacroRenderer(_briefDeduper);
  late final StudioRuntimeBlockExpander _blockExpander =
      StudioRuntimeBlockExpander(_briefMacroRenderer);

  StudioMessageBuilder(this._bucketizer, this._promptText, this._briefDeduper);

  /// Build the message list for a single agent run (pre-gen tracker,
  /// post-processing tracker, or final generator). [mainResponse] non-empty
  /// marks a post-processing tracker (Feature 6): the generator's reply is
  /// appended as an `<assistant_response>` block at the END of the list so
  /// the tracker can rewrite it.
  List<Map<String, dynamic>> buildAgentMessages({
    required StudioAgent agent,
    required PromptResult promptResult,
    required PromptPayload promptPayload,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required List<StudioStageBrief> priorBriefs,
    required bool isFinalResponse,
    String mainResponse = '',
    int finalContextOverride = 0,
    int reasoningHistoryCount = 0,
  }) {
    final context = _bucketizer.bucketize(
      promptResult,
      promptPayload: promptPayload,
      studioConfig: config,
    );
    final section = _blockExpander.sectionForRun(agent, isFinalResponse);
    final blocks =
        studioPreset.blocks
            .where((b) => b.enabled && b.section == section)
            .where((b) => !_blockExpander.isRuntimeComputedBlock(b))
            .where(
              (b) =>
                  _blockExpander.blockAppliesToAgent(b, agent, isFinalResponse),
            )
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    final hasExplicitBriefMacros =
        isFinalResponse &&
        blocks.any((b) => _briefMacroRenderer.hasStudioBriefMacro(b.content));
    final messages = <Map<String, dynamic>>[];

    for (final block in blocks) {
      switch (block.kind) {
        case 'agent_instruction':
          final control = StringBuffer();
          control.writeln(
            _blockExpander
                .expandStudioBlockContent(
                  block.content,
                  promptPayload: promptPayload,
                  promptResult: promptResult,
                  context: context,
                  priorBriefs: priorBriefs,
                  config: config,
                )
                .trim(),
          );
          if (!isFinalResponse) {
            control
              ..writeln()
              ..writeln(_promptText.intermediateRuntimeEnvelope(agent));
          }
          if (isFinalResponse &&
              (hasExplicitBriefMacros || priorBriefs.isNotEmpty)) {
            control
              ..writeln()
              ..writeln(_promptText.finalBriefUsageNote());
          }
          if (isFinalResponse) {
            final styleContract = _promptText.finalHardStyleContract(config);
            if (styleContract.isNotEmpty) {
              control
                ..writeln()
                ..writeln(styleContract);
            }
          }
          final controlText = control.toString().trim();
          if (controlText.isNotEmpty) {
            messages.add({
              'role': _blockExpander.normalizeInstructionRole(
                block.role.isNotEmpty ? block.role : agent.role,
              ),
              'content': controlText,
            });
          }
          break;
        case 'previous_agents':
          if (!isFinalResponse) break;
          if (hasExplicitBriefMacros) break;
          final sanitized = priorBriefs
              .where((b) => b.brief.trim().isNotEmpty)
              .map((b) => _briefDeduper.sanitizePriorBriefForFinal(b, config))
              .toList();
          final deduped = _briefDeduper.dedupePriorBriefs(sanitized);
          messages.addAll(
            deduped
                .where((b) => b.brief.trim().isNotEmpty)
                .map(
                  (b) => {
                    'role': _blockExpander.normalizeInstructionRole(block.role),
                    'content': 'Studio agent brief: ${b.agentName}\n${b.brief}',
                  },
                ),
          );
          break;
        case 'static_context':
          messages.addAll(context.staticContext.map((m) => m.toApiMap()));
          break;
        case 'chat_history':
          final history = isFinalResponse
              ? StudioHistoryLimiter.limitFinalHistory(
                  context.history,
                  config,
                  pipelineOverride: finalContextOverride,
                  reasoningHistoryCount: reasoningHistoryCount,
                )
              : StudioHistoryLimiter.limitTrackerHistory(
                  context.history,
                  agent.contextSize,
                );
          if (isFinalResponse &&
              (reasoningHistoryCount == -1 || reasoningHistoryCount > 0)) {
            messages.addAll(
              _historyWithReasoning(history, reasoningHistoryCount),
            );
          } else {
            messages.addAll(history.map((m) => m.toApiMap()));
          }
          break;
        case 'dynamic_context':
          messages.addAll(context.dynamicContext.map((m) => m.toApiMap()));
          break;
        default:
          final promptMessages = context.messagesForKind(block.kind);
          if (promptMessages.isNotEmpty) {
            messages.addAll(promptMessages.map((m) => m.toApiMap()));
            break;
          }
          final content = _blockExpander
              .expandStudioBlockContent(
                block.content,
                promptPayload: promptPayload,
                promptResult: promptResult,
                context: context,
                priorBriefs: priorBriefs,
                config: config,
              )
              .trim();
          if (content.isNotEmpty) {
            messages.add({
              'role': _blockExpander.normalizeInstructionRole(block.role),
              'content': content,
            });
          }
      }
    }

    // Feature 6 — post-processing trackers receive the generator's response
    // as an `<assistant_response>` block appended at the END of the message
    // list.
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

  List<Map<String, dynamic>> _historyWithReasoning(
    List<PromptMessage> history,
    int reasoningHistoryCount,
  ) {
    final messages = history
        .map<Map<String, dynamic>>((message) => message.toApiMap())
        .toList();
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
        messages[i]['reasoning_content'] = reasoning;
        if (!includeAll) remaining--;
      }
    }
    return messages;
  }

  /// Shared messages for a batch: `static_context` + `dynamic_context` +
  /// `chat_history` (trimmed to [batchContextSize]).
  List<Map<String, dynamic>> buildSharedBatchMessages({
    required StudioConfig config,
    required StudioContextBuckets context,
    required PromptPayload promptPayload,
    required PromptResult promptResult,
    required int batchContextSize,
  }) {
    final messages = <Map<String, dynamic>>[];
    messages.addAll(context.staticContext.map((m) => m.toApiMap()));
    messages.addAll(context.dynamicContext.map((m) => m.toApiMap()));
    final history = StudioHistoryLimiter.limitTrackerHistory(
      context.history,
      batchContextSize,
    );
    messages.addAll(history.map((m) => m.toApiMap()));
    return messages;
  }

  /// Per-agent task text: the agent's `promptShard` + the preset's
  /// `agent_instruction` block content + the runtime envelope.
  String buildPerAgentTaskText({
    required StudioAgent agent,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required PromptResult promptResult,
    required PromptPayload promptPayload,
    required StudioContextBuckets context,
  }) {
    final blocks =
        studioPreset.blocks
            .where((b) => b.enabled && b.section == 'pregen')
            .where(
              (b) =>
                  b.kind == 'agent_instruction' ||
                  (b.kind == 'tracker_instruction' &&
                      _blockExpander.trackerInstructionAppliesToAgent(
                        b,
                        agent,
                      )),
            )
            .where((b) => !_blockExpander.isRuntimeComputedBlock(b))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    final buf = StringBuffer();
    for (final block in blocks) {
      final content = _blockExpander
          .expandStudioBlockContent(
            block.content,
            promptPayload: promptPayload,
            promptResult: promptResult,
            context: context,
          )
          .trim();
      if (content.isNotEmpty) {
        buf.writeln(content);
        buf.writeln();
      }
    }
    buf.writeln(_promptText.intermediateRuntimeEnvelope(agent));
    return buf.toString().trim();
  }

  /// Role text for the `<role>` element: the shared role/instruction text
  /// from the preset's non-`agent_instruction` blocks.
  String batchRoleText(
    StudioConfig config,
    StudioPreset studioPreset,
    StudioContextBuckets context,
    PromptPayload promptPayload,
    PromptResult promptResult,
  ) {
    final blocks =
        studioPreset.blocks
            .where((b) => b.enabled && b.section == 'pregen')
            .where((b) => b.kind != 'agent_instruction')
            .where((b) => b.kind != 'tracker_instruction')
            .where((b) => !_blockExpander.isRuntimeComputedBlock(b))
            .where((b) => b.kind != 'static_context')
            .where((b) => b.kind != 'chat_history')
            .where((b) => b.kind != 'dynamic_context')
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    final buf = StringBuffer();
    for (final block in blocks) {
      final promptMessages = context.messagesForKind(block.kind);
      if (promptMessages.isNotEmpty) {
        for (final m in promptMessages) {
          if (m.content.isNotEmpty) buf.writeln(m.content);
        }
        continue;
      }
      final content = _blockExpander
          .expandStudioBlockContent(
            block.content,
            promptPayload: promptPayload,
            promptResult: promptResult,
            context: context,
          )
          .trim();
      if (content.isNotEmpty) {
        buf.writeln(content);
      }
    }
    return buf.toString().trim();
  }
}
