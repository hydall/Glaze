import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UI→DB violations fixed (Phase 2.5)', () {
    final widgetFiles = <String>[
      'lib/features/chat/widgets/magic_drawer.dart',
      'lib/features/chat/widgets/summary_sheet.dart',
      'lib/features/chat/widgets/authors_note_sheet.dart',
      'lib/features/chat/widgets/chat_stats_sheet.dart',
      'lib/features/chat/widgets/lorebook_coverage_sheet.dart',
      // context_info_sheet.dart and chat_dialogs.dart were deleted in 0565341;
      // they are intentionally absent from this list.
      'lib/features/chat/widgets/memory_books_sheet.dart',
      'lib/features/regex/regex_sheet.dart',
      'lib/features/personas/persona_list_screen.dart',
      'lib/features/personas/persona_connections_sheet.dart',
      'lib/features/character_list/character_editor_screen.dart',
      'lib/features/character_list/character_detail_screen.dart',
      'lib/features/character_list/character_list_screen.dart',
      'lib/features/tools/tools_screen.dart',
      'lib/features/presets/preset_editor_screen.dart',
      'lib/features/picks/widgets/picks_detail_launcher.dart',
    ];

    test('all widget files exist on disk', () {
      for (final path in widgetFiles) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '$path should exist',
        );
      }
    });

    // Documented exception. chat_stats_sheet.dart reads sessions and characters
    // straight from chatRepoProvider/characterRepoProvider on purpose — see the
    // comments at its _initData(): the cached session provider is not
    // invalidated on message edits/deletions, so the stats counts would lag,
    // and a plain repo future is guaranteed to complete where the (async)
    // providers may stay unresolved and hand the sheet an empty list.
    // Deliberate, so the rule below skips it rather than the rule being deleted
    // for everyone else.
    final directRepoExceptions = <String>{
      'lib/features/chat/widgets/chat_stats_sheet.dart',
    };

    test('no widget files directly import *RepoProvider', () {
      for (final path in widgetFiles) {
        if (directRepoExceptions.contains(path)) continue;
        final source = File(path).readAsStringSync();

        // Check that files don't directly use repo providers for data access
        // Note: Some files may still import db_provider.dart for other providers
        // like imageStorageProvider or characterImporterProvider
        final hasDirectRepoUsage = source.contains('ref.read(characterRepoProvider)') ||
            source.contains('ref.watch(characterRepoProvider)') ||
            source.contains('ref.read(chatRepoProvider)') ||
            source.contains('ref.watch(chatRepoProvider)') ||
            source.contains('ref.read(presetRepoProvider)') ||
            source.contains('ref.watch(presetRepoProvider)') ||
            source.contains('ref.read(personaRepoProvider)') ||
            source.contains('ref.watch(personaRepoProvider)') ||
            source.contains('ref.read(lorebookRepoProvider)') ||
            source.contains('ref.watch(lorebookRepoProvider)');
        
        expect(
          hasDirectRepoUsage,
          isFalse,
          reason: '$path should not directly call *RepoProvider (use higher-level providers instead)',
        );
      }
    });

    test('total widget files count is 15', () {
      expect(widgetFiles.length, 15);
    });

    test('no .put() calls on repos in widget code', () async {
      final mutationPattern =
          RegExp(r'ref\.read\(\w+RepoProvider\)\s*\.put\(');
      var foundMutations = 0;
      for (final path in widgetFiles) {
        final source = File(path).readAsStringSync();
        if (mutationPattern.hasMatch(source)) {
          foundMutations++;
        }
      }
      expect(foundMutations, 0,
          reason: 'No widget files should call .put() directly on repos');
    });

    test('no .delete() calls on repos in widget code', () async {
      var foundDelete = false;
      for (final path in widgetFiles) {
        final source = File(path).readAsStringSync();
        if (RegExp(r'ref\.read\(\w+RepoProvider\)\s*\.delete\(')
            .hasMatch(source)) {
          foundDelete = true;
          break;
        }
      }
      expect(foundDelete, isFalse,
          reason: 'No widget files should call .delete() directly on repos');
    });
  });

  group('Architecture layer imports (Phase 2.5)', () {
    test('provider files do NOT import from widgets', () {
      final providerFiles = Directory('lib/features')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('_provider.dart'))
          .where((f) => !f.path.contains('characterization'));

      for (final file in providerFiles) {
        final source = file.readAsStringSync();
        expect(
          source,
          isNot(contains('widgets/')),
          reason: '${file.path} should not import from widgets layer',
        );
      }
    });

    test('repo files do NOT import from widgets or providers', () {
      final repoFiles = Directory('lib/features')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('_repo.dart'));

      for (final file in repoFiles) {
        final source = file.readAsStringSync();
        expect(
          source,
          isNot(contains('widgets/')),
          reason: '${file.path} should not import from widgets layer',
        );
      }
    });
  });
}
