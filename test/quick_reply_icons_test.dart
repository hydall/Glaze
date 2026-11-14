import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/quick_replies_provider.dart';
import 'package:glaze_flutter/features/chat/quick_reply_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const storageKey = 'quick_replies_list_v1';

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  Future<List<QuickReply>> load(ProviderContainer container) =>
      container.read(quickRepliesProvider.future);

  String encode(List<Map<String, dynamic>> items) => jsonEncode(items);

  group('QuickReply icon', () {
    test('falls back to the built-in glyph when none was chosen', () {
      expect(
        const QuickReply(id: 'qr-1', label: 'a', text: 'b').icon,
        Icons.bolt,
      );
      expect(
        const QuickReply(
          id: kContinueQuickReplyId,
          label: 'Continue',
          text: '',
        ).icon,
        Icons.keyboard_double_arrow_right,
      );
    });

    test('a chosen glyph wins, built-in cards included', () {
      expect(
        const QuickReply(
          id: 'qr-1',
          label: 'a',
          text: 'b',
          iconId: 'moon',
        ).icon,
        kQuickReplyIcons['moon'],
      );
      expect(
        const QuickReply(
          id: kContinueQuickReplyId,
          label: 'Continue',
          text: '',
          iconId: 'skip',
        ).icon,
        kQuickReplyIcons['skip'],
      );
    });

    test('an id this build no longer offers falls back', () {
      // Same path a card written by a newer build takes on an older one.
      expect(
        const QuickReply(
          id: 'qr-1',
          label: 'a',
          text: 'b',
          iconId: 'unicorn',
        ).icon,
        Icons.bolt,
      );
      expect(quickReplyIconById('unicorn'), isNull);
      expect(quickReplyIconById(null), isNull);
    });

    test('survives a JSON round trip, and stays out of it when unset', () {
      const withIcon = QuickReply(
        id: 'qr-1',
        label: 'a',
        text: 'b',
        iconId: 'star',
      );
      expect(QuickReply.fromJson(withIcon.toJson()).iconId, 'star');

      const without = QuickReply(id: 'qr-2', label: 'a', text: 'b');
      expect(without.toJson().containsKey('icon'), isFalse);
      expect(QuickReply.fromJson(without.toJson()).iconId, isNull);
    });

    test('copyWith leaves the glyph alone unless asked to clear it', () {
      const reply = QuickReply(
        id: 'qr-1',
        label: 'a',
        text: 'b',
        iconId: 'fire',
      );
      expect(reply.copyWith(label: 'z').iconId, 'fire');
      expect(reply.copyWith(iconId: 'moon').iconId, 'moon');
      expect(reply.copyWith(clearIcon: true).iconId, isNull);
    });

    test('add persists the chosen glyph', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      await load(container);
      await container
          .read(quickRepliesProvider.notifier)
          .add('Look up', '*looks up*', iconId: 'moon');

      final added = container
          .read(quickRepliesProvider)
          .value!
          .firstWhere((q) => q.label == 'Look up');
      expect(added.iconId, 'moon');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(storageKey), contains('"icon":"moon"'));
    });

    test('edit sets a glyph and clears it back to the default', () async {
      SharedPreferences.setMockInitialValues({
        storageKey: encode([
          {'id': 'qr-1', 'label': 'a', 'text': 'b', 'icon': 'star'},
        ]),
      });
      final container = makeContainer();
      await load(container);
      final notifier = container.read(quickRepliesProvider.notifier);

      await notifier.edit('qr-1', iconId: 'heart');
      expect(container.read(quickRepliesProvider).value!.last.iconId, 'heart');

      await notifier.edit('qr-1', label: 'renamed', clearIcon: true);
      final cleared = container.read(quickRepliesProvider).value!.last;
      expect(cleared.iconId, isNull);
      expect(cleared.label, 'renamed');
      expect(cleared.icon, Icons.bolt);
    });

    test('the catalog is a set of distinct glyphs', () {
      // Two ids drawing the same icon would give the picker two swatches that
      // look and behave identically.
      expect(
        kQuickReplyIcons.values.toSet().length,
        kQuickReplyIcons.length,
      );
      expect(kQuickReplyIcons, contains('bolt'));
    });
  });
}
