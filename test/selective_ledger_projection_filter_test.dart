import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt/effective_canon_prompt_formatter.dart';
import 'package:glaze_flutter/core/llm/prompt/effective_canon_prompt_materializer.dart';
import 'package:glaze_flutter/core/llm/prompt/arc_state_builder.dart';
import 'package:glaze_flutter/core/llm/prompt/selective_ledger_projection_filter.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_policy.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

void main() {
  group('SelectiveLedgerProjectionFilter', () {
    test('disabled is empty even when requested mode is legacy', () {
      final result = _select(
        _projection(facts: [_fact()]),
        policy: const LedgerPromptInjectionPolicy(
          presetOptIn: false,
          mode: LedgerPromptInjectionMode.legacy,
        ),
      );
      expect(result.projection.facts, isEmpty);
      expect(result.projection.trackers, isEmpty);
      expect(result.projection.transitions, isEmpty);
      expect(
        result.diagnostics.single.reason,
        LedgerProjectionDecisionReason.disabledMode,
      );
    });

    test('legacy keeps facts when no causal relevance signal exists', () {
      final projection = _projection(facts: [_fact()]);
      final result = _select(
        projection,
        policy: const LedgerPromptInjectionPolicy(
          presetOptIn: true,
          mode: LedgerPromptInjectionMode.legacy,
        ),
      );
      expect(result.projection.facts.map((fact) => fact.id), ['fact-1']);
      expect(result.diagnostics, isNotEmpty);
    });

    test('legacy applies relevance but does not suppress visible source', () {
      final projection = _projection(
        facts: [
          _fact(
            id: 'chloe',
            source: 'm1',
            subjectKey: 'chloe',
            subjectName: 'Chloe',
          ),
          _fact(
            id: 'gilda',
            source: 'm0',
            subjectKey: 'gilda',
            subjectName: 'Gilda',
          ),
        ],
      );
      final result = _select(
        projection,
        policy: const LedgerPromptInjectionPolicy(
          presetOptIn: true,
          mode: LedgerPromptInjectionMode.legacy,
        ),
        visible: [
          _message('m1', 'Chloe asks about training.'),
          _message('m2', 'The pool is open tomorrow.'),
        ],
      );

      expect(result.projection.facts.map((fact) => fact.id), ['chloe']);
      expect(
        result.diagnostics
            .firstWhere((item) => item.groupId.contains('chloe'))
            .reason,
        LedgerProjectionDecisionReason.selected,
      );
      expect(
        result.diagnostics
            .firstWhere((item) => item.groupId.contains('gilda'))
            .reason,
        LedgerProjectionDecisionReason.notRelevantToCausalWindow,
      );
    });

    test('shadow diagnoses source coverage but outputs legacy', () {
      final projection = _projection(facts: [_fact(source: 'm1')]);
      final result = _select(
        projection,
        visible: [_message('m1', 'source event')],
        policy: const LedgerPromptInjectionPolicy(
          presetOptIn: true,
          mode: LedgerPromptInjectionMode.shadow,
        ),
      );
      expect(identical(result.projection, projection), isTrue);
      expect(result.selectiveProjection.facts, isEmpty);
      expect(
        result.diagnostics.single.reason,
        LedgerProjectionDecisionReason.visibleSourceEvidence,
      );
    });

    test('only actual visible source evidence suppresses a gap fact', () {
      final projection = _projection(facts: [_fact(source: 'source')]);
      expect(
        _select(
          projection,
          visible: [_message('other', 'same words')],
        ).projection.facts,
        hasLength(1),
      );
      expect(
        _select(
          projection,
          visible: [_message('source', 'event')],
        ).projection.facts,
        isEmpty,
      );
      expect(
        _select(
          projection,
          visible: [_message('source', 'event', hidden: true)],
        ).projection.facts,
        hasLength(1),
      );
    });

    test('unknown freshness preserves valid legacy content', () {
      final projection = _projection(
        facts: [_fact(source: 'source')],
        transitions: [
          EffectiveCanonTransitionProjection(
            id: 'volatile-transition',
            semanticScopeKey: 'scene.current',
            affectedTrackerKeys: ['scene.action'],
            claim: 'The scene moved on.',
          ),
        ],
      );
      final result = _select(
        projection,
        visible: [_message('source', 'event')],
        freshness: LedgerProjectionFreshness.unknown,
      );
      expect(result.projection.facts, hasLength(1));
      expect(result.projection.transitions, hasLength(1));
    });

    test('structured continuity source IDs suppress duplicate gap state', () {
      final result = _select(
        _projection(facts: [_fact(source: 'm-book')]),
        continuity: {'m-book'},
      );
      expect(result.projection.facts, isEmpty);
      expect(
        result.diagnostics.single.reason,
        LedgerProjectionDecisionReason.structuredContinuityCoverage,
      );
    });

    test('critical durable facts survive visible evidence', () {
      final result = _select(
        _projection(
          facts: [
            _fact(
              source: 'm1',
              factClass: CharacterKnowledgeFactClass.persistentCondition,
            ),
          ],
        ),
        visible: [_message('m1', 'Lucy remains injured')],
      );
      expect(result.projection.facts, hasLength(1));
      expect(
        result.diagnostics.single.tier,
        LedgerProjectionDeliveryTier.critical,
      );
    });

    test(
      'non-critical facts unrelated to the causal window are suppressed',
      () {
        final result = _select(
          _projection(
            facts: [
              _fact(id: 'current', subjectKey: 'chloe', subjectName: 'Chloe'),
              _fact(id: 'unrelated', subjectKey: 'gilda', subjectName: 'Gilda'),
            ],
          ),
          visible: [_message('m', 'Chloe asks about the pool.')],
        );
        expect(result.projection.facts.map((fact) => fact.id), ['current']);
        expect(
          result.diagnostics
              .firstWhere((item) => item.groupId.endsWith(':unrelated'))
              .reason,
          LedgerProjectionDecisionReason.notRelevantToCausalWindow,
        );
      },
    );

    test('no causal entity match retains non-critical facts', () {
      final result = _select(
        _projection(
          facts: [_fact(subjectKey: 'gilda', subjectName: 'Gilda')],
        ),
        visible: [_message('m', 'The room falls quiet.')],
      );
      expect(result.projection.facts, hasLength(1));
    });

    test('a present knower does not retain unrelated knowledge', () {
      final result = _select(
        _projection(
          facts: [
            _fact(
              id: 'gilda-knowledge',
              knowerKey: 'kodi',
              knowerName: 'Kodi',
              subjectKey: 'gilda',
              subjectName: 'Gilda',
            ),
            _fact(id: 'kodi-fact', subjectKey: 'kodi', subjectName: 'Kodi'),
          ],
        ),
        visible: [_message('m', 'Kodi asks Chloe about the pool.')],
      );
      expect(result.projection.facts.map((fact) => fact.id), ['kodi-fact']);
    });

    test('focal user mention does not retain unrelated user-subject facts', () {
      final result = _select(
        _projection(
          facts: [
            _fact(id: 'engagement', subjectKey: 'danvi', subjectName: 'Danvi'),
            _fact(id: 'chloe', subjectKey: 'chloe', subjectName: 'Chloe'),
          ],
        ),
        focalUserName: 'Danvi',
        visible: [
          _message('m1', 'Danvi tells Chloe about the pool.'),
          _message('m2', 'Chloe asks about training.'),
        ],
      );

      expect(result.projection.facts.map((fact) => fact.id), ['chloe']);
      expect(
        result.diagnostics
            .firstWhere((item) => item.groupId.endsWith(':engagement'))
            .reason,
        LedgerProjectionDecisionReason.notRelevantToCausalWindow,
      );
    });

    test('focal-user fact survives when an external entity is current', () {
      final result = _select(
        _projection(
          facts: [
            _fact(
              id: 'audi',
              subjectKey: 'danvi',
              subjectName: 'Danvi',
            ).copyWith(entities: const ['Audi', 'Gilda']),
            _fact(id: 'chloe', subjectKey: 'chloe', subjectName: 'Chloe'),
          ],
        ),
        focalUserName: 'Danvi',
        visible: [
          _message('m1', 'Danvi asks whether Gilda wants the Audi.'),
          _message('m2', 'Chloe waits for the answer.'),
        ],
      );

      expect(result.projection.facts.map((fact) => fact.id), ['audi', 'chloe']);
    });

    test(
      'current tracker entity activates fact relevance without a matching fact',
      () {
        final result = _select(
          _projection(
            facts: [
              _fact(
                id: 'engagement',
                subjectKey: 'danvi',
                subjectName: 'Danvi',
              ),
              _fact(id: 'audi', subjectKey: 'gilda', subjectName: 'Gilda'),
            ],
            trackers: [
              _tracker(
                'npc:chloe_brooks.location',
                'Kitchen with Danvi',
                provenance: 'message=m2|swipe=0',
              ),
            ],
          ),
          focalUserName: 'Danvi',
          visible: [
            _message('m1', 'Danvi and Chloe discuss the pool.'),
            _message('m2', 'Chloe asks about training.'),
          ],
        );

        expect(result.projection.facts, isEmpty);
        expect(
          result.diagnostics
              .where((item) => item.groupId.startsWith('fact:'))
              .map((item) => item.reason),
          everyElement(
            LedgerProjectionDecisionReason.notRelevantToCausalWindow,
          ),
        );
      },
    );

    test(
      'a recently mentioned subject remains relevant across three turns',
      () {
        final result = _select(
          _projection(
            facts: [
              _fact(id: 'audi', subjectKey: 'audi', subjectName: 'Audi'),
              _fact(id: 'chloe', subjectKey: 'chloe', subjectName: 'Chloe'),
            ],
          ),
          visible: [
            _message('m1', 'Gilda still needs to discuss the Audi.'),
            _message('m2', 'We can wait for her answer.'),
            _message('m3', 'Chloe enters the kitchen.'),
            _message('m4', 'Chloe asks about the pool.'),
            _message('m5', 'The party grows quieter.'),
            _message('m6', 'Kodi watches the doorway.'),
          ],
        );
        expect(result.projection.facts.map((fact) => fact.id), [
          'audi',
          'chloe',
        ]);
      },
    );

    test('tentative and inferred facts never enter selective output', () {
      final result = _select(
        _projection(
          facts: [
            _fact(lifecycle: CharacterKnowledgeFactLifecycle.tentative),
            _fact(
              id: 'inferred',
              epistemic: CharacterKnowledgeEpistemicState.inferred,
            ),
          ],
        ),
      );
      expect(result.projection.facts, isEmpty);
      expect(
        result.diagnostics.map((item) => item.reason),
        everyElement(LedgerProjectionDecisionReason.tentativeOrInferred),
      );
    });

    test('volatile Cyrillic entity matching uses safe literal boundaries', () {
      final tracker = _tracker('npc:Люси.current_goal', 'уйти');
      final projection = _projection(trackers: [tracker]);
      expect(
        _select(
          projection,
          visible: [_message('m', 'Люсина куртка')],
        ).projection.trackers,
        hasLength(1),
      );
      expect(
        _select(
          projection,
          visible: [_message('m', 'Я вижу Люси.')],
        ).projection.trackers,
        isEmpty,
      );
    });

    test('safe normalization matches common decomposed aliases', () {
      final tracker = _tracker('npc:José.current_goal', 'leave');
      expect(
        _select(
          _projection(trackers: [tracker]),
          visible: [_message('m', 'Jose\u0301 arrives.')],
        ).projection.trackers,
        isEmpty,
      );
    });

    test('world and scene tracker domains are explicit', () {
      expect(
        classifyLedgerTracker('world:weather.state'),
        LedgerProjectionTrackerDomain.world,
      );
      expect(
        classifyLedgerTracker('scene.location'),
        LedgerProjectionTrackerDomain.scene,
      );
    });

    test('relationship requires evidence, not mention of one party', () {
      final projection = _projection(
        trackers: [
          _tracker(
            'relationship:Lucy:David.trust',
            'fragile',
            provenance: 'message=rel-event',
          ),
        ],
      );
      expect(
        _select(
          projection,
          visible: [_message('x', 'Lucy entered')],
        ).projection.trackers,
        hasLength(1),
      );
      expect(
        _select(
          projection,
          visible: [_message('rel-event', 'They reconcile')],
        ).projection.trackers,
        isEmpty,
      );
    });

    test('manual override is authoritative and makes target critical', () {
      final projection = _projection(
        trackers: [
          _tracker('npc:Lucy.current_goal', 'leave', provenance: 'message=m1'),
          _tracker('canon_override:npc:Lucy.current_goal', 'stay'),
        ],
      );
      final result = _select(
        projection,
        visible: [_message('m1', 'Lucy decides to stay')],
      );
      expect(result.projection.trackers, hasLength(2));
    });

    test('standalone manual lock remains selected', () {
      final result = _select(
        _projection(trackers: [_tracker('canon_lock:world:weather', 'true')]),
      );
      expect(result.projection.trackers.single.name, contains('canon_lock'));
    });

    test(
      'mixed validity and criticality are item-level and order independent',
      () {
        final active = _fact(id: 'active', subjectName: 'Run');
        final retracted = _fact(
          id: 'retracted',
          subjectName: 'Run',
          lifecycle: CharacterKnowledgeFactLifecycle.retracted,
        );
        final volatile = _tracker(
          'arc:a.action',
          'run',
          provenance: 'message=m',
        );
        final critical = _tracker('arc:a.do_not_reopen', 'true');
        for (final facts in [
          [active, retracted],
          [retracted, active],
        ]) {
          final result = _select(
            _projection(facts: facts, trackers: [critical, volatile]),
            visible: [_message('m', 'run')],
          );
          expect(result.projection.facts.map((item) => item.id), ['active']);
          expect(result.projection.trackers.map((item) => item.name), [
            'arc:a.do_not_reopen',
          ]);
        }
      },
    );

    test('source swipe mismatch is not direct coverage', () {
      final result = _select(
        _projection(facts: [_fact(source: 'm')]),
        visible: [_message('m', 'replacement', swipe: 2)],
        swipes: {'m': 2},
      );
      expect(result.projection.facts, hasLength(1));
    });

    test('resolved arc group and durable transition remain consistent', () {
      final projection = _projection(
        trackers: [
          _tracker('arc:rescue.status', 'completed'),
          _tracker('arc:rescue.summary', 'Everyone escaped'),
        ],
        transitions: [
          EffectiveCanonTransitionProjection(
            id: 't1',
            semanticScopeKey: 'arc.resolved.rescue',
            affectedTrackerKeys: ['arc:rescue.status'],
            claim: 'The rescue is resolved.',
          ),
        ],
      );
      final result = _select(projection);
      expect(result.projection.trackers, hasLength(2));
      expect(result.projection.transitions.map((item) => item.id), ['t1']);
      expect(result.projection.unblockedTransitionClaims, [
        'The rescue is resolved.',
      ]);
    });
  });

  group('projection codec and materializer', () {
    test('arc compatibility maps only existing terminal statuses', () {
      for (final status in ['completed', 'failed', 'abandoned', 'superseded']) {
        expect(
          mapLegacyArcLifecycle(status),
          ArcLifecycleCompatibility.terminal,
        );
      }
      expect(mapLegacyArcLifecycle('paused'), ArcLifecycleCompatibility.paused);
      expect(
        mapLegacyArcLifecycle('resolved'),
        ArcLifecycleCompatibility.active,
      );
      expect(
        buildArcContent([
          _tracker('arc:a.status', 'paused'),
          _tracker('arc:a.title', 'A'),
        ]),
        contains('continuity only; not an immediate scene task'),
      );
    });

    test('structured transition round trips with all filtering fields', () {
      final projection = _projection(
        transitions: [
          EffectiveCanonTransitionProjection(
            id: 'transition-7',
            semanticScopeKey: 'relationship:a:b',
            affectedTrackerKeys: ['relationship:a:b.trust'],
            claim: 'Trust is established.',
          ),
        ],
      );
      final decoded = EffectiveCanonPromptProjection.fromJson(
        projection.toJson(),
      );
      final transition = decoded.transitions.single;
      expect(transition.id, 'transition-7');
      expect(transition.semanticScopeKey, 'relationship:a:b');
      expect(transition.affectedTrackerKeys, ['relationship:a:b.trust']);
      expect(transition.claim, 'Trust is established.');
    });

    test('legacy materialization is byte-equivalent to existing formatter', () {
      final projection = _projection(
        facts: [_fact()],
        trackers: [_tracker('world:weather', 'rain')],
        claims: ['The old conflict is over.'],
      );
      final old = EffectiveCanonPromptFormatter.format(
        projection,
        sessionId: 's',
        latestUserText: '',
        latestAssistantText: '',
      );
      final materialized = EffectiveCanonPromptMaterializer.materialize(
        _input(
          projection,
          const LedgerPromptInjectionPolicy(
            presetOptIn: true,
            mode: LedgerPromptInjectionMode.legacy,
          ),
        ),
        sessionId: 's',
      );
      expect(materialized.characterKnowledgeContent, old.characterKnowledge);
      expect(
        [
          materialized.studioSessionStateContent,
          materialized.transitionContent,
        ].whereType<String>().join('\n\n'),
        old.sessionState,
      );
    });

    test('safe materialization never exposes tentative facts', () {
      final active = _fact(id: 'active', object: 'accepted sentinel');
      final tentative = _fact(
        id: 'tentative',
        object: 'tentative sentinel',
        lifecycle: CharacterKnowledgeFactLifecycle.tentative,
      );
      final materialized = EffectiveCanonPromptMaterializer.materializeSafely(
        _input(
          _projection(facts: [active, tentative]),
          const LedgerPromptInjectionPolicy(
            presetOptIn: true,
            mode: LedgerPromptInjectionMode.legacy,
          ),
        ),
        sessionId: 's',
      );

      expect(materialized.filteredProjection.facts, [active]);
      expect(materialized.characterKnowledgeContent, contains(active.object));
      expect(
        materialized.characterKnowledgeContent,
        isNot(contains(tentative.object)),
      );
    });

    test('identity is deterministic and changes with swipe/content/path', () {
      String identity(String content, int swipe, String path) =>
          EffectiveCanonPromptMaterializer.materialize(
            _input(
              _projection(trackers: [_tracker('world:weather', 'rain')]),
              _gapPolicy,
              visible: [_message('m', content)],
              swipes: {'m': swipe},
              path: path,
            ),
            sessionId: 's',
          ).injectionCacheIdentity;
      expect(
        identity('hello', 2, 'ordinary'),
        identity('hello', 2, 'ordinary'),
      );
      expect(
        identity('hello', 2, 'ordinary'),
        isNot(identity('hello', 3, 'ordinary')),
      );
      expect(
        identity('hello', 2, 'ordinary'),
        isNot(identity('changed', 2, 'ordinary')),
      );
      expect(
        identity('hello', 2, 'ordinary'),
        isNot(identity('hello', 2, 'studio-final')),
      );
    });

    test(
      'identity ignores hidden and typing messages and hashes provenance',
      () {
        String identity(Tracker tracker, List<ChatMessage> visible) =>
            EffectiveCanonPromptMaterializer.materialize(
              _input(
                _projection(trackers: [tracker]),
                _gapPolicy,
                visible: visible,
              ),
              sessionId: 's',
            ).injectionCacheIdentity;
        final base = identity(_tracker('world:weather', 'rain'), const []);
        expect(
          identity(_tracker('world:weather', 'rain'), [
            _message('hidden', 'secret', hidden: true),
            _message('typing', 'draft', typing: true),
          ]),
          base,
        );
        expect(
          identity(
            _tracker('world:weather', 'rain', provenance: 'message=m'),
            const [],
          ),
          isNot(base),
        );
      },
    );
  });
}

const _gapPolicy = LedgerPromptInjectionPolicy(
  presetOptIn: true,
  mode: LedgerPromptInjectionMode.gapFiller,
);

SelectiveLedgerProjectionResult _select(
  EffectiveCanonPromptProjection projection, {
  LedgerPromptInjectionPolicy policy = _gapPolicy,
  List<ChatMessage> visible = const [],
  Set<String> continuity = const {},
  Map<String, int> swipes = const {},
  String focalUserName = '',
  LedgerProjectionFreshness freshness = LedgerProjectionFreshness.provenCurrent,
}) => SelectiveLedgerProjectionFilter.select(
  _input(
    projection,
    policy,
    visible: visible,
    continuity: continuity,
    swipes: swipes,
    focalUserName: focalUserName,
    freshness: freshness,
  ),
);

SelectiveLedgerProjectionInput _input(
  EffectiveCanonPromptProjection projection,
  LedgerPromptInjectionPolicy policy, {
  List<ChatMessage> visible = const [],
  Set<String> continuity = const {},
  Map<String, int> swipes = const {},
  String focalUserName = '',
  String path = 'ordinary',
  LedgerProjectionFreshness freshness = LedgerProjectionFreshness.provenCurrent,
}) => SelectiveLedgerProjectionInput(
  policy: policy,
  consumerPath: path,
  projection: projection,
  visibleMessages: visible,
  selectedSwipeByMessageId: swipes,
  focalUserName: focalUserName,
  structuredContinuitySourceIds: continuity,
  freshness: freshness,
);

EffectiveCanonPromptProjection _projection({
  List<CharacterKnowledgeFact> facts = const [],
  List<Tracker> trackers = const [],
  List<EffectiveCanonTransitionProjection> transitions = const [],
  List<String>? claims,
}) => EffectiveCanonPromptProjection(
  facts: facts,
  trackers: trackers,
  transitions: transitions,
  unblockedTransitionClaims:
      claims ?? transitions.map((item) => item.claim).toList(),
  revisionNumber: 1,
  revisionHash: 'revision',
  cacheIdentity: 'canon-cache',
);

CharacterKnowledgeFact _fact({
  String id = 'fact-1',
  String source = 'source-1',
  String knowerKey = 'david',
  String knowerName = 'David',
  String subjectKey = 'lucy',
  String subjectName = 'Lucy',
  CharacterKnowledgeFactClass factClass = CharacterKnowledgeFactClass.knowledge,
  CharacterKnowledgeFactLifecycle lifecycle =
      CharacterKnowledgeFactLifecycle.active,
  CharacterKnowledgeEpistemicState epistemic =
      CharacterKnowledgeEpistemicState.confirmed,
  String object = 'the truth',
}) => CharacterKnowledgeFact(
  id: id,
  chatSessionId: 's',
  knowerKey: knowerKey,
  knowerName: knowerName,
  subjectKey: subjectKey,
  subjectName: subjectName,
  factClass: factClass,
  scopeKey: 'fact:$id',
  predicate: 'knows',
  object: object,
  epistemicState: epistemic,
  sourceMessageId: source,
  sourceSwipeId: 0,
  sourceAgentSwipeId: 0,
  lifecycle: lifecycle,
);

Tracker _tracker(String name, String value, {String provenance = ''}) =>
    Tracker(sessionId: 's', name: name, value: value, provenance: provenance);

ChatMessage _message(
  String id,
  String content, {
  bool hidden = false,
  bool typing = false,
  int swipe = 0,
}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  isHidden: hidden,
  isTyping: typing,
  swipeId: swipe,
);
