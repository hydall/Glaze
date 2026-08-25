import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/game_time.dart';
import '../../../core/llm/macro_engine.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/summary_providers.dart';
import '../../settings/api_list_provider.dart';

final summaryGenerationServiceProvider = Provider<SummaryGenerationService>(
  (ref) => SummaryGenerationService(ref),
);

/// Resolves everything a summary run needs from the provider layer — chat API
/// config, character, persona, the session's stored prompt template and the
/// macro context — and hands it to the provider-free `SummaryService`.
///
/// Shared by the Memory sheet's "Summarize" button, the auto-summary stage and
/// `ChatActionsService`, so all three produce identical prompts.
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
    // apiListProvider can still be loading on a cold start; activeApiConfig
    // reads null until it resolves.
    await _ref.read(apiListProvider.future);
    final apiConfig = _ref.read(activeApiConfigProvider);
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
      macroContext: _macroContext(
        charId: charId,
        session: session,
        gameTime: gameTime,
      ),
      cancelToken: cancelToken,
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
