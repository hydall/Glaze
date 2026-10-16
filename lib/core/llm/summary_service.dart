import 'package:dio/dio.dart';

import '../db/repositories/summary_repo.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/summary_block.dart';
import 'auxiliary_timed_history.dart';
import 'aux_llm_client.dart';
import 'macro_engine.dart';
import 'tokenizer.dart';
import 'transport/llm_protocol.dart';
import 'transport/llm_capture_context.dart';

/// Prompt used when a session has no custom summarization prompt. Exposed so
/// the editor can show it as the placeholder for an empty field.
const defaultSummaryPrompt =
    'Summarize the following part of a roleplay conversation concisely, in '
    'the language it is written in: key events in order, decisions, changes '
    'in relationships, and what is still unresolved. Keep proper names '
    'exactly as they appear.\n\n';

/// Placeholder replaced with the formatted transcript. Substituted *after*
/// macro expansion so nothing inside the transcript is treated as a macro.
const summaryHistoryPlaceholder = '{{history}}';

/// Placeholder replaced with the summary of what came before this part. A
/// template that uses it decides where it goes; one that does not gets the
/// block below in front of the transcript.
const summaryPreviousPlaceholder = '{{previous_summary}}';

/// Placeholder replaced with the block's size target in tokens. A template
/// without it gets [summaryLengthHint] appended instead.
const summaryTargetPlaceholder = '{{target_tokens}}';

/// Heading the earlier summary is handed over under when the template does
/// not place it itself. Each block retells only its own messages, so the
/// earlier ones are context — who is who, what a name refers to — and must
/// not be retold again.
const summaryPreviousHeader =
    'Story so far, for context only. Do not retell it; summarize only the '
    'transcript below.';

String summaryLengthHint(int targetTokens) =>
    'Keep it under about $targetTokens tokens.';

/// Fallback idle timeout when the API config carries no `firstChunkTimeoutMs`.
const _fallbackTimeoutMs = 120000;

/// Temperature a summary runs at unless the connection's slot pins one.
/// Summarizing is extraction, not prose — a hot summariser invents facts.
const kSummaryDefaultTemperature = 0.3;

/// Instruction for merging adjacent blocks into one a level up. Built in: it
/// is about keeping continuity through a merge, which a reader's template for
/// retelling messages does not cover.
const summaryMergePrompt =
    'Below are consecutive parts of the summary of one roleplay, oldest '
    'first. Merge them into a single summary, in the language they are '
    'written in.\n'
    '- Keep the order in which things happened.\n'
    '- State a fact once, even when several parts repeat it.\n'
    '- When a later part changes what an earlier one established, keep the '
    'outcome and, briefly, what caused it.\n'
    '- Keep goals, promises and dangers that are still open. Never present a '
    'thread that was resolved as open again.\n'
    '- Keep proper names and established terms exactly as written.\n'
    '- Add nothing that the parts do not say. No preamble.';

class SummaryService {
  final SummaryRepo _repo;
  final AuxLlmClient _llm;

  SummaryService(this._repo, {AuxLlmClient? llm})
    : _llm = llm ?? const AuxLlmClient();

  /// The summary text, or null when the session has it switched off. Rendered
  /// from the active blocks without checking their sources — prompt assembly
  /// uses [getPromptView], which does.
  Future<String?> getSummary(String sessionId) async {
    final row = await _repo.get(sessionId);
    if (row == null || !row.enabled) return null;
    return row.content;
  }

  Future<String?> getSummaryContent(String sessionId) async {
    final row = await _repo.get(sessionId);
    return row?.content;
  }

  Future<bool> isSummaryEnabled(String sessionId) async {
    final row = await _repo.get(sessionId);
    return row?.enabled ?? true;
  }

  /// Writes only the summarization template. See [SummaryRepo.setPrompt] for
  /// why this is not a full write.
  Future<void> setSummaryPrompt({
    required String sessionId,
    required String? prompt,
  }) {
    final trimmed = prompt?.trim();
    return _repo.setPrompt(
      sessionId: sessionId,
      prompt: trimmed == null || trimmed.isEmpty ? null : prompt,
    );
  }

  /// Session's custom summarization prompt, or null when it uses the built-in
  /// [defaultSummaryPrompt]. A blank stored value counts as unset.
  Future<String?> getSummaryPrompt(String sessionId) async {
    final prompt = (await _repo.get(sessionId))?.prompt;
    if (prompt == null || prompt.trim().isEmpty) return null;
    return prompt;
  }

  Future<void> setSummaryEnabled({
    required String sessionId,
    required bool enabled,
  }) {
    return _repo.setEnabled(sessionId: sessionId, enabled: enabled);
  }

  /// The session's blocks, archive included. A row from before blocks
  /// existed reads as one note holding its text, so an old summary keeps
  /// being sent — it just stands in for no messages.
  Future<List<SummaryBlock>> getBlocks(String sessionId) async {
    final row = await _repo.get(sessionId);
    if (row == null) return const [];
    if (row.blocksJson != null) return SummaryBlock.decodeList(row.blocksJson);
    final legacy = row.content.trim();
    if (legacy.isEmpty) return const [];
    return [
      SummaryBlock(
        id: 'note-legacy',
        level: 0,
        content: legacy,
        tokens: estimateTokens(legacy),
      ),
    ];
  }

  /// Persists [blocks], and the text rendered from the live ones as
  /// `content` for readers that only want text.
  Future<void> saveBlocks({
    required String sessionId,
    required List<SummaryBlock> blocks,
    required List<ChatMessage> messages,
  }) {
    return _repo.putBlocks(
      sessionId: sessionId,
      blocksJson: SummaryBlock.encodeList(blocks),
      content: SummaryChain.render(SummaryChain.live(blocks, messages)),
      messageCount: messages.length,
    );
  }

  /// What the prompt gets: the live blocks' text and the messages they stand
  /// in for. Null when the summary is switched off or empty — then nothing is
  /// sent and no message is left out.
  Future<SummaryPromptView?> getPromptView(
    String sessionId,
    List<ChatMessage> messages,
  ) async {
    final row = await _repo.get(sessionId);
    if (row == null || !row.enabled) return null;
    final view = SummaryChain.promptView(await getBlocks(sessionId), messages);
    return view.content.isEmpty ? null : view;
  }

  /// Retells [source] — one run of messages — as the text of a new level-1
  /// block. Persists nothing; the caller commits the block.
  ///
  /// The call goes through [AuxLlmClient] so every protocol the app supports
  /// works here. Non-streaming (INV-S1).
  ///
  /// [earlierSummary] is the live blocks before this run, handed over as
  /// context. [customPrompt] is the session's template.
  Future<String> summarizeMessages({
    required String sessionId,
    required List<ChatMessage> source,
    required ApiConfig apiConfig,
    required int targetTokens,
    String? earlierSummary,
    String? customPrompt,
    MacroContext? macroContext,
    CancelToken? cancelToken,
    double? temperature,
  }) {
    return _call(
      sessionId: sessionId,
      apiConfig: apiConfig,
      targetTokens: targetTokens,
      temperature: temperature,
      cancelToken: cancelToken,
      prompt: buildSummaryPrompt(
        history: source,
        template: customPrompt,
        macroContext: macroContext,
        previousSummary: earlierSummary,
        targetTokens: targetTokens,
      ),
    );
  }

  /// Merges [parts] — adjacent blocks of one level, in story order — into the
  /// text of one block a level up. Persists nothing.
  Future<String> mergeBlocks({
    required String sessionId,
    required List<SummaryBlock> parts,
    required ApiConfig apiConfig,
    required int targetTokens,
    CancelToken? cancelToken,
    double? temperature,
  }) {
    return _call(
      sessionId: sessionId,
      apiConfig: apiConfig,
      targetTokens: targetTokens,
      temperature: temperature,
      cancelToken: cancelToken,
      prompt: buildMergePrompt(parts: parts, targetTokens: targetTokens),
    );
  }

  Future<String> _call({
    required String sessionId,
    required ApiConfig apiConfig,
    required String prompt,
    required int targetTokens,
    double? temperature,
    CancelToken? cancelToken,
  }) async {
    // OpenRouter's transport hardcodes its base URL and ignores the config's
    // endpoint, so an empty endpoint is legitimate there.
    final endpointRequired = apiConfig.protocol != LlmProtocol.openrouter;
    if (endpointRequired && apiConfig.endpoint.isEmpty) {
      throw Exception('API endpoint not configured');
    }
    if (apiConfig.model.isEmpty) {
      throw Exception('API model not configured');
    }

    final content = await _llm.callOnce(
      config: AuxApiConfig(
        endpoint: apiConfig.endpoint,
        apiKey: apiConfig.apiKey,
        model: apiConfig.model,
        protocol: apiConfig.protocol,
        useResponsesApi: apiConfig.useResponsesApi,
        // The connection's own "no temperature" flag travels with it: the
        // summary pins temperature 0.3, but a provider that rejects the
        // parameter rejects it here too.
        omitTemperature: apiConfig.omitTemperature,
        extraRequestParameters: apiConfig.extraRequestParameters,
      ),
      prompt: prompt,
      // Room for the target with slack; a reasoning model spends part of it
      // before it writes anything.
      maxTokens: apiConfig.maxTokens > 0
          ? apiConfig.maxTokens
          : (targetTokens * 2).clamp(1024, 16384),
      temperature: temperature ?? kSummaryDefaultTemperature,
      timeoutMs: apiConfig.firstChunkTimeoutMs > 0
          ? apiConfig.firstChunkTimeoutMs
          : _fallbackTimeoutMs,
      cancelToken: cancelToken,
      captureContext: LlmCaptureContext(
        stage: 'summary',
        sessionId: sessionId,
        logicalCallId: 'summary:$sessionId',
        relatedArtifactId: sessionId,
      ),
    );
    final trimmed = content.trim();
    if (trimmed.isEmpty) throw Exception('The summarizer returned nothing');
    return trimmed;
  }

  /// Builds the prompt for retelling one run of messages.
  ///
  /// Order matters: macros in [template] are expanded first (so `{{char}}`,
  /// `{{user}}`, `{{getvar::…}}` and friends work in a user-written prompt),
  /// and only then is `{{history}}` swapped for the transcript. Doing it the
  /// other way round would run the macro engine over the chat log itself and
  /// rewrite whatever `{{…}}` the roleplay happens to contain.
  ///
  /// A template without `{{history}}` gets the transcript appended, which is
  /// how the built-in prompt works.
  ///
  /// [previousSummary] is the summary of what came before this run. A
  /// template places it itself with `{{previous_summary}}`; otherwise it is
  /// handed over under [summaryPreviousHeader] between the instructions and
  /// the transcript. An empty or absent one changes nothing about the prompt.
  String buildSummaryPrompt({
    required List<ChatMessage> history,
    String? template,
    MacroContext? macroContext,
    String? previousSummary,
    int? targetTokens,
  }) {
    var resolved = (template == null || template.trim().isEmpty)
        ? defaultSummaryPrompt
        : template;
    if (macroContext != null) {
      resolved = replaceMacros(resolved, macroContext).text;
    }
    if (targetTokens != null) {
      if (resolved.contains(summaryTargetPlaceholder)) {
        resolved = resolved.replaceAll(
          summaryTargetPlaceholder,
          '$targetTokens',
        );
      } else {
        resolved =
            '${resolved.trimRight()}\n${summaryLengthHint(targetTokens)}';
      }
    }
    final previous = previousSummary?.trim() ?? '';
    final placed = resolved.contains(summaryPreviousPlaceholder);
    if (placed) {
      resolved = resolved.replaceAll(summaryPreviousPlaceholder, previous);
    } else if (previous.isNotEmpty) {
      resolved = '$resolved\n\n$summaryPreviousHeader\n$previous';
    }
    final historyText = _formatHistory(history);
    if (resolved.contains(summaryHistoryPlaceholder)) {
      return resolved.replaceAll(summaryHistoryPlaceholder, historyText);
    }
    return '$resolved\n\n$historyText';
  }

  String buildMergePrompt({
    required List<SummaryBlock> parts,
    required int targetTokens,
  }) {
    final buffer = StringBuffer()
      ..writeln(summaryMergePrompt)
      ..writeln(summaryLengthHint(targetTokens));
    for (var i = 0; i < parts.length; i++) {
      buffer
        ..writeln()
        ..writeln('Part ${i + 1}:')
        ..writeln(parts[i].content.trim());
    }
    return buffer.toString().trimRight();
  }

  Future<void> deleteSummary(String sessionId) async {
    await _repo.deleteBySessionId(sessionId);
  }

  String _formatHistory(List<ChatMessage> messages) {
    final buf = StringBuffer();
    for (final msg in messages) {
      if (msg.role == 'user' || msg.role == 'assistant') {
        final speaker = msg.role == 'user' ? 'User' : 'Character';
        // The ledger-stamped game clock travels with the transcript so the
        // summary stays time-anchored instead of teleporting across hours.
        buf.writeln('$speaker: ${auxiliaryTimedContent(msg)}');
      }
    }
    return buf.toString();
  }
}
