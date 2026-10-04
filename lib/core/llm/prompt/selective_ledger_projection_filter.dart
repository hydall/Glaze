import 'dart:convert';

import '../../models/character_knowledge_fact.dart';
import '../../models/chat_message.dart';
import '../../models/ledger_prompt_injection_policy.dart';
import '../../models/ledger_prompt_injection_mode.dart';
import '../../models/tracker.dart';
import 'effective_canon_prompt_formatter.dart';

enum LedgerProjectionDeliveryTier { critical, gap, volatile, excluded }

/// Coverage suppression is unsafe until the caller proves that its projection
/// and final selected message set share an atomic freshness boundary.
enum LedgerProjectionFreshness { unknown, provenCurrent }

enum LedgerProjectionTrackerDomain {
  npc,
  relationship,
  arc,
  scene,
  world,
  other,
  manualControl,
}

enum LedgerProjectionDecisionReason {
  selected,
  disabledMode,
  visibleSourceEvidence,
  structuredContinuityCoverage,
  visibleEntityCoverage,
  notRelevantToCausalWindow,
  tentativeOrInferred,
  transitionTargetSuppressed,
}

final class LedgerProjectionDiagnostic {
  const LedgerProjectionDiagnostic({
    required this.groupId,
    required this.selected,
    required this.reason,
    required this.tier,
    this.matchingSourceIds = const <String>[],
  });

  final String groupId;
  final bool selected;
  final LedgerProjectionDecisionReason reason;
  final LedgerProjectionDeliveryTier tier;
  final List<String> matchingSourceIds;
}

/// All coverage is supplied from the final, already trimmed responder context.
/// [selectedSwipeByMessageId] is identity metadata only: [visibleMessages]
/// must already contain the content of that selected swipe.
final class SelectiveLedgerProjectionInput {
  const SelectiveLedgerProjectionInput({
    required this.policy,
    required this.consumerPath,
    required this.projection,
    required this.visibleMessages,
    required this.selectedSwipeByMessageId,
    this.focalUserName = '',
    this.structuredContinuitySourceIds = const <String>{},
    this.freshness = LedgerProjectionFreshness.unknown,
  });

  final LedgerPromptInjectionPolicy policy;
  final String consumerPath;
  final EffectiveCanonPromptProjection projection;
  final List<ChatMessage> visibleMessages;
  final Map<String, int> selectedSwipeByMessageId;

  /// Resolved `{{user}}` identity. It is not enough by itself to make a
  /// fact relevant: the protagonist is present in nearly every turn.
  final String focalUserName;
  final Set<String> structuredContinuitySourceIds;
  final LedgerProjectionFreshness freshness;
}

final class SelectiveLedgerProjectionResult {
  const SelectiveLedgerProjectionResult({
    required this.projection,
    required this.selectiveProjection,
    required this.diagnostics,
  });

  /// Projection to materialize (legacy in shadow mode).
  final EffectiveCanonPromptProjection projection;

  /// Selection computed in both shadow and gap-filler modes.
  final EffectiveCanonPromptProjection selectiveProjection;
  final List<LedgerProjectionDiagnostic> diagnostics;
}

/// Pure semantic-group selector. It never reads chat storage and therefore
/// cannot accidentally count hidden, unselected, or budget-trimmed messages.
abstract final class SelectiveLedgerProjectionFilter {
  static SelectiveLedgerProjectionResult select(
    SelectiveLedgerProjectionInput input,
  ) {
    final mode = input.policy.effectiveMode;
    if (mode == LedgerPromptInjectionMode.disabled) {
      final empty = _copyProjection(input.projection);
      return SelectiveLedgerProjectionResult(
        projection: empty,
        selectiveProjection: empty,
        diagnostics: const [
          LedgerProjectionDiagnostic(
            groupId: '*',
            selected: false,
            reason: LedgerProjectionDecisionReason.disabledMode,
            tier: LedgerProjectionDeliveryTier.excluded,
          ),
        ],
      );
    }
    final visible = {
      for (final message in input.visibleMessages)
        if ((message.role == 'user' || message.role == 'assistant') &&
            !message.isHidden &&
            !message.isTyping)
          message.id: message,
    };
    final causalWindow = _latestCausalWindow(visible.values);
    final groups = _buildGroups(
      input.projection,
      focalUserName: input.focalUserName,
    );
    final factRelevanceActive = groups
        .where((group) => group.facts.isNotEmpty)
        .any(
          (group) => group.factRelevanceEntities.any(
            (entity) => causalWindow.any(
              (message) => _literalEntity(message.content, entity),
            ),
          ),
        );
    // A current scene can be represented by tracker state without having a
    // matching Character Knowledge fact. Tracker keys use canonical IDs while
    // chat commonly uses display names in another language, so an entity-name
    // comparison alone is not reliable. A tracker anchored in the causal
    // window is equally explicit current-scene evidence.
    final trackerRelevanceActive = groups
        .where((group) => group.trackers.isNotEmpty)
        .any(
          (group) =>
              group.entities.any(
                (entity) => causalWindow.any(
                  (message) => _literalEntity(message.content, entity),
                ),
              ) ||
              group.sources.any(
                (source) => causalWindow.any(
                  (message) =>
                      source.messageId == message.id &&
                      (source.swipeId == null ||
                          source.swipeId ==
                              (input.selectedSwipeByMessageId[message.id] ??
                                  message.swipeId)),
                ),
              ),
        );
    final selectedFacts = <CharacterKnowledgeFact>[];
    final selectedTrackers = <Tracker>[];
    final diagnostics = <LedgerProjectionDiagnostic>[];
    final selectedGroupIds = <String>{};
    final trackerGroup = <String, String>{};
    final manualTargets = input.projection.trackers
        .where(_isManualControl)
        .map((item) => _manualTarget(item.name))
        .toSet();

    for (final group in groups) {
      for (final tracker in group.trackers) {
        trackerGroup[tracker.name] = group.id;
      }
      final decision = _decide(
        group,
        visible,
        input.structuredContinuitySourceIds,
        input.selectedSwipeByMessageId,
        input.freshness,
        manualTargets,
        causalWindow,
        factRelevanceActive || trackerRelevanceActive,
        mode != LedgerPromptInjectionMode.legacy,
      );
      diagnostics.add(
        LedgerProjectionDiagnostic(
          groupId: group.id,
          selected: decision.selected,
          reason: decision.reason,
          tier: group.tier,
          matchingSourceIds: decision.matches,
        ),
      );
      if (!decision.selected) continue;
      selectedGroupIds.add(group.id);
      selectedFacts.addAll(group.facts);
      selectedTrackers.addAll(group.trackers);
    }

    // Manual controls are authoritative records. They remain available even
    // when their target is absent, and make an existing exact target critical.
    for (final control in input.projection.trackers.where(_isManualControl)) {
      selectedTrackers.add(control);
      diagnostics.add(
        LedgerProjectionDiagnostic(
          groupId: 'manual:${control.name}',
          selected: true,
          reason: LedgerProjectionDecisionReason.selected,
          tier: LedgerProjectionDeliveryTier.critical,
        ),
      );
    }

    final transitions = <EffectiveCanonTransitionProjection>[];
    for (final transition in input.projection.transitions) {
      final targetGroups = transition.affectedTrackerKeys
          .map((key) => trackerGroup[key])
          .whereType<String>()
          .toSet();
      final durable =
          transition.affectedTrackerKeys.any(_isCriticalTrackerKey) ||
          _looksDurableScope(transition.semanticScopeKey);
      // Relevance applies to facts only. Legacy keeps the established complete
      // transition contract; Gap Filler may omit a non-durable transition when
      // every affected current-state group is absent.
      final selected =
          mode == LedgerPromptInjectionMode.legacy ||
          input.freshness == LedgerProjectionFreshness.unknown ||
          (durable &&
              (targetGroups.isEmpty ||
                  targetGroups.any(selectedGroupIds.contains)));
      diagnostics.add(
        LedgerProjectionDiagnostic(
          groupId: 'transition:${transition.id}',
          selected: selected,
          reason: selected
              ? LedgerProjectionDecisionReason.selected
              : LedgerProjectionDecisionReason.transitionTargetSuppressed,
          tier: durable
              ? LedgerProjectionDeliveryTier.critical
              : LedgerProjectionDeliveryTier.excluded,
        ),
      );
      if (selected) transitions.add(transition);
    }
    final selective = _copyProjection(
      input.projection,
      facts: selectedFacts,
      trackers: selectedTrackers,
      transitions: transitions,
      // Older isolate payloads can carry only string transition claims. Legacy
      // must preserve that contract verbatim; structured claims are selected
      // independently for Gap Filler.
      claims: mode == LedgerPromptInjectionMode.legacy
          ? input.projection.unblockedTransitionClaims
          : transitions.map((item) => item.claim).toList(growable: false),
    );
    return SelectiveLedgerProjectionResult(
      // Shadow is an internal comparison mode. User-facing modes are:
      // legacy = relevance only; gapFiller = relevance plus history coverage.
      projection: mode == LedgerPromptInjectionMode.shadow
          ? input.projection
          : selective,
      selectiveProjection: selective,
      diagnostics: diagnostics,
    );
  }
}

final class _Group {
  _Group(this.id);
  final String id;
  final List<CharacterKnowledgeFact> facts = [];
  final List<Tracker> trackers = [];
  final List<_SourceRef> sources = [];
  final Set<String> entities = {};
  final Set<String> factRelevanceEntities = {};
  bool factRelevanceDependsOnlyOnFocalUser = false;
  LedgerProjectionDeliveryTier tier = LedgerProjectionDeliveryTier.gap;
}

List<_Group> _buildGroups(
  EffectiveCanonPromptProjection projection, {
  String focalUserName = '',
}) {
  final byId = <String, _Group>{};
  _Group get(String id) => byId.putIfAbsent(id, () => _Group(id));
  for (final fact in projection.facts) {
    final scope = fact.scopeKey.trim().isNotEmpty
        ? fact.scopeKey.trim()
        : '${fact.factClass.wireName}:${fact.subjectKey}';
    // Facts are independently valid and tiered. Sharing a semantic scope must
    // not let a tentative item suppress an accepted one (or vice versa).
    final group = get('fact:$scope:${fact.id}');
    group.facts.add(fact);
    if (fact.sourceMessageId.isNotEmpty) {
      group.sources.add(_SourceRef(fact.sourceMessageId, fact.sourceSwipeId));
    }
    group.entities.addAll(
      [
        fact.subjectKey,
        fact.subjectName,
        ...fact.entities,
      ].where((value) => value.trim().isNotEmpty),
    );
    final relevanceEntities = [
      fact.subjectKey,
      fact.subjectName,
      ...fact.entities,
    ].where((value) => value.trim().isNotEmpty).toList(growable: false);
    final nonFocalEntities = relevanceEntities
        .where((value) => !_isFocalUserIdentity(value, focalUserName))
        .toList(growable: false);
    group.factRelevanceEntities.addAll(nonFocalEntities);
    if (relevanceEntities.isNotEmpty && nonFocalEntities.isEmpty) {
      group.factRelevanceDependsOnlyOnFocalUser = true;
    }
    if (!isSelectableLedgerFact(fact)) {
      group.tier = LedgerProjectionDeliveryTier.excluded;
    } else if (_isCriticalFact(fact)) {
      group.tier = LedgerProjectionDeliveryTier.critical;
    } else if (fact.factClass == CharacterKnowledgeFactClass.goal ||
        fact.factClass == CharacterKnowledgeFactClass.behaviorChange) {
      group.tier = LedgerProjectionDeliveryTier.volatile;
    }
  }
  for (final tracker in projection.trackers.where(
    (item) => !_isManualControl(item) && !_isGameClockTrackerKey(item.name),
  )) {
    // Tracker tier is item-level. In particular, an arc tombstone or lock must
    // not promote every volatile field in the same semantic group.
    final id = '${_trackerGroupId(tracker.name)}#${tracker.name}';
    final group = get(id);
    group.trackers.add(tracker);
    group.sources.addAll(_provenanceSources(tracker.provenance));
    group.entities.addAll(_trackerEntities(tracker.name, tracker.value));
    if (_isCriticalTrackerKey(tracker.name) ||
        _isTerminalArcTracker(tracker, projection.trackers)) {
      group.tier = LedgerProjectionDeliveryTier.critical;
    } else if (_isVolatileTrackerKey(tracker.name) &&
        group.tier != LedgerProjectionDeliveryTier.critical) {
      group.tier = LedgerProjectionDeliveryTier.volatile;
    }
  }
  return byId.values.toList(growable: false);
}

_Decision _decide(
  _Group group,
  Map<String, ChatMessage> visible,
  Set<String> continuityIds,
  Map<String, int> selectedSwipes,
  LedgerProjectionFreshness freshness,
  Set<String> manualTargets,
  List<ChatMessage> causalWindow,
  bool factRelevanceActive,
  bool allowHistoryCoverage,
) {
  if (group.tier == LedgerProjectionDeliveryTier.excluded) {
    return const _Decision(
      false,
      LedgerProjectionDecisionReason.tentativeOrInferred,
    );
  }
  if (group.tier == LedgerProjectionDeliveryTier.critical ||
      group.trackers.any((item) => manualTargets.contains(item.name))) {
    return const _Decision(true, LedgerProjectionDecisionReason.selected);
  }
  // Non-critical facts are durable context, but should not pull an unrelated
  // character or plot thread back into the immediate scene. Relevance is
  // independent of the selected delivery mode; only coverage is Gap-Filler
  // specific. This deliberately uses only the newest conversational exchange.
  if (group.facts.isNotEmpty &&
      factRelevanceActive &&
      (group.factRelevanceEntities.isNotEmpty ||
          group.factRelevanceDependsOnlyOnFocalUser) &&
      causalWindow.isNotEmpty &&
      !group.factRelevanceEntities.any(
        (entity) => causalWindow.any(
          (message) => _literalEntity(message.content, entity),
        ),
      )) {
    return const _Decision(
      false,
      LedgerProjectionDecisionReason.notRelevantToCausalWindow,
    );
  }
  // Unknown freshness never permits history-based suppression, but it does
  // not disable the independent relevance filter above.
  if (!allowHistoryCoverage || freshness == LedgerProjectionFreshness.unknown) {
    return const _Decision(true, LedgerProjectionDecisionReason.selected);
  }
  final visibleSources =
      group.sources
          .where((source) => _sourceMatches(source, visible, selectedSwipes))
          .map((source) => source.messageId)
          .toList()
        ..sort();
  if (group.sources.isNotEmpty &&
      visibleSources.length == group.sources.length) {
    return _Decision(
      false,
      LedgerProjectionDecisionReason.visibleSourceEvidence,
      visibleSources,
    );
  }
  final continuity =
      group.sources
          .map((source) => source.messageId)
          .where(continuityIds.contains)
          .toList()
        ..sort();
  if (group.sources.isNotEmpty && continuity.length == group.sources.length) {
    return _Decision(
      false,
      LedgerProjectionDecisionReason.structuredContinuityCoverage,
      continuity,
    );
  }
  if (group.tier == LedgerProjectionDeliveryTier.volatile &&
      group.entities.isNotEmpty &&
      group.entities.any(
        (entity) => visible.values.any(
          (message) => _literalEntity(message.content, entity),
        ),
      )) {
    return const _Decision(
      false,
      LedgerProjectionDecisionReason.visibleEntityCoverage,
    );
  }
  return const _Decision(true, LedgerProjectionDecisionReason.selected);
}

List<ChatMessage> _latestCausalWindow(Iterable<ChatMessage> visible) {
  final conversational = visible
      .where((message) => message.role == 'user' || message.role == 'assistant')
      .toList(growable: false);
  const maxMessages = 6;
  if (conversational.length <= maxMessages) return conversational;
  return conversational.sublist(conversational.length - maxMessages);
}

bool _isFocalUserIdentity(String value, String focalUserName) {
  final normalized = _normalizeIdentity(value);
  final focal = _normalizeIdentity(focalUserName);
  return normalized == '{{user}}' || (focal.isNotEmpty && normalized == focal);
}

String _normalizeIdentity(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.startsWith('entity:')
      ? normalized.substring('entity:'.length)
      : normalized;
}

final class _SourceRef {
  const _SourceRef(this.messageId, [this.swipeId]);
  final String messageId;
  final int? swipeId;
}

bool _sourceMatches(
  _SourceRef source,
  Map<String, ChatMessage> visible,
  Map<String, int> selectedSwipes,
) {
  final message = visible[source.messageId];
  if (message == null) return false;
  final selected = selectedSwipes[source.messageId] ?? message.swipeId;
  return source.swipeId == null || source.swipeId == selected;
}

final class _Decision {
  const _Decision(
    this.selected,
    this.reason, [
    this.matches = const <String>[],
  ]);
  final bool selected;
  final LedgerProjectionDecisionReason reason;
  final List<String> matches;
}

String _trackerGroupId(String key) {
  final domain = classifyLedgerTracker(key);
  if (domain == LedgerProjectionTrackerDomain.npc) {
    final dot = key.indexOf('.');
    return 'npc:${dot < 0 ? key.substring(4) : key.substring(4, dot)}';
  }
  if (domain == LedgerProjectionTrackerDomain.relationship) {
    final dot = key.indexOf('.');
    final pair = (dot < 0 ? key.substring(13) : key.substring(13, dot)).split(
      ':',
    )..sort();
    return 'relationship:${pair.join(':')}';
  }
  if (domain == LedgerProjectionTrackerDomain.arc) {
    final dot = key.indexOf('.');
    return 'arc:${dot < 0 ? key.substring(4) : key.substring(4, dot)}';
  }
  if (domain == LedgerProjectionTrackerDomain.scene) return 'scene';
  if (domain == LedgerProjectionTrackerDomain.world) {
    return 'world:${key.substring(6).split('.').first}';
  }
  return 'tracker:${key.split('.').first}';
}

LedgerProjectionTrackerDomain classifyLedgerTracker(String key) {
  if (_isManualControlKey(key)) {
    return LedgerProjectionTrackerDomain.manualControl;
  }
  if (key.startsWith('npc:')) return LedgerProjectionTrackerDomain.npc;
  if (key.startsWith('relationship:')) {
    return LedgerProjectionTrackerDomain.relationship;
  }
  if (key.startsWith('arc:')) return LedgerProjectionTrackerDomain.arc;
  if (key.startsWith('scene.')) return LedgerProjectionTrackerDomain.scene;
  if (key.startsWith('world:')) return LedgerProjectionTrackerDomain.world;
  return LedgerProjectionTrackerDomain.other;
}

Set<String> _trackerEntities(String key, String value) {
  if (key.startsWith('npc:')) {
    return {key.substring(4).split('.').first};
  }
  if (key.startsWith('relationship:')) {
    return key.substring(13).split('.').first.split(':').toSet();
  }
  if (key == 'scene.present_entities' ||
      key == 'scene.absent_backstory_entities') {
    return value
        .split(RegExp(r'[,;\n]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
  }
  return const <String>{};
}

List<_SourceRef> _provenanceSources(String provenance) {
  final ids = <String>{};
  int? swipeId;
  for (final match in RegExp(
    r'(?:^|[|;,\s])message(?:Id)?=([^|;,\s]+)',
    caseSensitive: false,
  ).allMatches(provenance)) {
    final value = match.group(1);
    if (value != null && value.isNotEmpty) ids.add(value);
  }
  if (provenance.trimLeft().startsWith('{')) {
    try {
      final json = jsonDecode(provenance);
      if (json is Map) {
        for (final key in const ['messageId', 'sourceMessageId']) {
          final value = json[key];
          if (value is String && value.isNotEmpty) ids.add(value);
        }
        final rawSwipe = json['swipeId'] ?? json['sourceSwipeId'];
        if (rawSwipe is int) swipeId = rawSwipe;
      }
    } catch (_) {}
  }
  return ids.map((id) => _SourceRef(id, swipeId)).toList(growable: false);
}

bool _literalEntity(String text, String entity) {
  final needle = _safeNormalize(entity.trim());
  if (needle.length < 2) return false;
  final haystack = _safeNormalize(text);
  final escaped = RegExp.escape(needle);
  return RegExp(
    '(^|[^\\p{L}\\p{N}_])$escaped(?=\$|[^\\p{L}\\p{N}_])',
    unicode: true,
  ).hasMatch(haystack);
}

// Dart has no SDK Unicode normalization API and this repository has no NFC
// dependency. Keep matching conservative while covering common decomposed
// Latin aliases and Russian е/ё. Unknown combining sequences are not stripped.
String _safeNormalize(String value) {
  var result = value.toLowerCase().replaceAll('ё', 'е');
  const composed = <String, String>{
    'a\u0301': 'á',
    'e\u0301': 'é',
    'i\u0301': 'í',
    'o\u0301': 'ó',
    'u\u0301': 'ú',
    'y\u0301': 'ý',
    'n\u0303': 'ñ',
    'c\u0327': 'ç',
    'a\u0308': 'ä',
    'e\u0308': 'ë',
    'i\u0308': 'ï',
    'o\u0308': 'ö',
    'u\u0308': 'ü',
  };
  for (final entry in composed.entries) {
    result = result.replaceAll(entry.key, entry.value);
  }
  return result;
}

bool _isManualControl(Tracker tracker) => _isManualControlKey(tracker.name);
bool _isManualControlKey(String key) =>
    key.startsWith('canon_lock:') || key.startsWith('canon_override:');
String _manualTarget(String key) => key.substring(key.indexOf(':') + 1);

bool _isCriticalFact(CharacterKnowledgeFact fact) =>
    fact.factClass == CharacterKnowledgeFactClass.commitment ||
    fact.factClass == CharacterKnowledgeFactClass.persistentCondition ||
    fact.factClass == CharacterKnowledgeFactClass.identityDevelopment;

/// Whether a durable knowledge fact may cross the final-generator prompt
/// boundary. Tentative and non-canonical epistemic states remain available to
/// review/reconciliation workflows but must never steer a reroll.
bool isSelectableLedgerFact(CharacterKnowledgeFact fact) {
  if (fact.lifecycle != CharacterKnowledgeFactLifecycle.active) return false;
  return !const {
    CharacterKnowledgeEpistemicState.inferred,
    CharacterKnowledgeEpistemicState.disbelieved,
    CharacterKnowledgeEpistemicState.forgotten,
    CharacterKnowledgeEpistemicState.retracted,
  }.contains(fact.epistemicState);
}

/// Game clock (`world:time` / `world:date` / `world:day`) is surfaced through
/// the always-current `{{gametime}}` / `{{gamedate}}` / `{{gameday}}` macros,
/// not through the ledger projection. Excluding the raw trackers here keeps the
/// prompt from duplicating the clock and avoids re-injecting a stale value.
bool _isGameClockTrackerKey(String key) {
  final value = key.toLowerCase();
  return value == 'world:time' ||
      value == 'world:date' ||
      value == 'world:day';
}

bool _isCriticalTrackerKey(String key) {
  final value = key.toLowerCase();
  return value.startsWith('canon_') ||
      value.contains('boundar') ||
      value.contains('persistent_condition') ||
      value.contains('commitment') ||
      value.endsWith('.do_not_reopen') ||
      value.endsWith('.card_override');
}

bool _isVolatileTrackerKey(String key) {
  final value = key.toLowerCase();
  return value.startsWith('scene.') ||
      value.endsWith('.current_goal') ||
      value.endsWith('.current_emotional_residue') ||
      value.endsWith('.location') ||
      value.endsWith('.action');
}

bool _isTerminalArcTracker(Tracker tracker, List<Tracker> all) {
  if (!tracker.name.startsWith('arc:')) return false;
  final group = _trackerGroupId(tracker.name);
  String? status;
  for (final item in all) {
    if (_trackerGroupId(item.name) == group && item.name.endsWith('.status')) {
      status = item.value.toLowerCase();
      break;
    }
  }
  return const {
    'completed',
    'failed',
    'abandoned',
    'superseded',
  }.contains(status);
}

bool _looksDurableScope(String scope) {
  final value = scope.toLowerCase();
  return value.contains('resolved') ||
      value.contains('supersed') ||
      value.contains('identity') ||
      value.contains('commitment') ||
      value.contains('condition') ||
      value.contains('boundary');
}

EffectiveCanonPromptProjection _copyProjection(
  EffectiveCanonPromptProjection source, {
  List<CharacterKnowledgeFact> facts = const [],
  List<Tracker> trackers = const [],
  List<EffectiveCanonTransitionProjection> transitions = const [],
  List<String> claims = const [],
}) => EffectiveCanonPromptProjection(
  facts: facts,
  trackers: trackers,
  unblockedTransitionClaims: claims,
  transitions: transitions,
  revisionNumber: source.revisionNumber,
  revisionHash: source.revisionHash,
  cacheIdentity: source.cacheIdentity,
);
