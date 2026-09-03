import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/composer_pins_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  Future<List<ComposerPin>> load(ProviderContainer container) =>
      container.read(composerPinsProvider.future);

  ComposerPin pinOf(ComposerAction action) => ComposerPin.action(action);

  group('ComposerPin encoding', () {
    test('round-trips every kind', () {
      for (final pin in [
        ComposerPin.action(ComposerAction.attach),
        ComposerPin.reply('qr-1700000000'),
        ComposerPin.tool('char-card'),
      ]) {
        expect(ComposerPin.decode(pin.encode()), pin);
      }
    });

    test('reads a bare action id as the legacy action pin it was', () {
      expect(ComposerPin.decode('guidance'), pinOf(ComposerAction.guidance));
    });

    test('rejects an unknown kind, an unknown action and an empty ref', () {
      expect(ComposerPin.decode('widget:thing'), isNull);
      expect(ComposerPin.decode('action:teleport'), isNull);
      expect(ComposerPin.decode('tool:'), isNull);
      expect(ComposerPin.decode('gone'), isNull);
    });

    test('keeps a ref id that contains a dash', () {
      final pin = ComposerPin.decode('tool:image-gen');
      expect(pin, ComposerPin.tool('image-gen'));
    });
  });

  group('composer pins', () {
    test('defaults to the full row in declaration order', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await load(makeContainer()), kDefaultComposerPins);
    });

    test('migrates the pre-mixed-row key of bare action ids', () async {
      SharedPreferences.setMockInitialValues({
        ComposerPinsNotifier.legacyStorageKey: ['drawer', 'guidance'],
      });
      expect(await load(makeContainer()), [
        pinOf(ComposerAction.drawer),
        pinOf(ComposerAction.guidance),
      ]);
    });

    test('reads a stored row, dropping ids it cannot parse', () async {
      SharedPreferences.setMockInitialValues({
        ComposerPinsNotifier.storageKey: [
          'action:drawer',
          'action:guidance',
          'widget:gone',
          'tool:regex',
          'reply:qr-1',
        ],
      });
      expect(await load(makeContainer()), [
        pinOf(ComposerAction.drawer),
        pinOf(ComposerAction.guidance),
        ComposerPin.tool('regex'),
        ComposerPin.reply('qr-1'),
      ]);
    });

    test('restores the drawer button a stored row is missing', () async {
      // The old settings sheet could switch it off, and there is no switch any
      // more — without this the user has no way back into the drawer.
      SharedPreferences.setMockInitialValues({
        ComposerPinsNotifier.storageKey: ['action:attach'],
      });
      expect(await load(makeContainer()), [
        pinOf(ComposerAction.drawer),
        pinOf(ComposerAction.attach),
      ]);
    });

    test('unpin drops the button and persists the rest', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      await load(container);
      await container
          .read(composerPinsProvider.notifier)
          .unpin(pinOf(ComposerAction.attach));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(ComposerPinsNotifier.storageKey), [
        'action:drawer',
        'action:fullscreen',
        'action:guidance',
      ]);
    });

    test('unpin refuses the drawer button', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      await load(container);
      await container
          .read(composerPinsProvider.notifier)
          .unpin(pinOf(ComposerAction.drawer));

      expect(
        container.read(composerPinsProvider).value,
        contains(pinOf(ComposerAction.drawer)),
      );
    });

    test('a row emptied down to the permanent button stays that way', () async {
      SharedPreferences.setMockInitialValues({
        ComposerPinsNotifier.storageKey: <String>[],
      });
      expect(await load(makeContainer()), [pinOf(ComposerAction.drawer)]);
    });

    test('pin appends a tool and a reply, and ignores a repeat', () async {
      SharedPreferences.setMockInitialValues({
        ComposerPinsNotifier.storageKey: ['action:drawer'],
      });
      final container = makeContainer();
      await load(container);
      final notifier = container.read(composerPinsProvider.notifier);
      await notifier.pin(ComposerPin.tool('memory'));
      await notifier.pin(ComposerPin.reply('qr-7'));
      await notifier.pin(ComposerPin.tool('memory'));

      expect(container.read(composerPinsProvider).value, [
        pinOf(ComposerAction.drawer),
        ComposerPin.tool('memory'),
        ComposerPin.reply('qr-7'),
      ]);
    });

    test('reorder moves a pin to the given index', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      await load(container);
      await container.read(composerPinsProvider.notifier).reorder(0, 3);

      expect(container.read(composerPinsProvider).value, [
        pinOf(ComposerAction.attach),
        pinOf(ComposerAction.fullscreen),
        pinOf(ComposerAction.guidance),
        pinOf(ComposerAction.drawer),
      ]);
    });

    test('reorder ignores out-of-range indices', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      final before = await load(container);
      await container.read(composerPinsProvider.notifier).reorder(0, 9);
      expect(container.read(composerPinsProvider).value, before);
    });

    test('reset restores the shipped row', () async {
      SharedPreferences.setMockInitialValues({
        ComposerPinsNotifier.storageKey: ['action:drawer'],
      });
      final container = makeContainer();
      await load(container);
      await container.read(composerPinsProvider.notifier).reset();

      expect(container.read(composerPinsProvider).value, kDefaultComposerPins);
    });
  });

  group('drag payloads', () {
    // Edit mode puts the composer's pinned row and a drawer grid on screen at
    // the same time, and a DragTarget accepts by payload type alone. Sharing a
    // type between them let a card dragged out of the grid land in the row as a
    // reorder of whatever pin happened to share its index.
    test('the row and the two grids cannot accept each other\'s drags', () {
      String source(String path) => File(path).readAsStringSync();

      expect(
        source('lib/features/chat/widgets/chat_input_bar.dart'),
        allOf(
          contains('DragTarget<ComposerPin>('),
          contains('Draggable<ComposerPin>('),
        ),
      );
      expect(
        source('lib/features/chat/widgets/magic_drawer.dart'),
        allOf(contains('DragTarget<int>('), isNot(contains('<ComposerPin>('))),
      );
      expect(
        source('lib/features/chat/widgets/quick_replies_panel.dart'),
        allOf(
          contains('DragTarget<String>('),
          isNot(contains('<ComposerPin>(')),
        ),
      );
    });
  });

  group('ComposerActionBridge', () {
    test('runs through the registered handler and stops after unregister', () {
      final bridge = ComposerActionBridge();
      final ran = <ComposerAction>[];
      void handler(ComposerAction action) => ran.add(action);

      expect(bridge.isAvailable, isFalse);
      bridge.register(handler);
      expect(bridge.isAvailable, isTrue);
      bridge.run(ComposerAction.attach);

      bridge.unregister(handler);
      bridge.run(ComposerAction.guidance);

      expect(ran, [ComposerAction.attach]);
      expect(bridge.isAvailable, isFalse);
    });

    test('a stale unregister cannot unseat the current handler', () {
      // A session switch re-keys ChatInputBar; the replacement can register
      // before the outgoing State's dispose runs.
      final bridge = ComposerActionBridge();
      final ran = <ComposerAction>[];
      void outgoing(ComposerAction action) {}
      void incoming(ComposerAction action) => ran.add(action);

      bridge.register(outgoing);
      bridge.register(incoming);
      bridge.unregister(outgoing);
      bridge.run(ComposerAction.fullscreen);

      expect(ran, [ComposerAction.fullscreen]);
    });
  });
}
