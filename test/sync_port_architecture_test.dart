import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AgentRunner does not import feature providers', () {
    final file = File('lib/core/llm/agent_runner.dart');
    final featureImport = RegExp(r'''import\s+['"][^'"]*features/''');

    expect(
      file.readAsStringSync(),
      isNot(matches(featureImport)),
      reason: '${file.path} must receive values and callbacks by constructor',
    );
  });

  test('VectorRebuildService does not import features or Riverpod', () {
    final file = File('lib/core/llm/vector_rebuild_service.dart');
    final forbiddenImport = RegExp(
      r'''import\s+['"][^'"]*(?:features/|flutter_riverpod)[^'"]*['"]''',
    );

    expect(
      file.readAsStringSync(),
      isNot(matches(forbiddenImport)),
      reason: '${file.path} must receive dependencies by constructor',
    );
  });

  test('lorebook LLM implementations remain provider-free', () {
    expect(
      File('lib/core/llm/lorebook_providers.dart').existsSync(),
      isFalse,
      reason: 'Lorebook provider composition belongs in core/state',
    );

    final files = <File>[
      File('lib/core/llm/embedding_service.dart'),
      File('lib/core/llm/lorebook_embedding_service.dart'),
      File('lib/core/llm/lorebook_vector_search.dart'),
    ];
    final riverpodImport = RegExp(
      r'''import\s+['"][^'"]*flutter_riverpod[^'"]*['"]''',
    );
    final providerDefinition = RegExp(
      r'''\b(?:Provider|FutureProvider|StreamProvider|NotifierProvider|AsyncNotifierProvider)\s*<''',
    );

    for (final file in files) {
      final source = file.readAsStringSync();
      expect(
        source,
        isNot(matches(riverpodImport)),
        reason: '${file.path} must receive dependencies by constructor',
      );
      expect(
        source,
        isNot(matches(providerDefinition)),
        reason: '${file.path} must not define provider composition',
      );
    }
  });

  test('core repositories do not import cloud sync features', () {
    final files = <File>[
      ...Directory('lib/core/db/repositories')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
    ];
    final featureCloudSyncImport = RegExp(
      r'''import\s+['"][^'"]*features/cloud_sync/''',
    );

    for (final file in files) {
      expect(
        file.readAsStringSync(),
        isNot(matches(featureCloudSyncImport)),
        reason: '${file.path} must depend on the neutral sync port',
      );
    }
  });

  test('neutral sync ports do not import feature models', () {
    final files = <File>[
      File('lib/core/application/sync_repo_interfaces.dart'),
      File('lib/shared/application/sync_theme_store.dart'),
    ];
    final featureImport = RegExp(r'''import\s+['"][^'"]*features/''');

    for (final file in files) {
      expect(
        file.readAsStringSync(),
        isNot(matches(featureImport)),
        reason: '${file.path} must remain below the feature layer',
      );
    }
  });
}
