import 'package:dio/dio.dart';

import '../db/app_db.dart' as db;
import '../db/repositories/summary_repo.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/summary_block.dart';
import 'aux_llm_client.dart';
import 'macro_engine.dart';
import 'tokenizer.dart';
import 'transport/llm_protocol.dart';
import 'transport/llm_capture_context.dart';

/// Prompt used when a session has no custom summarization prompt. Exposed so
/// the editor can show it as the placeholder for an empty field.
const defaultSummaryPrompt =
    'You are given one part of a long roleplay. Summarize it so the story '
    'can continue from your summary in place of these messages. Write in the '
    'language the roleplay is written in.\n'
    'Keep:\n'
    '- events in the order they happened, and what caused them;\n'
    '- changes in relationships and in what characters know, want or feel;\n'
    '- important items: who has them, where they are, what state they are '
    'in;\n'
    '- where characters are and what condition they are in;\n'
    '- promises, plans and dangers that are still open;\n'
    '- facts about the world the story established.\n'
    'Keep proper names and established terms exactly as written. When '
    'something changed, keep the outcome and what caused it, not every step. '
    'Add nothing the messages do not say; when something is unclear, say so '
    'instead of guessing. No preamble.';

/// Built-in prompts this one replaced. Picking the built-in preset stores its
/// text, so a session holding one of these is on the built-in prompt and
/// moves to the current one.
const _replacedDefaultSummaryPrompts = {
  'Summarize the following part of a roleplay conversation concisely, in '
      'the language it is written in: key events in order, decisions, changes '
      'in relationships, and what is still unresolved. Keep proper names '
      'exactly as they appear.',
};

/// Placeholder replaced with the formatted transcript. Substituted *after*
/// macro expansion so nothing inside the transcript is treated as a macro.
///
/// A template that places it lays out the whole request itself, so it is sent
/// as one user message. Without it the template is the system message and the
/// material goes in the user message.
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

/// Heading the transcript goes under in the user message.
const summaryTranscriptHeader = 'Transcript to summarize:';

/// Placeholder replaced, in a merge prompt, with the level of the block the
/// merge makes — one above its parts.
const summaryLevelPlaceholder = '{{level}}';

String summaryLengthHint(int targetTokens) =>
    'Keep it under about $targetTokens tokens.';

/// How far past its target a block may come out before it is sent back to be
/// shortened, in percent of the target.
const summaryShortenSlackPercent = 125;

/// Fallback idle timeout when the API config carries no `firstChunkTimeoutMs`.
const _fallbackTimeoutMs = 120000;

/// Temperature a summary runs at unless the connection's slot pins one.
/// Summarizing is extraction, not prose — a hot summariser invents facts.
const kSummaryDefaultTemperature = 0.3;

/// Instruction for merging adjacent blocks into one a level up. Built in: it
/// is about keeping continuity through a merge, which a reader's template for
/// retelling messages does not cover.
const summaryMergePrompt =
    'You are given consecutive parts of the summary of one roleplay, oldest '
    'first. Merge them into a single summary, in the language they are '
    'written in.\n'
    '- Keep the order in which things happened.\n'
    '- State a fact once, even when several parts repeat it.\n'
    '- Keep earlier facts that are still true, not only the latest part.\n'
    '- When a later part changes what an earlier one established, keep the '
    'outcome and, briefly, what caused it. When the parts contradict each '
    'other without a change in the story, say the matter is unclear.\n'
    '- Retell finished events by their outcome and what they left behind.\n'
    '- Keep goals, promises and dangers that are still open. Never present a '
    'thread that was resolved as open again.\n'
    '- Keep proper names and established terms exactly as written.\n'
    '- Add nothing that the parts do not say. No preamble.';

/// Instruction for a block that came out well past its target. Sent once; the
/// shorter of the two texts is kept. The built-in default of
/// `SummaryShortenPromptPresets`.
const summaryShortenPrompt =
    'The summary you are given came out longer than it should. Shorten it '
    'without changing facts, their order, names or established terms, and '
    'keep the language it is written in. Cut repetition and wording first; '
    'cut continuity last. Keep what is still open and the causes of changes. '
    'No preamble.';

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
  /// [defaultSummaryPrompt]. A blank stored value counts as unset, and so does
  /// an earlier built-in one.
  Future<String?> getSummaryPrompt(String sessionId) async {
    final prompt = (await _repo.get(sessionId))?.prompt;
    final text = prompt?.trim() ?? '';
    if (text.isEmpty || _replacedDefaultSummaryPrompts.contains(text)) {
      return null;
    }
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
  Future<List<SummaryBlock>> getBlocks(String sessionId) async =>
      _blocksOf(await _repo.get(sessionId));

  static List<SummaryBlock> _blocksOf(db.ChatSummary? row) {
    if (row == null) return const [];
    if (row.blocksJson != null) return SummaryBlock.decodeList(row.blocksJson);
    final legacy = row.content.trim();
    if (legacy.isEmpty) return const [];
    return [
      SummaryBlock(
        id: SummaryBlock.legacyNoteId,
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
      content: SummaryChain.render(SummaryChain.inPrompt(blocks, messages)),
      messageCount: messages.length,
    );
  }

  /// Applies [change] to the blocks as stored now and writes the result, in
  /// one transaction (`docs/rules/database.md`). A null from [change] writes
  /// nothing. Returns whether anything was written.
  Future<bool> mutateBlocks({
    required String sessionId,
    required List<ChatMessage> messages,
    required List<SummaryBlock>? Function(List<SummaryBlock> blocks) change,
  }) => _repo.mutateBlocks(
    sessionId: sessionId,
    messageCount: messages.length,
    mutate: (row) {
      final next = change(_blocksOf(row));
      if (next == null) return null;
      return (
        blocksJson: SummaryBlock.encodeList(next),
        content: SummaryChain.render(SummaryChain.inPrompt(next, messages)),
      );
    },
  );

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
  /// context. [customPrompt] is the session's template; [shortenTemplate]
  /// the chosen shortening prompt.
  Future<String> summarizeMessages({
    required String sessionId,
    required List<ChatMessage> source,
    required ApiConfig apiConfig,
    required int targetTokens,
    String? earlierSummary,
    String? customPrompt,
    String? shortenTemplate,
    MacroContext? macroContext,
    CancelToken? cancelToken,
    double? temperature,
  }) {
    return _summarize(
      sessionId: sessionId,
      apiConfig: apiConfig,
      targetTokens: targetTokens,
      temperature: temperature,
      cancelToken: cancelToken,
      shortenTemplate: shortenTemplate,
      messages: buildSummaryMessages(
        history: source,
        template: customPrompt,
        macroContext: macroContext,
        previousSummary: earlierSummary,
        targetTokens: targetTokens,
      ),
    );
  }

  /// Merges [parts] — adjacent blocks of one level, in story order — into the
  /// text of one block a level up. Persists nothing. [template] is the chosen
  /// merge prompt; [summaryMergePrompt] when absent. [shortenTemplate] is the
  /// chosen shortening prompt.
  Future<String> mergeBlocks({
    required String sessionId,
    required List<SummaryBlock> parts,
    required ApiConfig apiConfig,
    required int targetTokens,
    String? template,
    String? shortenTemplate,
    CancelToken? cancelToken,
    double? temperature,
  }) {
    return _summarize(
      sessionId: sessionId,
      apiConfig: apiConfig,
      targetTokens: targetTokens,
      temperature: temperature,
      cancelToken: cancelToken,
      shortenTemplate: shortenTemplate,
      messages: buildMergeMessages(
        parts: parts,
        targetTokens: targetTokens,
        template: template,
      ),
    );
  }

  /// One summarizer call, and one more to shorten its answer when it came out
  /// well past [targetTokens]. The shorter text is kept; a failed shortening,
  /// or one the model refused — shorter than anything — keeps the first
  /// answer, which is complete.
  Future<String> _summarize({
    required String sessionId,
    required ApiConfig apiConfig,
    required List<Map<String, String>> messages,
    required int targetTokens,
    String? shortenTemplate,
    double? temperature,
    CancelToken? cancelToken,
  }) async {
    final text = await _call(
      sessionId: sessionId,
      apiConfig: apiConfig,
      messages: messages,
      targetTokens: targetTokens,
      temperature: temperature,
      cancelToken: cancelToken,
    );
    final tokens = estimateTokens(text);
    if (tokens * 100 <= targetTokens * summaryShortenSlackPercent) return text;
    try {
      final shorter = await _call(
        sessionId: sessionId,
        apiConfig: apiConfig,
        messages: buildShortenMessages(
          text: text,
          targetTokens: targetTokens,
          template: shortenTemplate,
        ),
        targetTokens: targetTokens,
        temperature: temperature,
        cancelToken: cancelToken,
      );
      return estimateTokens(shorter) < tokens ? shorter : text;
    } catch (_) {
      if (cancelToken?.isCancelled == true) rethrow;
      return text;
    }
  }

  Future<String> _call({
    required String sessionId,
    required ApiConfig apiConfig,
    required List<Map<String, String>> messages,
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
      messages: messages,
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

  /// Builds the request for retelling one run of messages.
  ///
  /// Order matters: macros in [template] are expanded first (so `{{char}}`,
  /// `{{user}}`, `{{getvar::…}}` and friends work in a user-written prompt),
  /// and only then is the transcript put in. Doing it the other way round
  /// would run the macro engine over the chat log itself and rewrite whatever
  /// `{{…}}` the roleplay happens to contain.
  ///
  /// The template is the system message; the earlier summary, under
  /// [summaryPreviousHeader], and the transcript go in the user message. A
  /// template that places `{{history}}` lays out the request itself and is
  /// sent as one user message. `{{previous_summary}}` puts the earlier summary
  /// where the template wants it instead.
  List<Map<String, String>> buildSummaryMessages({
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
    }
    final transcript = _formatHistory(history, macroContext);
    if (resolved.contains(summaryHistoryPlaceholder)) {
      return [
        {
          'role': 'user',
          'content': resolved.replaceAll(summaryHistoryPlaceholder, transcript),
        },
      ];
    }
    final material = StringBuffer();
    if (!placed && previous.isNotEmpty) {
      material
        ..writeln(summaryPreviousHeader)
        ..writeln(previous)
        ..writeln();
    }
    material
      ..writeln(summaryTranscriptHeader)
      ..write(transcript);
    return [
      {'role': 'system', 'content': resolved.trim()},
      {'role': 'user', 'content': material.toString().trimRight()},
    ];
  }

  /// The merge request: [template] (or [summaryMergePrompt]) as the system
  /// message, with `{{level}}` filled, `{{target_tokens}}` filled or the length
  /// hint appended, and the parts in order as the user message.
  List<Map<String, String>> buildMergeMessages({
    required List<SummaryBlock> parts,
    required int targetTokens,
    String? template,
  }) {
    var instructions = (template == null || template.trim().isEmpty)
        ? summaryMergePrompt
        : template.trim();
    final level = (parts.firstOrNull?.level ?? 1) + 1;
    instructions = instructions.replaceAll(summaryLevelPlaceholder, '$level');
    instructions = instructions.contains(summaryTargetPlaceholder)
        ? instructions.replaceAll(summaryTargetPlaceholder, '$targetTokens')
        : '$instructions\n${summaryLengthHint(targetTokens)}';
    final buffer = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) buffer.writeln();
      buffer
        ..writeln('Part ${i + 1}:')
        ..writeln(parts[i].content.trim());
    }
    return [
      {'role': 'system', 'content': instructions},
      {'role': 'user', 'content': buffer.toString().trimRight()},
    ];
  }

  /// The shortening request: [template] (or [summaryShortenPrompt]) as the
  /// system message, with `{{target_tokens}}` filled or the length hint
  /// appended, and the oversized block as the user message.
  List<Map<String, String>> buildShortenMessages({
    required String text,
    required int targetTokens,
    String? template,
  }) {
    final instructions = (template == null || template.trim().isEmpty)
        ? summaryShortenPrompt
        : template.trim();
    return [
      {
        'role': 'system',
        'content': instructions.contains(summaryTargetPlaceholder)
            ? instructions.replaceAll(summaryTargetPlaceholder, '$targetTokens')
            : '$instructions\n${summaryLengthHint(targetTokens)}',
      },
      {'role': 'user', 'content': text.trim()},
    ];
  }

  Future<void> deleteSummary(String sessionId) async {
    await _repo.deleteBySessionId(sessionId);
  }

  /// One line per message, under the speaker's name: the persona a user
  /// message was written as, else the chat's persona, and the character.
  String _formatHistory(List<ChatMessage> messages, MacroContext? context) {
    final user = _name(context?.userName, 'User');
    final char = _name(context?.charName, 'Character');
    final buf = StringBuffer();
    for (final msg in messages) {
      if (msg.role == 'user') {
        buf.writeln('${_name(msg.personaName, user)}: ${msg.content}');
      } else if (msg.role == 'assistant') {
        buf.writeln('$char: ${msg.content}');
      }
    }
    return buf.toString();
  }

  static String _name(String? name, String fallback) {
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? fallback : trimmed;
  }
}
