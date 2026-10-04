import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../../models/ledger_prompt_injection_mode.dart';
import 'arc_state_builder.dart';
import 'effective_canon_prompt_formatter.dart';
import 'selective_ledger_projection_filter.dart';

final class EffectiveCanonPromptMaterialization {
  const EffectiveCanonPromptMaterialization({
    required this.filteredProjection,
    required this.characterKnowledgeContent,
    required this.studioSessionStateContent,
    required this.arcContent,
    required this.transitionContent,
    required this.diagnostics,
    required this.injectionCacheIdentity,
  });

  final EffectiveCanonPromptProjection filteredProjection;
  final String? characterKnowledgeContent;
  final String? studioSessionStateContent;
  final String? arcContent;
  final String? transitionContent;
  final List<LedgerProjectionDiagnostic> diagnostics;
  final String injectionCacheIdentity;
}

/// Selects and renders every Ledger-owned prompt channel from one immutable
/// projection. Callers own exception handling so enabled-preset failures can
/// fall back to legacy while an explicit opt-out remains empty.
abstract final class EffectiveCanonPromptMaterializer {
  static EffectiveCanonPromptMaterialization materialize(
    SelectiveLedgerProjectionInput input, {
    required String sessionId,
    String latestUserText = '',
    String latestAssistantText = '',
  }) {
    final selection = SelectiveLedgerProjectionFilter.select(input);
    final projection = selection.projection;
    // Preserve the public legacy contract: transitions are appended to the
    // session-state field. Existing prompt paths do not consume the separate
    // transition field, so moving them would silently change legacy output.
    final content = EffectiveCanonPromptFormatter.format(
      projection,
      sessionId: sessionId,
      latestUserText: latestUserText,
      latestAssistantText: latestAssistantText,
    );
    final arc = buildArcContent(
      projection.trackers,
      latestUserText: latestUserText,
      latestAssistantText: latestAssistantText,
    );
    return EffectiveCanonPromptMaterialization(
      filteredProjection: projection,
      characterKnowledgeContent: content.characterKnowledge,
      studioSessionStateContent: content.sessionState,
      arcContent: arc,
      // The existing formatter already appends transitions to sessionState.
      // Keep the compatibility field empty to prevent consumers that combine
      // both fields from injecting the same canonical claim twice.
      transitionContent: null,
      diagnostics: selection.diagnostics,
      // Shadow emits the legacy projection, but its identity must still expose
      // the selective decision so cache/diagnostic comparisons are meaningful.
      injectionCacheIdentity: _identity(input, selection.selectiveProjection),
    );
  }

  /// Materializes with the asymmetric failure contract used by generation:
  /// explicit opt-out always stays empty; opted-in failures use exact legacy
  /// formatting rather than failing the request or returning partial state.
  static EffectiveCanonPromptMaterialization materializeSafely(
    SelectiveLedgerProjectionInput input, {
    required String sessionId,
    String latestUserText = '',
    String latestAssistantText = '',
  }) {
    final safeInput = _generationSafeInput(input);
    try {
      return materialize(
        safeInput,
        sessionId: sessionId,
        latestUserText: latestUserText,
        latestAssistantText: latestAssistantText,
      );
    } catch (_) {
      if (safeInput.policy.effectiveMode ==
          LedgerPromptInjectionMode.disabled) {
        final source = safeInput.projection;
        final empty = EffectiveCanonPromptProjection(
          facts: const [],
          trackers: const [],
          unblockedTransitionClaims: const [],
          transitions: const [],
          revisionNumber: source.revisionNumber,
          revisionHash: source.revisionHash,
          cacheIdentity: source.cacheIdentity,
        );
        return EffectiveCanonPromptMaterialization(
          filteredProjection: empty,
          characterKnowledgeContent: null,
          studioSessionStateContent: null,
          arcContent: null,
          transitionContent: null,
          diagnostics: const [],
          injectionCacheIdentity: '${safeInput.policy.identity}/disabled',
        );
      }
      final legacyProjection = safeInput.projection;
      final content = EffectiveCanonPromptFormatter.format(
        legacyProjection,
        sessionId: sessionId,
        latestUserText: latestUserText,
        latestAssistantText: latestAssistantText,
      );
      String? legacyArc;
      try {
        legacyArc = buildArcContent(
          legacyProjection.trackers,
          latestUserText: latestUserText,
          latestAssistantText: latestAssistantText,
        );
      } catch (_) {
        // Matches the legacy callers, which treated arc formatting as an
        // optional channel while preserving character/session state.
      }
      String identity;
      try {
        identity = _identity(safeInput, legacyProjection);
      } catch (_) {
        identity =
            '${safeInput.policy.identity}/${legacyProjection.cacheIdentity}';
      }
      return EffectiveCanonPromptMaterialization(
        filteredProjection: legacyProjection,
        characterKnowledgeContent: content.characterKnowledge,
        studioSessionStateContent: content.sessionState,
        arcContent: legacyArc,
        transitionContent: null,
        diagnostics: const [],
        injectionCacheIdentity: identity,
      );
    }
  }
}

SelectiveLedgerProjectionInput _generationSafeInput(
  SelectiveLedgerProjectionInput input,
) {
  final safeFacts = input.projection.facts
      .where(isSelectableLedgerFact)
      .toList(growable: false);
  if (safeFacts.length == input.projection.facts.length) return input;
  final source = input.projection;
  return SelectiveLedgerProjectionInput(
    policy: input.policy,
    consumerPath: input.consumerPath,
    projection: EffectiveCanonPromptProjection(
      facts: safeFacts,
      trackers: source.trackers,
      unblockedTransitionClaims: source.unblockedTransitionClaims,
      transitions: source.transitions,
      revisionNumber: source.revisionNumber,
      revisionHash: source.revisionHash,
      cacheIdentity: source.cacheIdentity,
    ),
    visibleMessages: input.visibleMessages,
    selectedSwipeByMessageId: input.selectedSwipeByMessageId,
    focalUserName: input.focalUserName,
    structuredContinuitySourceIds: input.structuredContinuitySourceIds,
    freshness: input.freshness,
  );
}

String _identity(
  SelectiveLedgerProjectionInput input,
  EffectiveCanonPromptProjection selected,
) {
  final visible = input.visibleMessages
      .where(
        (message) =>
            (message.role == 'user' || message.role == 'assistant') &&
            !message.isHidden &&
            !message.isTyping,
      )
      .map(
        (message) => {
          'id': message.id,
          'contentHash': _hash(message.content),
          'swipe':
              input.selectedSwipeByMessageId[message.id] ?? message.swipeId,
        },
      )
      .toList(growable: false);
  final trackers =
      selected.trackers
          .map(
            (item) => jsonEncode({
              'name': item.name,
              'value': item.value,
              'scope': item.scope,
              'provenance': item.provenance,
              'basisRevisionNumber': item.basisRevisionNumber,
              'basisRevisionHash': item.basisRevisionHash,
            }),
          )
          .toList()
        ..sort();
  final facts =
      selected.facts
          .map(
            (item) => jsonEncode({
              'id': item.id,
              'scopeKey': item.scopeKey,
              'predicate': item.predicate,
              'object': item.object,
              'lifecycle': item.lifecycle.wireName,
              'epistemicState': item.epistemicState.wireName,
              'sourceMessageId': item.sourceMessageId,
              'sourceSwipeId': item.sourceSwipeId,
              'sourceAgentSwipeId': item.sourceAgentSwipeId,
            }),
          )
          .toList()
        ..sort();
  final transitions =
      selected.transitions
          .map(
            (item) => jsonEncode({
              'id': item.id,
              'scope': item.semanticScopeKey,
              'keys': [...item.affectedTrackerKeys]..sort(),
              'claim': item.claim,
            }),
          )
          .toList()
        ..sort();
  final continuity = input.structuredContinuitySourceIds.toList()..sort();
  return _hash(
    jsonEncode({
      'effectiveCanon': selected.cacheIdentity,
      'policy': input.policy.toJson(),
      'consumerPath': input.consumerPath,
      'freshness': input.freshness.name,
      'visible': visible,
      'continuitySourceIds': continuity,
      'facts': facts,
      'trackers': trackers,
      'transitions': transitions,
    }),
  );
}

String _hash(String value) =>
    crypto.sha256.convert(utf8.encode(value)).toString();
