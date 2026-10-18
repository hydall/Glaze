import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/game_time.dart';
import '../../../core/llm/macro_engine.dart';
import '../../../core/llm/memory_book_api_config_resolver.dart';
import '../../../core/llm/transport/llm_protocol.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book_api_settings.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/summary_providers.dart';
import '../../settings/api_list_provider.dart';

final summaryGenerationServiceProvider = Provider<SummaryGenerationService>(
  (ref) => SummaryGenerationService(ref),
);

/// Resolves everything a summary run needs from the provider layer — the API
/// connection, character, persona, the session's stored prompt template and the
/// macro context — and hands it to the provider-free `SummaryService`.
///
/// Shared by the Memory sheet's "Summarize" button, the auto-summary stage and
/// `ChatActionsService`, so all three produce identical prompts.
///
/// The connection is the Memory slot's (`PipelineSettings.memoryBookApi`), the
/// same one memory drafts run on: both are the same kind of work — a small
/// model reading the transcript and writing prose about it — and a reader who
/// picks a cheap connection for one means it for the other. The slot falls
/// back to the active chat connection when it names none, which is what every
/// summary used to run on. Whatever it resolves to, the request goes out
/// through that connection's own chat protocol.
class SummaryGenerationService {
  final Ref _ref;

  const SummaryGenerationService(this._ref);

  /// Generates and persists the summary for [session]. Throws when no usable
  /// chat API config exists, or whatever the transport throws on failure.
  Future<String> generate({
    required String charId,
    required ChatSession session,
    CancelToken? cancelToken,
  }) async {
    final slot = _ref.read(pipelineSettingsProvider).memoryBookApi;
    final apiConfig = await _resolveConfig(slot);
    if (apiConfig == null || apiConfig.mode == 'embedding') {
      throw Exception(
        'No chat API config found. Add one in API Settings first.',
      );
    }

    final service = _ref.read(summaryServiceProvider);
    final template = await service.getSummaryPrompt(session.id);

    final gameTime = await _readGameTime(session.id);
    return service.generateSummary(
      sessionId: session.id,
      history: session.messages,
      apiConfig: apiConfig,
      customPrompt: template,
      // Only when the slot pins one. Summarizing stays at its own low default
      // otherwise: a hot summariser invents facts.
      temperature: slot.generationTemperature,
      macroContext: _macroContext(
        charId: charId,
        session: session,
        gameTime: gameTime,
      ),
      cancelToken: cancelToken,
    );
  }

  /// The Memory slot's connection, as one [ApiConfig] the summary can run on:
  /// the saved connection with the slot's model and output cap folded in, or —
  /// on the custom-endpoint branch — the endpoint the slot carries itself.
  Future<ApiConfig?> _resolveConfig(MemoryBookApiSettings slot) async {
    if (slot.generationSource == 'custom') {
      if (slot.generationEndpoint.isEmpty || slot.generationModel.isEmpty) {
        return null;
      }
      return ApiConfig(
        id: 'memory-slot-custom',
        endpoint: slot.generationEndpoint,
        apiKey: slot.generationApiKey,
        model: slot.generationModel,
        protocol: LlmProtocol.customChatCompletion,
        maxTokens: slot.generationMaxTokens ?? 0,
      );
    }
    // apiListProvider can still be loading on a cold start; the active config
    // the slot falls back to reads null until it resolves.
    await _ref.read(apiListProvider.future);
    final resolver = MemoryBookApiConfigResolver(
      apiConfigs: _ref.read(apiListProvider).value ?? const [],
      activeConfig: _ref.read(activeApiConfigProvider),
    );
    final config = resolver.resolve(slot);
    if (config == null) return null;
    return config.copyWith(
      model: slot.generationModel.isNotEmpty
          ? slot.generationModel
          : config.model,
      maxTokens: MemoryBookApiConfigResolver.maxTokensFor(slot, config),
    );
  }

  Future<GameTimeState> _readGameTime(String sessionId) async {
    try {
      final trackers = await _ref
          .read(trackerRepoProvider)
          .getBySessionAndScope(sessionId, 'ledger');
      return GameTimeState.fromTrackers(trackers);
    } catch (_) {
      return const GameTimeState();
    }
  }

  MacroContext _macroContext({
    required String charId,
    required ChatSession session,
    GameTimeState gameTime = const GameTimeState(),
  }) {
    final character = _ref.read(characterByIdProvider(charId));
    final persona = _ref.read(
      effectivePersonaForChatProvider((charId: charId, sessionId: session.id)),
    );
    return MacroContext(
      charName: character?.name ?? 'Character',
      charDescription: character?.description,
      charScenario: character?.scenario,
      charPersonality: character?.personality,
      charMesExample: character?.mesExample,
      macroName: character?.macroName,
      userName: persona?.name ?? 'User',
      personaPrompt: persona?.prompt,
      sessionVars: session.sessionVars,
      globalVars: _ref.read(globalVarsProvider),
      charId: charId,
      sessionId: session.id,
      gameTime: gameTime.time,
      gameDate: gameTime.date,
      gameDay: gameTime.day?.toString(),
    );
  }
}
