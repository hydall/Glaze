import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/character_repo.dart';
import '../../../core/db/repositories/chat_repo.dart';
import '../../../core/llm/prompt/effective_canon_prompt_formatter.dart';
import '../../../core/llm/prompt/effective_canon_prompt_materializer.dart';
import '../../../core/llm/prompt/selective_ledger_projection_filter.dart';
import '../../../core/llm/studio/studio_history_limiter.dart';
import '../../../core/llm/studio/studio_stream_interceptor.dart';
import '../../../core/llm/studio_turn_config_snapshot.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/ledger_prompt_injection_mode.dart';
import '../../../core/models/ledger_prompt_injection_policy.dart';
import '../../../core/services/card_rewriter/effective_canon_context_loader.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../../core/state/studio_turn_config_resolver.dart';
import '../../extensions/services/ext_blocks_prompt_injection.dart';

final class LedgerInjectionModePreview {
  const LedgerInjectionModePreview({required this.mode, required this.value});

  final LedgerPromptInjectionMode mode;
  final EffectiveCanonPromptMaterialization value;
}

final class CurrentLedgerInjectionPreview {
  const CurrentLedgerInjectionPreview({
    required this.sessionId,
    required this.characterId,
    required this.presetId,
    required this.configuredMode,
    required this.generatedAt,
    required this.visibleMessageIds,
    required this.revisionNumber,
    required this.revisionHash,
    required this.legacy,
    required this.gapFiller,
  });

  final String sessionId;
  final String characterId;
  final String presetId;
  final LedgerPromptInjectionMode configuredMode;
  final DateTime generatedAt;
  final List<String> visibleMessageIds;
  final int revisionNumber;
  final String revisionHash;
  final LedgerInjectionModePreview legacy;
  final LedgerInjectionModePreview gapFiller;
}

final class CurrentLedgerInjectionPreviewService {
  const CurrentLedgerInjectionPreviewService(
    this._chatRepo,
    this._characterRepo,
    this._canonLoader,
    this._resolveTurnConfig,
    this._injectHistory,
    this._resolvePersonaName,
  );

  final ChatRepo _chatRepo;
  final CharacterRepo _characterRepo;
  final EffectiveCanonContextLoader _canonLoader;
  final Future<StudioTurnConfigSnapshot> Function(String sessionId)
  _resolveTurnConfig;
  final Future<List<ChatMessage>> Function(
    String sessionId,
    List<ChatMessage> messages,
  )
  _injectHistory;
  final String Function(String characterId, String sessionId)
  _resolvePersonaName;

  Future<CurrentLedgerInjectionPreview> load({
    required String sessionId,
    String? expectedCharacterId,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _loadOnce(
          sessionId: sessionId,
          expectedCharacterId: expectedCharacterId,
        );
      } on _PreviewChanged {
        if (attempt > 0) {
          throw StateError('Chat or canon changed while building the preview.');
        }
      }
    }
  }

  Future<CurrentLedgerInjectionPreview> _loadOnce({
    required String sessionId,
    String? expectedCharacterId,
  }) async {
    final session = await _chatRepo.getById(sessionId);
    if (session == null) throw StateError('Chat session not found.');
    if (expectedCharacterId != null &&
        expectedCharacterId.isNotEmpty &&
        session.characterId != expectedCharacterId) {
      throw StateError('Chat session belongs to another character.');
    }
    final character = await _characterRepo.getById(session.characterId);
    if (character == null) throw StateError('Character not found.');
    final turnConfig = await _resolveTurnConfig(sessionId);
    final preset = turnConfig.preset;
    if (!turnConfig.enabled || preset == null) {
      throw StateError('Studio is not active.');
    }
    final canon = await _canonLoader.loadReadOnly(
      sessionId: sessionId,
      sourceCharacter: character,
    );
    final history = await _injectHistory(sessionId, session.messages);
    final settings = turnConfig.pipelineSettings.studioAgent;
    final finalContextSize = settings.studioFinalContextSize > 0
        ? settings.studioFinalContextSize
        : preset.maxFinalHistoryMessages;
    final visibleIds =
        StudioStreamInterceptor.computeStudioFinalVisibleMessageIds(
          history,
          finalContextSize,
          reasoningHistoryCount: settings.studioFinalReasoningHistoryCount,
          excludeReasoningFromContextBudget:
              settings.studioFinalExcludeReasoningFromContextBudget,
          historyWindowStartMessageId:
              session.sessionVars[StudioHistoryLimiter.historyWindowStartVar],
        );
    final basePolicy = turnConfig.ledgerPromptInjectionPolicy;
    final visible = history
        .where(
          (message) =>
              visibleIds.contains(message.id) &&
              !message.isHidden &&
              !message.isTyping &&
              (message.role == 'user' || message.role == 'assistant'),
        )
        .toList(growable: false);
    final scanStart = visible.length > basePolicy.reverseScanDepth
        ? visible.length - basePolicy.reverseScanDepth
        : 0;
    final selectionWindow = visible.sublist(scanStart);

    final freshSession = await _chatRepo.getById(sessionId);
    final freshCharacter = await _characterRepo.getById(session.characterId);
    final canonIsCurrent =
        freshCharacter != null &&
        await _canonLoader.isStillCurrentReadOnly(
          sessionId: sessionId,
          sourceCharacter: freshCharacter,
          stamp: canon.stamp,
        );
    if (freshSession != session || !canonIsCurrent) {
      throw const _PreviewChanged();
    }

    final projection = EffectiveCanonPromptProjection.fromContext(canon);
    final selectedSwipes = {
      for (final message in selectionWindow) message.id: message.swipeId,
    };
    final focalUserName = _resolvePersonaName(session.characterId, sessionId);
    LedgerInjectionModePreview materialize(LedgerPromptInjectionMode mode) {
      final policy = LedgerPromptInjectionPolicy(
        presetOptIn: basePolicy.presetOptIn,
        mode: mode,
        algorithmVersion: basePolicy.algorithmVersion,
        reverseScanDepth: basePolicy.reverseScanDepth,
      );
      return LedgerInjectionModePreview(
        mode: mode,
        value: EffectiveCanonPromptMaterializer.materializeSafely(
          SelectiveLedgerProjectionInput(
            policy: policy,
            consumerPath: 'studio-final',
            projection: projection,
            visibleMessages: selectionWindow,
            selectedSwipeByMessageId: selectedSwipes,
            focalUserName: focalUserName,
            freshness: LedgerProjectionFreshness.provenCurrent,
          ),
          sessionId: sessionId,
        ),
      );
    }

    return CurrentLedgerInjectionPreview(
      sessionId: sessionId,
      characterId: session.characterId,
      presetId: preset.id,
      configuredMode: basePolicy.effectiveMode,
      generatedAt: DateTime.now(),
      visibleMessageIds: List.unmodifiable(visibleIds),
      revisionNumber: projection.revisionNumber,
      revisionHash: projection.revisionHash,
      legacy: materialize(LedgerPromptInjectionMode.legacy),
      gapFiller: materialize(LedgerPromptInjectionMode.gapFiller),
    );
  }
}

final class _PreviewChanged implements Exception {
  const _PreviewChanged();
}

typedef CurrentLedgerInjectionPreviewKey = ({
  String sessionId,
  String? characterId,
});

final currentLedgerInjectionPreviewServiceProvider =
    Provider<CurrentLedgerInjectionPreviewService>((ref) {
      return CurrentLedgerInjectionPreviewService(
        ref.watch(chatRepoProvider),
        ref.watch(characterRepoProvider),
        ref.watch(effectiveCanonContextLoaderProvider),
        ref.watch(studioTurnConfigResolverProvider).resolve,
        (sessionId, messages) => ref
            .read(extBlocksPromptInjectionProvider)
            .injectIntoHistory(sessionId: sessionId, messages: messages),
        (characterId, sessionId) =>
            ref
                .read(
                  effectivePersonaForChatProvider((
                    charId: characterId,
                    sessionId: sessionId,
                  )),
                )
                ?.name ??
            '',
      );
    });

final currentLedgerInjectionPreviewProvider =
    FutureProvider.family<
      CurrentLedgerInjectionPreview,
      CurrentLedgerInjectionPreviewKey
    >((ref, key) {
      return ref
          .watch(currentLedgerInjectionPreviewServiceProvider)
          .load(sessionId: key.sessionId, expectedCharacterId: key.characterId);
    });
