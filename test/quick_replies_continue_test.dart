import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/quick_replies_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Continue is a feature wired to `continueMessage()`, not a user-authored
/// quick action, so it must survive both a delete attempt and a stored list
/// saved back when it *was* deletable.
void main() {
  const storageKey = 'quick_replies_list_v1';

  String encode(List<Map<String, String>> items) => jsonEncode(items);

  Future<List<QuickReply>> load(ProviderContainer container) =>
      container.read(quickRepliesProvider.future);

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  group('Continue quick reply', () {
    test('is present in the shipped defaults', () async {
      SharedPreferences.setMockInitialValues({});
      final replies = await load(makeContainer());
      expect(replies.any((r) => r.isContinueAction), isTrue);
    });

    test('is restored when a stored list is missing it', () async {
      SharedPreferences.setMockInitialValues({
        storageKey: encode([
          {'id': 'qr-1', 'label': 'Tell more', 'text': 'Tell me more.'},
        ]),
      });

      final replies = await load(makeContainer());

      expect(replies.first.id, kContinueQuickReplyId);
      expect(replies.map((r) => r.id), ['continue', 'qr-1']);
    });

    test('is not duplicated when a stored list already has it', () async {
      SharedPreferences.setMockInitialValues({
        storageKey: encode([
          {'id': 'qr-1', 'label': 'Tell more', 'text': 'Tell me more.'},
          {'id': 'continue', 'label': 'Keep going', 'text': ''},
        ]),
      });

      final replies = await load(makeContainer());

      // Position and the user's rename are both preserved — restoring is only
      // for a list that lost the action entirely.
      expect(replies.map((r) => r.id), ['qr-1', 'continue']);
      expect(replies.last.label, 'Keep going');
    });

    test('remove() is a no-op for it and still deletes the rest', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      await load(container);
      final notifier = container.read(quickRepliesProvider.notifier);

      await notifier.remove(kContinueQuickReplyId);
      expect(
        container.read(quickRepliesProvider).value!.any(
          (r) => r.isContinueAction,
        ),
        isTrue,
      );

      await notifier.remove('tell-more');
      expect(
        container.read(quickRepliesProvider).value!.any(
          (r) => r.id == 'tell-more',
        ),
        isFalse,
      );
    });

    test('is flagged built-in so the UI hides its delete affordance', () async {
      SharedPreferences.setMockInitialValues({});
      final replies = await load(makeContainer());

      final continueReply = replies.firstWhere((r) => r.isContinueAction);
      expect(continueReply.isBuiltIn, isTrue);
      expect(replies.where((r) => r.isBuiltIn).length, 1);
    });

    test('stays renameable and reorderable', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      final initial = await load(container);
      final notifier = container.read(quickRepliesProvider.notifier);

      await notifier.edit(kContinueQuickReplyId, label: 'Keep going');
      await notifier.reorder(0, initial.length - 1);

      final replies = container.read(quickRepliesProvider).value!;
      expect(replies.last.id, kContinueQuickReplyId);
      expect(replies.last.label, 'Keep going');
    });
  });
}
