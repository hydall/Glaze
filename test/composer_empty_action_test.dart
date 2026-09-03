import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/composer_empty_action_provider.dart';
import 'package:glaze_flutter/features/chat/composer_pins_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  Future<ComposerPin?> load(ProviderContainer container) =>
      container.read(composerEmptyActionProvider.future);

  group('composer empty action', () {
    test('defaults to nothing, which is the built-in impersonation', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await load(makeContainer()), isNull);
    });

    test('reads a stored assignment of every kind', () async {
      for (final pin in [
        ComposerPin.action(ComposerAction.guidance),
        ComposerPin.reply('qr-1'),
        ComposerPin.tool('char-card'),
      ]) {
        SharedPreferences.setMockInitialValues({
          ComposerEmptyActionNotifier.storageKey: pin.encode(),
        });
        expect(await load(makeContainer()), pin);
      }
    });

    test('falls back to impersonation on an id it cannot parse', () async {
      SharedPreferences.setMockInitialValues({
        ComposerEmptyActionNotifier.storageKey: 'widget:gone',
      });
      expect(await load(makeContainer()), isNull);
    });

    test('assign persists the pin and replaces what was there', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      await load(container);
      final notifier = container.read(composerEmptyActionProvider.notifier);

      await notifier.assign(ComposerPin.tool('regex'));
      await notifier.assign(ComposerPin.reply('qr-2'));

      expect(container.read(composerEmptyActionProvider).value,
          ComposerPin.reply('qr-2'));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(ComposerEmptyActionNotifier.storageKey),
        'reply:qr-2',
      );
    });

    test('reset clears both the state and the stored key', () async {
      SharedPreferences.setMockInitialValues({
        ComposerEmptyActionNotifier.storageKey: 'action:attach',
      });
      final container = makeContainer();
      await load(container);
      await container.read(composerEmptyActionProvider.notifier).reset();

      expect(container.read(composerEmptyActionProvider).value, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(ComposerEmptyActionNotifier.storageKey),
        isNull,
      );
    });

    test('an assignment does not touch the composer row', () async {
      // The slot retargets a button that is already on screen rather than
      // rehoming a card, so the pins list — and the drawer grids that filter
      // on it — must not move.
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      final before = await container.read(composerPinsProvider.future);
      await load(container);
      await container
          .read(composerEmptyActionProvider.notifier)
          .assign(ComposerPin.tool('regex'));

      expect(container.read(composerPinsProvider).value, before);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(ComposerPinsNotifier.storageKey), isNull);
    });
  });
}
