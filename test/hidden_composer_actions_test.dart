import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/composer_pins_provider.dart';
import 'package:glaze_flutter/features/chat/hidden_composer_actions_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  Future<Set<String>> load(ProviderContainer container) =>
      container.read(hiddenComposerActionsProvider.future);

  group('hidden composer actions', () {
    test('starts with nothing hidden', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await load(makeContainer()), isEmpty);
    });

    test('hides and restores an insert action', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      await load(container);
      final notifier = container.read(hiddenComposerActionsProvider.notifier);

      await notifier.hide(ComposerAction.asterisk);
      expect(container.read(hiddenComposerActionsProvider).value, {
        ComposerAction.asterisk.id,
      });

      await notifier.show(ComposerAction.asterisk);
      expect(container.read(hiddenComposerActionsProvider).value, isEmpty);
    });

    test('refuses to hide an action with a feature behind it', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      await load(container);

      await container
          .read(hiddenComposerActionsProvider.notifier)
          .hide(ComposerAction.attach);

      expect(container.read(hiddenComposerActionsProvider).value, isEmpty);
    });

    test('drops stored ids this build cannot hide', () async {
      SharedPreferences.setMockInitialValues({
        HiddenComposerActionsNotifier.storageKey: [
          ComposerAction.quote.id,
          ComposerAction.attach.id,
          'gone',
        ],
      });

      expect(await load(makeContainer()), {ComposerAction.quote.id});
    });
  });
}
