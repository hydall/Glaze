import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/composer_actions_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  Future<List<ComposerAction>> load(ProviderContainer container) =>
      container.read(composerActionsProvider.future);

  group('composer actions', () {
    test('defaults to the full row in declaration order', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await load(makeContainer()), ComposerAction.values);
    });

    test('reads a stored order, dropping unknown ids', () async {
      SharedPreferences.setMockInitialValues({
        ComposerActionsNotifier.storageKey: ['guidance', 'gone', 'attach'],
      });

      expect(await load(makeContainer()), [
        ComposerAction.guidance,
        ComposerAction.attach,
      ]);
    });

    test('hiding an action persists the remaining order', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      await load(container);

      await container
          .read(composerActionsProvider.notifier)
          .setEnabled(ComposerAction.attach, false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(ComposerActionsNotifier.storageKey), [
        'drawer',
        'fullscreen',
        'guidance',
      ]);
    });

    test('an empty row is honoured rather than reset to the defaults', () async {
      SharedPreferences.setMockInitialValues({
        ComposerActionsNotifier.storageKey: <String>[],
      });

      expect(await load(makeContainer()), isEmpty);
    });

    test('re-enabling puts the action back in its canonical slot', () async {
      SharedPreferences.setMockInitialValues({
        ComposerActionsNotifier.storageKey: ['drawer', 'fullscreen'],
      });
      final container = makeContainer();
      await load(container);

      await container
          .read(composerActionsProvider.notifier)
          .setEnabled(ComposerAction.attach, true);

      expect(container.read(composerActionsProvider).value, [
        ComposerAction.drawer,
        ComposerAction.attach,
        ComposerAction.fullscreen,
      ]);
    });

    test('reorder moves one action and leaves the rest in place', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      await load(container);

      await container.read(composerActionsProvider.notifier).reorder(0, 3);

      expect(container.read(composerActionsProvider).value, [
        ComposerAction.attach,
        ComposerAction.fullscreen,
        ComposerAction.guidance,
        ComposerAction.drawer,
      ]);
    });

    test('reset restores the full row', () async {
      SharedPreferences.setMockInitialValues({
        ComposerActionsNotifier.storageKey: ['guidance'],
      });
      final container = makeContainer();
      await load(container);

      await container.read(composerActionsProvider.notifier).reset();

      expect(container.read(composerActionsProvider).value, ComposerAction.values);
    });
  });
}
