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

    // Paste ships as a drawer card rather than a fifth button: the row was
    // already full, and Ctrl/Cmd+V covers the case on a keyboard.
    test('paste ships unpinned but is pinnable', () async {
      SharedPreferences.setMockInitialValues({});

      expect(
        await load(makeContainer()),
        isNot(contains(pinOf(ComposerAction.paste))),
      );
      expect(ComposerAction.demotable, contains(ComposerAction.paste));
      expect(ComposerPin.decode('action:paste'), pinOf(ComposerAction.paste));
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

    test('pinAt lands a dragged card at the drop position', () async {
      SharedPreferences.setMockInitialValues({
        ComposerPinsNotifier.storageKey: ['action:drawer', 'action:attach'],
      });
      final container = makeContainer();
      await load(container);
      await container
          .read(composerPinsProvider.notifier)
          .pinAt(ComposerPin.tool('memory'), 1);

      expect(container.read(composerPinsProvider).value, [
        pinOf(ComposerAction.drawer),
        ComposerPin.tool('memory'),
        pinOf(ComposerAction.attach),
      ]);
    });

    test('pinAt clamps an index past the end and ignores a repeat', () async {
      SharedPreferences.setMockInitialValues({
        ComposerPinsNotifier.storageKey: ['action:drawer'],
      });
      final container = makeContainer();
      await load(container);
      final notifier = container.read(composerPinsProvider.notifier);
      await notifier.pinAt(ComposerPin.reply('qr-3'), 99);
      await notifier.pinAt(ComposerPin.reply('qr-3'), 0);

      expect(container.read(composerPinsProvider).value, [
        pinOf(ComposerAction.drawer),
        ComposerPin.reply('qr-3'),
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
    // once, and a DragTarget accepts by payload type alone. All three carry the
    // same ComposerPin — that is what lets a card be dragged out of a grid and
    // into the row — so each grid must guard its own drops by kind, or a button
    // dragged the other way would reshuffle it.
    test('every surface drags a ComposerPin', () {
      String source(String path) => File(path).readAsStringSync();

      for (final path in const [
        'lib/features/chat/widgets/chat_input_bar.dart',
        'lib/features/chat/widgets/magic_drawer.dart',
        'lib/features/chat/widgets/quick_replies_panel.dart',
      ]) {
        expect(
          source(path),
          allOf(
            contains('DragTarget<ComposerPin>('),
            contains('Draggable<ComposerPin>('),
          ),
          reason: path,
        );
      }
    });

    test('each grid guards its drops by pin kind', () {
      String source(String path) => File(path).readAsStringSync();

      expect(
        source('lib/features/chat/widgets/magic_drawer.dart'),
        contains('incoming.kind != ComposerPinKind.tool'),
      );
      expect(
        source('lib/features/chat/widgets/quick_replies_panel.dart'),
        contains('incoming.kind != ComposerPinKind.reply'),
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
