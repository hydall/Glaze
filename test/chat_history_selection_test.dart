import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat_history/chat_history_selection_provider.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  ChatHistorySelectionNotifier notifier() =>
      container.read(chatHistorySelectionProvider.notifier);
  ChatHistorySelectionState state() =>
      container.read(chatHistorySelectionProvider);

  test('starts inactive', () {
    expect(state().active, isFalse);
    expect(state().count, 0);
  });

  test('a long press starts selection with one row', () {
    notifier().start('char_0');
    expect(state().active, isTrue);
    expect(state().sessionIds, {'char_0'});
    expect(state().contains('char_0'), isTrue);
  });

  test('further taps add and remove rows', () {
    notifier()
      ..start('char_0')
      ..toggle('char_1')
      ..toggle('char_2');
    expect(state().count, 3);

    notifier().toggle('char_1');
    expect(state().sessionIds, {'char_0', 'char_2'});
    expect(state().active, isTrue);
  });

  test('deselecting the last row leaves selection mode', () {
    notifier()
      ..start('char_0')
      ..toggle('char_0');
    expect(state().active, isFalse);
    expect(state().count, 0);
  });

  test('clear drops the whole selection', () {
    notifier()
      ..start('char_0')
      ..toggle('char_1')
      ..clear();
    expect(state().active, isFalse);
    expect(state().sessionIds, isEmpty);
  });
}
