import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_books_controls.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_books_toolbar.dart';
import 'package:glaze_flutter/features/memory/controllers/memory_settings_mapper.dart';

import 'helpers/pump_localized.dart';

/// The panel counts its queue with `.plural()`, which needs a real locale, so
/// these assert on the English copy rather than on key names.
const _hint =
    'Auto-generate is off, so new drafts are created and wait here until you '
    'generate them.';

Future<void> _pumpPanel(
  WidgetTester tester, {
  required bool autoGenerateEnabled,
  bool isGenerating = false,
  int pendingCount = 3,
}) => pumpLocalized(
  tester,
  MemoryBatchPanel(
    pendingCount: pendingCount,
    isGenerating: isGenerating,
    autoGenerateEnabled: autoGenerateEnabled,
    onGenerateBatch: () {},
  ),
  locale: const Locale('en'),
);

void main() {
  // Auto-*create* is on out of the box and auto-*generate* is not, so the
  // ordinary first encounter with this panel is a stack of empty drafts and no
  // stated reason for it. That is the whole report: "The draft in memory book
  // arent auto generate — am i doing something wrong?" Nothing was wrong, and
  // nothing said so.
  group('the drafts panel says why drafts are waiting', () {
    testWidgets('auto-generate off is explained', (tester) async {
      await _pumpPanel(tester, autoGenerateEnabled: false);
      expect(find.text(_hint), findsOneWidget);
    });

    testWidgets('auto-generate on needs no explanation', (tester) async {
      await _pumpPanel(tester, autoGenerateEnabled: true);
      expect(find.text(_hint), findsNothing);
    });

    testWidgets('a batch already running needs no explanation', (tester) async {
      // Mid-batch the reader is watching it work; the reason it did not start
      // by itself is not the thing to say at that moment.
      await _pumpPanel(
        tester,
        autoGenerateEnabled: false,
        isGenerating: true,
      );
      expect(find.text(_hint), findsNothing);
    });

    testWidgets('the queue and its action are untouched', (tester) async {
      await _pumpPanel(tester, autoGenerateEnabled: false);
      expect(find.text('3 drafts need generation'), findsOneWidget);
      expect(find.text('Generate Batch'), findsOneWidget);
      expect(find.byType(MemoryActionTile), findsOneWidget);
    });
  });

  group('the delayed-automation switch is gone, its value is not', () {
    test('no control is offered for a flag nothing reads', () {
      // It was saved, synced and summarised while being read by nobody: drafts
      // are created from the post-generation coordinator, so its ON position
      // described what already happens and its OFF position promised a
      // behaviour that does not exist.
      for (final path in [
        'lib/features/chat/widgets/memory/settings/memory_capture_tab.dart',
        'lib/features/memory/controllers/memory_book_controller.dart',
      ]) {
        expect(
          File(path).readAsStringSync(),
          isNot(contains("'memory_books_delayed_automation'")),
          reason: '$path still advertises it',
        );
      }
    });

    test('nothing still consumes the flag', () {
      // If a consumer is ever written, this test is the place to notice that
      // the control has to come back with it.
      final stage = File(
        'lib/features/chat/services/stages/memory_draft_stage.dart',
      ).readAsStringSync();
      expect(stage, isNot(contains('useDelayedAutomation')));
    });

    test('a stored value still survives a settings round trip', () {
      // Removing the switch must not drop what a reader had saved, or wipe it
      // for the other devices it syncs to.
      const mapper = MemorySettingsMapper();
      const global = MemoryGlobalSettings(useDelayedAutomation: false);

      final book = mapper.globalToBook(global);
      expect(book.useDelayedAutomation, isFalse);

      final back = mapper.bookToGlobal(book, global, global.vectorThreshold);
      expect(back.useDelayedAutomation, isFalse);
    });
  });

  group('auto-generation itself is wired', () {
    // The audit for this card said `autoGenerateEnabled` "has no consumer in
    // the post-generation pipeline". It has two, and the stage is covered end
    // to end by memory_draft_stage_test.dart. Recorded here so the next reader
    // does not go looking for a missing implementation.
    test('the stage gates on it and the coordinator reserves for it', () {
      final stage = File(
        'lib/features/chat/services/stages/memory_draft_stage.dart',
      ).readAsStringSync();
      expect(stage, contains('!settings.autoGenerateEnabled'));

      final coordinator = File(
        'lib/features/chat/services/stages/post_gen_coordinator.dart',
      ).readAsStringSync();
      expect(coordinator, contains('draftStage.reserveAutoGeneration('));
    });
  });
}
