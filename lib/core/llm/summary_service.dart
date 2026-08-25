import 'package:dio/dio.dart';

import '../db/repositories/summary_repo.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import 'aux_llm_client.dart';
import 'macro_engine.dart';
import 'transport/llm_protocol.dart';
import 'transport/llm_capture_context.dart';

/// Prompt used when a session has no custom summarization prompt. Exposed so
/// the editor can show it as the placeholder for an empty field.
const defaultSummaryPrompt =
    'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n';

/// Placeholder replaced with the formatted transcript. Substituted *after*
/// macro expansion so nothing inside the transcript is treated as a macro.
const summaryHistoryPlaceholder = '{{history}}';

/// Fallback generation budget when the API config carries no `maxTokens`.
const _fallbackMaxTokens = 1024;

/// Fallback idle timeout when the API config carries no `firstChunkTimeoutMs`.
const _fallbackTimeoutMs = 60000;

class SummaryService {
  final SummaryRepo _repo;
  final AuxLlmClient _llm;

  SummaryService(this._repo, {AuxLlmClient? llm})
    : _llm = llm ?? const AuxLlmClient();

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

  /// Session's custom summarization prompt, or null when it uses the built-in
  /// [defaultSummaryPrompt]. A blank stored value counts as unset.
  Future<String?> getSummaryPrompt(String sessionId) async {
    final prompt = (await _repo.get(sessionId))?.prompt;
    if (prompt == null || prompt.trim().isEmpty) return null;
    return prompt;
  }

  /// Persists a manually-edited summary. Empty content clears it. This is the
  /// same store the prompt builder reads ([getSummary]), so manual edits are
  /// injected exactly like generated ones.
  ///
  /// [prompt] is the session's summarization template; pass an empty string to
  /// fall back to [defaultSummaryPrompt], or null to leave it untouched.
  Future<void> setSummary({
    required String sessionId,
    required String content,
    required int messageCount,
    String? prompt,
  }) async {
    final trimmed = content.trim();
    await _repo.put(
      sessionId: sessionId,
      content: trimmed,
      messageCount: messageCount,
      prompt: prompt,
    );
  }

  Future<void> setSummaryEnabled({
    required String sessionId,
    required bool enabled,
  }) {
    return _repo.setEnabled(sessionId: sessionId, enabled: enabled);
  }

  Future<int> getSummaryMessageCount(String sessionId) async {
    final row = await _repo.get(sessionId);
    return row?.messageCount ?? 0;
  }

  /// Generates a summary for [history] through [apiConfig] and persists it.
  ///
  /// The call goes through [AuxLlmClient] so every protocol the app supports
  /// works here: URL shape, auth header, request body and response parsing all
  /// come from the protocol's `ChatTransport`. This used to be a hand-rolled
  /// OpenAI Chat Completions POST, which silently failed on Anthropic, Gemini
  /// and OpenRouter configs.
  ///
  /// Non-streaming (INV-S1): the transport is called with `stream: false`.
  ///
  /// [customPrompt] is persisted verbatim (as a template); [macroContext]
  /// only affects what is sent to the model.
  Future<String> generateSummary({
    required String sessionId,
    required List<ChatMessage> history,
    required ApiConfig apiConfig,
    String? customPrompt,
    MacroContext? macroContext,
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

    final prompt = buildSummaryPrompt(
      history: history,
      template: customPrompt,
      macroContext: macroContext,
    );

    final content = await _llm.callOnce(
      config: AuxApiConfig(
        endpoint: apiConfig.endpoint,
        apiKey: apiConfig.apiKey,
        model: apiConfig.model,
        protocol: apiConfig.protocol,
        useResponsesApi: apiConfig.useResponsesApi,
        extraRequestParameters: apiConfig.extraRequestParameters,
      ),
      prompt: prompt,
      maxTokens: apiConfig.maxTokens > 0
          ? apiConfig.maxTokens
          : _fallbackMaxTokens,
      temperature: 0.3,
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
    await _repo.put(
      sessionId: sessionId,
      content: trimmed,
      messageCount: history.length,
      prompt: customPrompt,
    );

    return trimmed;
  }

  /// Builds the summarization prompt.
  ///
  /// Order matters: macros in [template] are expanded first (so `{{char}}`,
  /// `{{user}}`, `{{getvar::…}}` and friends work in a user-written prompt),
  /// and only then is `{{history}}` swapped for the transcript. Doing it the
  /// other way round would run the macro engine over the chat log itself and
  /// rewrite whatever `{{…}}` the roleplay happens to contain.
  ///
  /// A template without `{{history}}` gets the transcript appended, which is
  /// how the built-in prompt works.
  String buildSummaryPrompt({
    required List<ChatMessage> history,
    String? template,
    MacroContext? macroContext,
  }) {
    var resolved = (template == null || template.trim().isEmpty)
        ? defaultSummaryPrompt
        : template;
    if (macroContext != null) {
      resolved = replaceMacros(resolved, macroContext).text;
    }
    final historyText = _formatHistory(history);
    if (resolved.contains(summaryHistoryPlaceholder)) {
      return resolved.replaceAll(summaryHistoryPlaceholder, historyText);
    }
    return '$resolved\n\n$historyText';
  }

  Future<void> deleteSummary(String sessionId) async {
    await _repo.deleteBySessionId(sessionId);
  }

  bool needsRegeneration(int currentMessageCount, int? savedCount) {
    if (savedCount == null || savedCount == 0) return true;
    final threshold = (savedCount * 0.3).ceil();
    return currentMessageCount - savedCount >= threshold &&
        currentMessageCount > 10;
  }

  String _formatHistory(List<ChatMessage> messages) {
    final buf = StringBuffer();
    for (final msg in messages) {
      if (msg.role == 'user' || msg.role == 'assistant') {
        final speaker = msg.role == 'user' ? 'User' : 'Character';
        // The ledger-stamped game clock travels with the transcript so the
        // summary stays time-anchored instead of teleporting across hours.
        final gameTime = msg.time?.trim();
        final timePrefix = gameTime == null || gameTime.isEmpty
            ? ''
            : '[$gameTime] ';
        buf.writeln('$speaker: $timePrefix${msg.content}');
      }
    }
    return buf.toString();
  }
}
