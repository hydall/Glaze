import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_use_manifest_repo.dart';
import 'package:glaze_flutter/core/llm/prompt/exact_lorebook_manifest.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/features/chat/services/generation_pipeline.dart';

void main() {
  test('valid manifest remains available for the atomic generation commit', () {
    final manifest = _manifest(source: 'keyword');

    expect(validateGenerationManifestForCommit(manifest), isNotNull);
  });

  test('invalid manifest cannot roll back a generated swipe', () {
    final manifest = _manifest(source: 'invalid-source');

    expect(validateGenerationManifestForCommit(manifest), isNull);
  });

  test(
    'manifest conflict retries the guarded message commit without it',
    () async {
      final manifest = _manifest(source: 'keyword');
      final attempts = <ExactLorebookManifest?>[];
      var failureReported = false;

      final result = await commitGenerationWithManifestFallback<String>(
        manifest: manifest,
        commit: (candidate) async {
          attempts.add(candidate);
          if (candidate != null) {
            throw const LorebookUseManifestIntegrityConflict('conflict');
          }
          return 'saved swipe';
        },
        onManifestFailure: () => failureReported = true,
      );

      expect(result, 'saved swipe');
      expect(attempts, [same(manifest), isNull]);
      expect(failureReported, isTrue);
    },
  );
}

ExactLorebookManifest _manifest({required String source}) =>
    ExactLorebookManifest(
      entries: [
        ExactLorebookManifestEntry.fromMergedEntry(
          entry: const LorebookEntry(
            id: 'entry',
            lorebookId: 'book',
            content: 'lore',
            position: 'worldInfoBefore',
          ),
          source: source,
          classification: 'worldInfoBefore',
          injectionIndex: 0,
          renderedContent: 'lore',
        ),
      ],
      promptProvenance: const ExactLorebookPromptProvenance(
        characterId: 'character',
        presetSnapshotHash: 'preset',
      ),
      providerMessagesHash: 'provider',
    );
