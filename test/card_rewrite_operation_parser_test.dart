import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewrite_operation_parser.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewrite_prompt_builder.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

void main() {
  const scope = 'npc:ada';
  const anchor = 'A {{char}} who assists {{user}}.';
  const value = 'A {{char}} who aids {{user}} patiently.';

  Map<String, Object?> validPatch() => {
    'scopeKey': scope,
    'anchor': anchor,
    'anchorSha256': CardCanonicalizer.scalarSha256(anchor),
    'value': value,
  };

  Map<String, Object?> validTransition() => {
    'id': 'transition-1',
    'scopeKey': scope,
    'canonicalClaim': 'claim',
    'promotionDestination': 'card',
    'affectedTrackerKeys': const <String>[],
    'factIds': const <String>[],
    'chatSessionId': null,
  };

  Map<String, Object?> validPayload() => {
    'field': 'description',
    'patches': [validPatch()],
    'transition': validTransition(),
  };

  CardRewriteOperationParseResult parsePayload(
    Map<String, Object?> payload, {
    CardRewriteField expectedField = CardRewriteField.description,
  }) => CardRewriteOperationParser.parse(
    jsonEncode(payload),
    expectedField: expectedField,
  );

  CardRewriteOperationParseRejection rejectionOf(Map<String, Object?> payload) {
    final result = parsePayload(payload);
    expect(result.isSuccess, isFalse, reason: 'expected parse failure');
    expect(result.snapshot, isNull);
    return result.rejection!;
  }

  test('parses a well-formed payload into a typed snapshot', () {
    final result = parsePayload(validPayload());
    expect(result.isSuccess, isTrue, reason: result.detail);
    expect(result.rejection, isNull);
    final snapshot = result.snapshot!;
    expect(snapshot.field, CardRewriteField.description);
    expect(snapshot.patches, hasLength(1));
    final patch = snapshot.patches.single;
    expect(patch.scopeKey, scope);
    expect(patch.anchor, anchor);
    expect(patch.anchorSha256, CardCanonicalizer.scalarSha256(anchor));
    expect(patch.value, value);
    expect(snapshot.transition.id, 'transition-1');
    expect(snapshot.transition.scopeKey, scope);
    expect(snapshot.transition.canonicalClaim, 'claim');
    expect(snapshot.transition.promotionDestination, 'card');
    expect(snapshot.transition.affectedTrackerKeys, isEmpty);
    expect(snapshot.transition.factIds, isEmpty);
    expect(snapshot.transition.chatSessionId, isNull);
  });

  test('preserves exact Unicode scope subjects from model output', () {
    final payload = validPayload();
    (payload['patches'] as List).single['scopeKey'] = 'relationship:Lucy:Danvi';
    (payload['transition'] as Map<String, Object?>)['scopeKey'] =
        'relationship:Lucy:Danvi';

    final result = parsePayload(payload);

    expect(result.isSuccess, isTrue, reason: result.detail);
    expect(result.snapshot!.patches.single.scopeKey, 'relationship:Lucy:Danvi');
    expect(result.snapshot!.transition.scopeKey, 'relationship:Lucy:Danvi');
  });

  test(
    'accepts nested Unicode relationship identities and rejects unsafe text',
    () {
      for (final scope in ['relationship:Гильда:Квинн']) {
        final payload = validPayload();
        (payload['patches'] as List).single['scopeKey'] = scope;
        (payload['transition'] as Map<String, Object?>)['scopeKey'] = scope;
        expect(parsePayload(payload).isSuccess, isTrue, reason: scope);
      }
      for (final scope in [
        'relationship: Lucy',
        'relationship:Гильда::Квинн',
        'relationship:Lucy\u202eevil',
        'relationship:Lucy\nDanvi',
      ]) {
        final payload = validPayload();
        (payload['patches'] as List).single['scopeKey'] = scope;
        (payload['transition'] as Map<String, Object?>)['scopeKey'] = scope;
        expect(parsePayload(payload).isSuccess, isFalse, reason: scope);
      }
    },
  );

  test('tolerates markdown fences and surrounding prose', () {
    final fenced =
        'Here is the rewrite you asked for:\n'
        '```json\n${jsonEncode(validPayload())}\n```\n'
        'Hope that helps.';
    final result = CardRewriteOperationParser.parse(
      fenced,
      expectedField: CardRewriteField.description,
    );
    expect(result.isSuccess, isTrue, reason: result.detail);
    expect(result.snapshot!.patches.single.anchor, anchor);
  });

  test('tolerates trailing commas and comments via json repair', () {
    final sloppy =
        '{'
        '"field": "description", // target field\n'
        '"patches": [{"scopeKey": "$scope", "anchor": "$anchor",'
        ' "anchorSha256": "${CardCanonicalizer.scalarSha256(anchor)}",'
        ' "value": "$value",},],\n'
        '"transition": {"id": "transition-1", "scopeKey": "$scope",'
        ' "canonicalClaim": "claim", "promotionDestination": "card",'
        ' "affectedTrackerKeys": [],},\n'
        '}';
    final result = CardRewriteOperationParser.parse(
      sloppy,
      expectedField: CardRewriteField.description,
    );
    expect(result.isSuccess, isTrue, reason: result.detail);
  });

  test('rejects output without a JSON payload', () {
    final result = CardRewriteOperationParser.parse(
      'I could not produce a rewrite.',
      expectedField: CardRewriteField.description,
    );
    expect(result.isSuccess, isFalse);
    expect(result.rejection, CardRewriteOperationParseRejection.noJsonPayload);
  });

  test('explains a rejected card evolution batch', () {
    expect(
      CardRewriteOperationParser.explainEvolutionBatchFailure('not json'),
      'no JSON object was found',
    );
    expect(
      CardRewriteOperationParser.explainEvolutionBatchFailure(
        '{"operations": [{"field": "unknown"}]}',
      ),
      'field is unsupported or repeated',
    );
  });

  test('evolution batches recompute model-supplied anchor hashes', () {
    final payload = validPayload();
    (payload['patches'] as List).single['anchorSha256'] = 'not-a-real-hash';

    final operations = CardRewriteOperationParser.parseEvolutionBatch(
      jsonEncode({
        'operations': [payload],
      }),
    );

    expect(operations, hasLength(1));
    expect(
      operations!.single.patches.single.anchorSha256,
      CardCanonicalizer.scalarSha256(anchor),
    );
  });

  test('evolution batches reject repeated transition ids', () {
    final first = validPayload();
    final second = validPayload()
      ..['field'] = 'personality';

    expect(
      CardRewriteOperationParser.explainEvolutionBatchFailure(
        jsonEncode({
          'operations': [first, second],
        }),
      ),
      'transition id is repeated',
    );
  });

  test('rejects multiple concatenated JSON payloads', () {
    final result = CardRewriteOperationParser.parse(
      '${jsonEncode(validPayload())}\n${jsonEncode(validPayload())}',
      expectedField: CardRewriteField.description,
    );
    expect(result.isSuccess, isFalse);
    expect(result.rejection, CardRewriteOperationParseRejection.invalidJson);
  });

  test('rejects an empty object', () {
    final result = CardRewriteOperationParser.parse(
      '{}',
      expectedField: CardRewriteField.description,
    );
    expect(result.isSuccess, isFalse);
    expect(result.rejection, CardRewriteOperationParseRejection.unknownField);
  });

  test('rejects unknown top-level keys', () {
    final payload = validPayload()..['explanation'] = 'why';
    expect(rejectionOf(payload), CardRewriteOperationParseRejection.unknownKey);
  });

  test('rejects unknown patch keys, including a patch-level field', () {
    final extra = validPayload();
    (extra['patches']! as List<Object?>)[0] = validPatch()..['note'] = 'x';
    expect(rejectionOf(extra), CardRewriteOperationParseRejection.unknownKey);

    final multiField = validPayload();
    (multiField['patches']! as List<Object?>)[0] = validPatch()
      ..['field'] = 'personality';
    expect(
      rejectionOf(multiField),
      CardRewriteOperationParseRejection.unknownKey,
    );
  });

  test('rejects unknown transition keys', () {
    final payload = validPayload();
    (payload['transition']! as Map<String, Object?>)['extra'] = 1;
    expect(rejectionOf(payload), CardRewriteOperationParseRejection.unknownKey);
  });

  test('rejects non-writable and unknown fields', () {
    // `firstMes` is a real card field but not in the writable enum.
    expect(
      rejectionOf(validPayload()..['field'] = 'firstMes'),
      CardRewriteOperationParseRejection.unknownField,
    );
    expect(
      rejectionOf(validPayload()..['field'] = 'bogus'),
      CardRewriteOperationParseRejection.unknownField,
    );
  });

  test('rejects a writable field other than the requested target', () {
    final payload = validPayload()..['field'] = 'personality';
    (payload['patches']! as List<Object?>)[0] = validPatch()
      ..['value'] = 'Precise and warm.';
    expect(
      rejectionOf(payload),
      CardRewriteOperationParseRejection.fieldMismatch,
    );
  });

  test('rejects missing, non-list, and empty patches', () {
    final missing = validPayload()..remove('patches');
    expect(
      rejectionOf(missing),
      CardRewriteOperationParseRejection.patchesNotList,
    );
    final notList = validPayload()..['patches'] = const <String, Object?>{};
    expect(
      rejectionOf(notList),
      CardRewriteOperationParseRejection.patchesNotList,
    );
    final empty = validPayload()..['patches'] = const <Object?>[];
    expect(rejectionOf(empty), CardRewriteOperationParseRejection.emptyPatches);
  });

  test('rejects malformed patches', () {
    final notObject = validPayload()
      ..['patches'] = const <Object?>['not-a-patch'];
    expect(
      rejectionOf(notObject),
      CardRewriteOperationParseRejection.malformedPatch,
    );
    final missingMember = validPatch()..remove('value');
    final missingValue = validPayload()..['patches'] = [missingMember];
    expect(
      rejectionOf(missingValue),
      CardRewriteOperationParseRejection.malformedPatch,
    );
    final nonStringMember = validPayload()
      ..['patches'] = [validPatch()..['value'] = 42];
    expect(
      rejectionOf(nonStringMember),
      CardRewriteOperationParseRejection.malformedPatch,
    );
  });

  test('rejects empty anchor strings', () {
    final payload = validPayload()
      ..['patches'] = [
        validPatch()
          ..['anchor'] = ''
          ..['anchorSha256'] = CardCanonicalizer.scalarSha256(''),
      ];
    expect(
      rejectionOf(payload),
      CardRewriteOperationParseRejection.emptyAnchor,
    );
  });

  test('recomputes the anchor hash and tolerates missing or bogus values', () {
    // The model contract no longer asks for anchorSha256; when absent the
    // parser computes it, and a fabricated value is overwritten.
    final missing = validPayload()
      ..['patches'] = [validPatch()..remove('anchorSha256')];
    final missingResult = parsePayload(missing);
    expect(missingResult.isSuccess, isTrue, reason: missingResult.detail);
    expect(
      missingResult.snapshot!.patches.single.anchorSha256,
      CardCanonicalizer.scalarSha256(anchor),
    );

    for (final bogus in [
      'not-the-real-hash',
      CardCanonicalizer.scalarSha256('other text'),
    ]) {
      final payload = validPayload()
        ..['patches'] = [validPatch()..['anchorSha256'] = bogus];
      final result = parsePayload(payload);
      expect(result.isSuccess, isTrue, reason: bogus);
      expect(
        result.snapshot!.patches.single.anchorSha256,
        CardCanonicalizer.scalarSha256(anchor),
      );
    }

    // A non-string value is still structurally rejected.
    final nonString = validPayload()
      ..['patches'] = [validPatch()..['anchorSha256'] = 42];
    expect(
      rejectionOf(nonString),
      CardRewriteOperationParseRejection.malformedPatch,
    );
  });

  test('rejects replacements that change anchored macro tokens', () {
    for (final replacement in [
      'A {{char}} who assists.',
      'A {{character}} who assists {{user}}.',
      'A {{char}} who assists {{user}} for {{user}}.',
    ]) {
      final payload = validPayload();
      (payload['patches']! as List<Object?>)[0] = validPatch()
        ..['value'] = replacement;
      final result = parsePayload(payload);
      expect(
        result.rejection,
        CardRewriteOperationParseRejection.macroTokensChanged,
      );
      expect(result.detail, contains('macro-token multiset'));
    }
  });

  test('accepts replacements preserving repeated macro tokens exactly', () {
    const macroAnchor = '{{char}} greets {{user}} and {{char}} waits.';
    final payload = validPayload();
    (payload['patches']! as List<Object?>)[0] = validPatch()
      ..['anchor'] = macroAnchor
      ..['anchorSha256'] = CardCanonicalizer.scalarSha256(macroAnchor)
      ..['value'] = '{{char}} warmly greets {{user}}, then {{char}} waits.';
    expect(parsePayload(payload).isSuccess, isTrue);
  });

  test('rejects unparsable patch and transition scope keys', () {
    final badPatchScope = validPayload()
      ..['patches'] = [validPatch()..['scopeKey'] = 'scene:opening'];
    expect(
      rejectionOf(badPatchScope),
      CardRewriteOperationParseRejection.invalidScope,
    );
    final badTransitionScope = validPayload();
    (badTransitionScope['transition']! as Map<String, Object?>)['scopeKey'] =
        'world:Bad:Nested';
    expect(
      rejectionOf(badTransitionScope),
      CardRewriteOperationParseRejection.invalidScope,
    );
  });

  test(
    'accepts a large replacement when its patch contract is otherwise valid',
    () {
      final oversized = '${'x' * 12001} {{char}} {{user}}';
      final payload = validPayload()
        ..['patches'] = [validPatch()..['value'] = oversized];
      expect(parsePayload(payload).isSuccess, isTrue);
    },
  );

  test('rejects malformed transitions', () {
    final notObject = validPayload()..['transition'] = 'not-an-object';
    expect(
      rejectionOf(notObject),
      CardRewriteOperationParseRejection.malformedTransition,
    );
    final emptyId = validPayload();
    (emptyId['transition']! as Map<String, Object?>)['id'] = '';
    expect(
      rejectionOf(emptyId),
      CardRewriteOperationParseRejection.malformedTransition,
    );
    final emptyTrackerKey = validPayload();
    (emptyTrackerKey['transition']!
        as Map<String, Object?>)['affectedTrackerKeys'] = const [
      '',
    ];
    expect(
      rejectionOf(emptyTrackerKey),
      CardRewriteOperationParseRejection.malformedTransition,
    );
    final emptyFactId = validPayload();
    (emptyFactId['transition']! as Map<String, Object?>)['factIds'] = const [
      '',
    ];
    expect(
      rejectionOf(emptyFactId),
      CardRewriteOperationParseRejection.malformedTransition,
    );
  });

  test('rejects missing or empty canonicalClaim / promotionDestination', () {
    final noClaim = validPayload();
    (noClaim['transition']! as Map<String, Object?>).remove('canonicalClaim');
    expect(
      rejectionOf(noClaim),
      CardRewriteOperationParseRejection.missingCanonicalClaim,
    );
    final emptyClaim = validPayload();
    (emptyClaim['transition']! as Map<String, Object?>)['canonicalClaim'] = '';
    expect(
      rejectionOf(emptyClaim),
      CardRewriteOperationParseRejection.missingCanonicalClaim,
    );
    final noDestination = validPayload();
    (noDestination['transition']! as Map<String, Object?>).remove(
      'promotionDestination',
    );
    expect(
      rejectionOf(noDestination),
      CardRewriteOperationParseRejection.missingPromotionDestination,
    );
    final emptyDestination = validPayload();
    (emptyDestination['transition']!
            as Map<String, Object?>)['promotionDestination'] =
        '';
    expect(
      rejectionOf(emptyDestination),
      CardRewriteOperationParseRejection.missingPromotionDestination,
    );
  });

  test('requires affectedTrackerKeys while allowing an empty list', () {
    final missing = validPayload();
    (missing['transition']! as Map<String, Object?>).remove(
      'affectedTrackerKeys',
    );
    expect(
      rejectionOf(missing),
      CardRewriteOperationParseRejection.missingAffectedTrackerKeys,
    );

    final empty = validPayload();
    (empty['transition']! as Map<String, Object?>)['affectedTrackerKeys'] =
        const <String>[];
    final result = parsePayload(empty);
    expect(result.isSuccess, isTrue, reason: result.detail);
    expect(result.snapshot!.transition.affectedTrackerKeys, isEmpty);

    final populated = validPayload();
    (populated['transition']! as Map<String, Object?>)['affectedTrackerKeys'] =
        const ['mood'];
    final populatedResult = parsePayload(populated);
    expect(populatedResult.isSuccess, isTrue, reason: populatedResult.detail);
    expect(
      populatedResult.snapshot!.transition.affectedTrackerKeys,
      equals(const ['mood']),
    );
  });

  test('rejects non-global transitions', () {
    final payload = validPayload();
    (payload['transition']! as Map<String, Object?>)['chatSessionId'] =
        'session-1';
    expect(
      rejectionOf(payload),
      CardRewriteOperationParseRejection.nonGlobalTransition,
    );

    // Absent or explicit null chatSessionId stays global and parses.
    final absent = validPayload();
    (absent['transition']! as Map<String, Object?>).remove('chatSessionId');
    expect(
      parsePayload(absent).isSuccess,
      isTrue,
      reason: 'absent chatSessionId must stay global',
    );
  });

  test('rejects patches whose scope differs from the transition scope', () {
    final payload = validPayload();
    (payload['transition']! as Map<String, Object?>)['scopeKey'] = 'npc:bob';
    expect(
      rejectionOf(payload),
      CardRewriteOperationParseRejection.scopeMismatch,
    );
  });

  test('parsed patches pass the anchored patch validator', () {
    final card = Character(id: 'c', name: 'Ada', description: anchor);
    final result = parsePayload(validPayload());
    expect(result.isSuccess, isTrue, reason: result.detail);
    final validation = AnchoredScalarPatchValidator.validate(
      patches: result.snapshot!.patches,
      currentCardValues: {CardRewriteField.description: card.description},
    );
    expect(validation.isValid, isTrue, reason: '${validation.violations}');
  });

  group('ManualRewriteOperationSnapshotCodec', () {
    test('encodes the exact durable shape accepted by manual apply', () {
      final snapshot = parsePayload(validPayload()).snapshot!;
      final encoded = ManualRewriteOperationSnapshotCodec.encode(snapshot);
      final expected =
          '{"field":"description","patches":[{"scopeKey":"$scope",'
          '"anchor":"$anchor",'
          '"anchorSha256":"${CardCanonicalizer.scalarSha256(anchor)}",'
          '"value":"$value"}],'
          '"transition":{"id":"transition-1","scopeKey":"$scope",'
          '"canonicalClaim":"claim","promotionDestination":"card",'
          '"affectedTrackerKeys":[],"factIds":[],"chatSessionId":null}}';
      expect(encoded, expected);
      expect(
        jsonDecode(encoded),
        equals(<String, Object?>{
          'field': 'description',
          'patches': [
            {
              'scopeKey': scope,
              'anchor': anchor,
              'anchorSha256': CardCanonicalizer.scalarSha256(anchor),
              'value': value,
            },
          ],
          'transition': {
            'id': 'transition-1',
            'scopeKey': scope,
            'canonicalClaim': 'claim',
            'promotionDestination': 'card',
            'affectedTrackerKeys': const <String>[],
            'factIds': const <String>[],
            'chatSessionId': null,
          },
        }),
      );
    });

    test('round-trips deterministically through jsonDecode', () {
      final snapshot = parsePayload(validPayload()).snapshot!;
      final encoded = ManualRewriteOperationSnapshotCodec.encode(snapshot);
      final decoded = ManualRewriteOperationSnapshotCodec.tryDecode(
        jsonDecode(encoded),
      );
      expect(decoded, isNotNull);
      final reencoded = ManualRewriteOperationSnapshotCodec.encode(decoded!);
      expect(reencoded, encoded);
      expect(
        ManualRewriteOperationSnapshotCodec.encode(decoded),
        ManualRewriteOperationSnapshotCodec.encode(snapshot),
      );
    });

    test('tryDecode applies the apply-side defaults', () {
      final source =
          jsonDecode(
                ManualRewriteOperationSnapshotCodec.encode(
                  parsePayload(validPayload()).snapshot!,
                ),
              )
              as Map<String, Object?>;
      (source['transition']! as Map<String, Object?>)
        ..remove('factIds')
        ..remove('promotionDestination');
      final decoded = ManualRewriteOperationSnapshotCodec.tryDecode(source);
      expect(decoded, isNotNull);
      expect(decoded!.transition.factIds, isEmpty);
      expect(decoded.transition.promotionDestination, '');
    });

    test('tryDecode rejects structurally unusable snapshots', () {
      final valid =
          jsonDecode(
                ManualRewriteOperationSnapshotCodec.encode(
                  parsePayload(validPayload()).snapshot!,
                ),
              )
              as Map<String, Object?>;
      expect(ManualRewriteOperationSnapshotCodec.tryDecode(null), isNull);
      expect(ManualRewriteOperationSnapshotCodec.tryDecode('x'), isNull);
      expect(
        ManualRewriteOperationSnapshotCodec.tryDecode(
          valid..['field'] = 'firstMes',
        ),
        isNull,
      );
      expect(
        ManualRewriteOperationSnapshotCodec.tryDecode(
          jsonDecode(
                  ManualRewriteOperationSnapshotCodec.encode(
                    parsePayload(validPayload()).snapshot!,
                  ),
                )
                as Map<String, Object?>
            ..['patches'] = const <Object?>[],
        ),
        isNull,
      );
      expect(
        ManualRewriteOperationSnapshotCodec.tryDecode(
          jsonDecode(
                  ManualRewriteOperationSnapshotCodec.encode(
                    parsePayload(validPayload()).snapshot!,
                  ),
                )
                as Map<String, Object?>
            ..remove('transition'),
        ),
        isNull,
      );
    });
  });

  group('Lorebook evolution operations', () {
    test('round-trips a tagged lorebook operation', () {
      const content = 'The district is dangerous.';
      final snapshot = LorebookRewriteOperationSnapshot(
        lorebookId: 'book',
        entryId: 'district',
        baseContent: content,
        expectedContentHash: CardCanonicalizer.scalarSha256(content),
        patches: [
          LorebookAnchoredPatch(
            anchor: 'dangerous',
            anchorSha256: CardCanonicalizer.scalarSha256('dangerous'),
            value: 'dangerous but lively',
          ),
        ],
      );

      final encoded = RewriteOperationSnapshotCodec.encode(snapshot);
      final decoded = RewriteOperationSnapshotCodec.tryDecode(
        jsonDecode(encoded),
      );

      expect(decoded, isA<LorebookRewriteOperationSnapshot>());
      final lore = decoded! as LorebookRewriteOperationSnapshot;
      expect(lore.lorebookId, 'book');
      expect(lore.entryId, 'district');
      expect(lore.patches.single.value, 'dangerous but lively');
    });

    test('parses only unique, well-formed lorebook targets', () {
      const content = 'The district is dangerous.';
      final output = jsonEncode({
        'operations': [
          {
            'lorebookId': 'book',
            'entryId': 'district',
            'baseContent': content,
            'expectedContentHash': CardCanonicalizer.scalarSha256(content),
            'patches': [
              {
                'anchor': 'dangerous',
                'anchorSha256': CardCanonicalizer.scalarSha256('dangerous'),
                'value': 'dangerous but lively',
              },
            ],
          },
        ],
      });

      final result = CardRewriteOperationParser.parseLorebookEvolutionBatch(
        output,
      );

      expect(result, hasLength(1));
      expect(result!.single.entryId, 'district');
    });

    test(
      'accepts a lorebook batch with fabricated or missing anchor hashes',
      () {
        // Regression for the live lorebook_writer failure: the model cannot
        // compute SHA-256 and fabricated digests, so the whole batch was
        // rejected as "not a valid operation batch".
        const content = 'The district is dangerous.';
        final operations = [
          {
            'lorebookId': 'book',
            'entryId': 'district',
            'baseContent': content,
            'expectedContentHash': CardCanonicalizer.scalarSha256(content),
            'patches': [
              {
                'anchor': 'dangerous',
                'anchorSha256': '3f7c1e2a5b8d9046e1a7c3b5d8f2e0a4',
                'value': 'dangerous but lively',
              },
            ],
          },
          {
            'lorebookId': 'book',
            'entryId': 'harbor',
            'baseContent': content,
            'expectedContentHash': CardCanonicalizer.scalarSha256(content),
            'patches': [
              {'anchor': 'dangerous', 'value': 'dangerous but lively'},
            ],
          },
        ];

        final result = CardRewriteOperationParser.parseLorebookEvolutionBatch(
          jsonEncode({'operations': operations}),
        );

        expect(result, hasLength(2));
        expect(
          result!.first.patches.single.anchorSha256,
          CardCanonicalizer.scalarSha256('dangerous'),
        );
        expect(
          result.last.patches.single.anchorSha256,
          CardCanonicalizer.scalarSha256('dangerous'),
        );
      },
    );
  });

  group('macro preservation round-trip', () {
    test(
      'macros flow through prompt build, mocked output, parse, and encode unchanged',
      () {
        final card = Character(
          id: 'c',
          name: 'Ada',
          description:
              'Ada greets {{user}} while {{char}} recalls {{memory_key}} '
              'and cites {{description}}.',
        );
        final prompt = CardRewriterPromptBuilder.build(
          character: card,
          field: CardRewriteField.description,
          instruction: 'Keep every macro literal.',
        );
        for (final macro in const [
          '{{user}}',
          '{{char}}',
          '{{description}}',
          '{{memory_key}}',
        ]) {
          expect(prompt, contains(macro), reason: macro);
        }

        const macroAnchor =
            'Ada greets {{user}} while {{char}} recalls {{memory_key}} and cites {{description}}.';
        const macroValue =
            'Ada warmly embraces {{user}} while {{char}} recalls {{memory_key}} and cites {{description}}.';
        final modelOutput = jsonEncode({
          'field': 'description',
          'patches': [
            {
              'scopeKey': scope,
              'anchor': macroAnchor,
              'anchorSha256': CardCanonicalizer.scalarSha256(macroAnchor),
              'value': macroValue,
            },
          ],
          'transition': {
            'id': 'transition-macro',
            'scopeKey': scope,
            'canonicalClaim': '{{char}} recalls {{memory_key}}',
            'promotionDestination': 'card',
            'affectedTrackerKeys': const <String>[],
          },
        });
        final parsed = CardRewriteOperationParser.parse(
          modelOutput,
          expectedField: CardRewriteField.description,
        );
        expect(parsed.isSuccess, isTrue, reason: parsed.detail);

        final encoded = ManualRewriteOperationSnapshotCodec.encode(
          parsed.snapshot!,
        );
        for (final macro in const [
          '{{user}}',
          '{{char}}',
          '{{description}}',
          '{{memory_key}}',
        ]) {
          expect(encoded, contains(macro), reason: macro);
        }
        final roundTripped = ManualRewriteOperationSnapshotCodec.tryDecode(
          jsonDecode(encoded),
        );
        expect(roundTripped, isNotNull);
        expect(roundTripped!.patches.single.anchor, macroAnchor);
        expect(roundTripped.patches.single.value, macroValue);
        expect(
          roundTripped.transition.canonicalClaim,
          '{{char}} recalls {{memory_key}}',
        );
      },
    );
  });
}
