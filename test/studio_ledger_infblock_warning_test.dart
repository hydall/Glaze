// ignore_for_file: lines_longer_than_80_chars

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/screens/preset_editor/block_edit_dialog.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Test 19: User InfBlocks are panel-visible but not injected by default.
// Test 20: Enabling user InfBlock prompt injection always shows a fullscreen
// warning (Studio Canon is always-on when Studio is enabled).
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  Future<ProviderContainer> setupContainer() async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('Test 19 — User InfBlock default inject', () {
    test('BlockConfig default inject is false (panel-only)', () {
      const block = BlockConfig(id: 'b1', name: 'Test');
      expect(
        block.inject,
        isFalse,
        reason:
            'User InfBlocks should default to panel-visible, not '
            'injected into main generation. The user must explicitly opt in.',
      );
    });

    test('BlockConfig with explicit inject=true is honored', () {
      const block = BlockConfig(id: 'b1', name: 'Test', inject: true);
      expect(block.inject, isTrue);
    });
  });

  group('Test 20 — Fullscreen warning when enabling inject', () {
    testWidgets('shows fullscreen warning when enabling inject', (tester) async {
      final container = await setupContainer();

      final block = const BlockConfig(
        id: 'b1',
        name: 'Test',
        type: BlockType.infoblock,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: BlockEditDialog(block: block, onSave: (_) {}),
            ),
          ),
        ),
      );
      await tester.pump();

      final injectSwitchFinder = find.ancestor(
        of: find.text('block_inject_title'),
        matching: find.byType(SwitchListTile),
      );
      expect(injectSwitchFinder, findsOneWidget);

      await tester.scrollUntilVisible(
        injectSwitchFinder,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(injectSwitchFinder);
      await tester.pumpAndSettle();

      expect(find.text('Not recommended with Studio Canon'), findsOneWidget);
      expect(find.text('Continue anyway'), findsOneWidget);
      expect(find.byType(Scaffold), findsWidgets);
    });
  });
}
