import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/character_list/reveal_hidden_hotkey.dart';

void main() {
  test('hotkey survives an encode/decode round trip', () {
    const a = SingleActivator(
      LogicalKeyboardKey.keyK,
      control: true,
      alt: true,
    );
    final b = decodeHotkey(encodeHotkey(a))!;
    expect(b.trigger, LogicalKeyboardKey.keyK);
    expect(b.control, isTrue);
    expect(b.alt, isTrue);
    expect(b.shift, isFalse);
    expect(b.meta, isFalse);
  });

  test('missing value falls back to the default, cleared stays off', () {
    final d = decodeHotkey(null)!;
    expect(d.trigger, kDefaultRevealHiddenHotkey.trigger);
    expect(decodeHotkey(encodeHotkey(null)), isNull);
    expect(decodeHotkey('garbage')!.trigger, LogicalKeyboardKey.keyH);
  });

  test('formats modifiers before the key', () {
    const a = SingleActivator(
      LogicalKeyboardKey.keyH,
      control: true,
      shift: true,
    );
    expect(formatHotkey(a), 'Ctrl + Shift + H');
  });
}
