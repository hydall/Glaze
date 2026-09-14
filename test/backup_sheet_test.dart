import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/backup_service.dart';
import 'package:glaze_flutter/features/backup/backup_provider.dart';
import 'package:glaze_flutter/features/backup/backup_screen.dart';

/// Without EasyLocalization `.tr()` returns the key, which is what these
/// assertions read: the question is *which* string the button asks for.
void main() {
  /// The sheet reads the backup service only from its button callbacks, so a
  /// future that never completes is enough to hold the screen in "exporting"
  /// — `_performExport` flips the flag before it awaits.
  Future<void> pumpSheet(
    WidgetTester tester, {
    required bool fromOnboarding,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backupServiceProvider.overrideWith(
            (ref) => Completer<BackupService>().future,
          ),
        ],
        child: MaterialApp(
          home: BackupScreen(fromOnboarding: fromOnboarding),
        ),
      ),
    );
    await tester.pump();
  }

  group('#111 — a fresh install has nothing to export', () {
    testWidgets('the onboarding sheet offers import only', (tester) async {
      await pumpSheet(tester, fromOnboarding: true);
      expect(find.text('menu_import'), findsWidgets);
      // Both the section title and the button label ask for this key, so
      // zero of them is the whole section gone, hint and separator included.
      expect(find.text('menu_export'), findsNothing);
    });

    testWidgets('the settings sheet still offers both', (tester) async {
      await pumpSheet(tester, fromOnboarding: false);
      expect(find.text('menu_import'), findsWidgets);
      expect(find.text('menu_export'), findsWidgets);
    });
  });

  group('#24 — the export button announced an import', () {
    testWidgets('exporting says it is preparing an export', (tester) async {
      await pumpSheet(tester, fromOnboarding: false);
      await tester.tap(find.text('menu_export').last);
      await tester.pump();

      expect(find.text('backup_progress_preparing_export'), findsOneWidget);
      expect(
        find.text('backup_progress_preparing'),
        findsNothing,
        reason: 'that string says "Preparing import..."',
      );
    });

    test('the two progress strings really do say different things', () {
      for (final locale in ['en', 'ru']) {
        final map =
            jsonDecode(
                  File('assets/translations/$locale.json').readAsStringSync(),
                )
                as Map<String, dynamic>;
        final import = map['backup_progress_preparing'] as String;
        final export = map['backup_progress_preparing_export'] as String;
        expect(export, isNotEmpty, reason: locale);
        expect(export, isNot(import), reason: locale);
      }
      // And the English pair says which is which, so the fix is not two
      // identical strings under two keys.
      final en =
          jsonDecode(File('assets/translations/en.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(en['backup_progress_preparing'], contains('import'));
      expect(en['backup_progress_preparing_export'], contains('export'));
    });
  });
}
