import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

void main() {
  Character character({Map<String, dynamic> extensions = const {}}) =>
      Character(
        id: 'local-id',
        name: 'Ada',
        description: null,
        alternateGreetings: const ['Hello', 'Again'],
        depthPrompt: 'Stay in character.',
        depthPromptDepth: 6,
        depthPromptRole: 'system',
        extensions: extensions,
      );

  test('canonical card serialization is stable and normalizes null text', () {
    final first = character(
      extensions: {
        'z': {'beta': 2, 'alpha': 1},
        'a': true,
      },
    );
    final second = character(
      extensions: {
        'a': true,
        'z': {'alpha': 1, 'beta': 2},
      },
    ).copyWith(description: '');

    expect(
      CardCanonicalizer.serialize(first),
      CardCanonicalizer.serialize(second),
    );
    expect(CardCanonicalizer.sha256(first), CardCanonicalizer.sha256(second));
    expect(
      CardCanonicalizer.serialize(first),
      contains('"alternateGreetings"'),
    );
    expect(
      CardCanonicalizer.serialize(first),
      contains('"depthPromptDepth":6'),
    );
  });

  test(
    'canonical card excludes UI and gallery metadata but includes extensions',
    () {
      final base = character(extensions: {'custom': 'one'});
      final uiOnly = base.copyWith(
        avatarPath: '/tmp/avatar.png',
        color: '#fff',
        updatedAt: 5,
        currentSessionIndex: 9,
        fav: true,
        hidden: true,
        characterVersion: '999',
      );
      final changedExtension = base.copyWith(extensions: {'custom': 'two'});

      expect(CardCanonicalizer.sha256(uiOnly), CardCanonicalizer.sha256(base));
      expect(
        CardCanonicalizer.sha256(changedExtension),
        isNot(CardCanonicalizer.sha256(base)),
      );
    },
  );

  test('policy has the exact writable field allowlist', () {
    expect(
      CardRewritePolicy.modelWritableFields,
      unorderedEquals(
        CardRewriteField.values.where(
          (field) => field != CardRewriteField.creatorNotes,
        ),
      ),
    );
    expect(
      CardRewritePolicy.writableFields,
      unorderedEquals(CardRewriteField.values),
    );
  });

  test('model-facing snapshot excludes creator notes', () {
    final character = Character(
      id: 'character',
      name: 'Ada',
      creatorNotes: 'CREATOR_NOTES_MUST_NOT_REACH_MODEL_7F3A',
      extensions: const {
        'creator_notes': 'CREATOR_NOTES_MUST_NOT_REACH_MODEL_7F3A',
        'nested': {
          'creatorNotes': 'CREATOR_NOTES_MUST_NOT_REACH_MODEL_7F3A',
          'kept': 'value',
        },
      },
    );

    expect(CardCanonicalizer.snapshot(character), contains('creatorNotes'));
    expect(
      CardCanonicalizer.promptSnapshot(character),
      isNot(contains('creatorNotes')),
    );
    final promptJson = CardCanonicalizer.promptSnapshot(character).toString();
    expect(promptJson, isNot(contains('CREATOR_NOTES_MUST_NOT_REACH_MODEL')));
    expect(promptJson, contains('kept: value'));
  });

  test('scope grammar accepts only the defined semantic mappings', () {
    for (final key in const [
      'npc:ada',
      'relationship:Lucy:Danvi',
      'arc:act_1',
      'world:earth-2',
      'world:Bad',
      'scene.opening.bridge',
    ]) {
      expect(CardRewriteScope.tryParse(key), isNotNull, reason: key);
    }
    for (final key in const [
      'character:ada',
      'scene:opening',
      'npc:',
      'world:Bad:Nested',
      'relationship:ada-lovelace',
      'relationship:Lucy::Danvi',
    ]) {
      expect(CardRewriteScope.tryParse(key), isNull, reason: key);
    }
  });

  test(
    'anchored patch validator reports stale, duplicate, and full-set violations',
    () {
      final current = {
        for (final field in CardRewriteField.values)
          field: 'old-${field.wireName}',
      };
      AnchoredScalarPatch patch(
        CardRewriteField field, {
        String? anchor,
        String? value,
      }) => AnchoredScalarPatch(
        scopeKey: 'npc:ada',
        field: field,
        anchor: current[field]!,
        anchorSha256: anchor ?? CardCanonicalizer.scalarSha256(current[field]!),
        value: value ?? 'new-${field.wireName}',
      );

      final invalid = AnchoredScalarPatchValidator.validate(
        currentCardValues: current,
        patches: [
          patch(CardRewriteField.description),
          patch(CardRewriteField.description),
          patch(CardRewriteField.personality, anchor: 'outdated'),
          patch(CardRewriteField.scenario),
        ],
        requiredFields: CardRewriteField.values,
      );

      expect(invalid.isValid, isFalse);
      expect(
        invalid.violations,
        containsAll([
          CardPatchViolation.duplicateAnchor,
          CardPatchViolation.staleAnchor,
          CardPatchViolation.incompleteSet,
        ]),
      );
    },
  );

  test('multiple distinct anchored fragments in one field are valid', () {
    final current = <CardRewriteField, String?>{
      CardRewriteField.description: 'first fragment second fragment',
    };
    final result = AnchoredScalarPatchValidator.validate(
      currentCardValues: current,
      patches: [
        AnchoredScalarPatch(
          scopeKey: 'npc:ada',
          field: CardRewriteField.description,
          anchor: 'first fragment',
          anchorSha256: CardCanonicalizer.scalarSha256('first fragment'),
          value: 'first rewrite',
        ),
        AnchoredScalarPatch(
          scopeKey: 'npc:ada',
          field: CardRewriteField.description,
          anchor: 'second fragment',
          anchorSha256: CardCanonicalizer.scalarSha256('second fragment'),
          value: 'second rewrite',
        ),
      ],
    );

    expect(result.isValid, isTrue);
  });

  test('anchored patches preserve the exact macro-token multiset', () {
    const anchor = '{{char}} meets {{user}} and {{char}} smiles.';
    AnchoredScalarPatch patch(String value) => AnchoredScalarPatch(
      scopeKey: 'npc:ada',
      field: CardRewriteField.description,
      anchor: anchor,
      anchorSha256: CardCanonicalizer.scalarSha256(anchor),
      value: value,
    );
    final rejected = AnchoredScalarPatchValidator.validate(
      currentCardValues: {CardRewriteField.description: anchor},
      patches: [patch('{{char}} meets {{user}} and smiles.')],
    );
    final accepted = AnchoredScalarPatchValidator.validate(
      currentCardValues: {CardRewriteField.description: anchor},
      patches: [patch('{{char}} warmly meets {{user}}; {{char}} smiles.')],
    );
    expect(
      rejected.violations,
      contains(CardPatchViolation.macroTokensChanged),
    );
    expect(accepted.isValid, isTrue);
  });

  test(
    'anchors must occur exactly once and duplicate targets ignore scope',
    () {
      final anchor = CardCanonicalizer.scalarSha256('repeat');
      final result = AnchoredScalarPatchValidator.validate(
        currentCardValues: {CardRewriteField.description: 'repeat repeat'},
        patches: [
          AnchoredScalarPatch(
            scopeKey: 'npc:ada',
            field: CardRewriteField.description,
            anchor: 'repeat',
            anchorSha256: anchor,
            value: 'one',
          ),
          AnchoredScalarPatch(
            scopeKey: 'npc:bob',
            field: CardRewriteField.description,
            anchor: 'repeat',
            anchorSha256: anchor,
            value: 'two',
          ),
        ],
      );
      expect(result.violations, contains(CardPatchViolation.ambiguousAnchor));
      expect(result.violations, contains(CardPatchViolation.duplicateAnchor));
    },
  );

  test('does not reject a large replacement by size', () {
    final result = AnchoredScalarPatchValidator.validate(
      currentCardValues: {CardRewriteField.description: 'anchor text'},
      patches: [
        AnchoredScalarPatch(
          scopeKey: 'npc:ada',
          field: CardRewriteField.description,
          anchor: 'anchor text',
          anchorSha256: CardCanonicalizer.scalarSha256('anchor text'),
          value: 'x' * 100000,
        ),
      ],
    );

    expect(result.isValid, isTrue);
  });
}
