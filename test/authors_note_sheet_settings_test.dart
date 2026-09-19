import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The note's injection point lived in the preset editor, two screens away
/// from the text it places, so the sheet could only say "set it somewhere
/// else". It is back in the sheet, editing the current preset's
/// `authors_note` block, and the group's hint says so.
void main() {
  final sheet = File(
    'lib/features/chat/widgets/authors_note_sheet.dart',
  ).readAsStringSync();

  group('the sheet carries the block settings', () {
    test('role, insertion and depth are in the sheet', () {
      expect(sheet, contains("'label_injection_point'.tr()"));
      expect(sheet, contains("'label_role'.tr()"));
      expect(sheet, contains("'label_insertion'.tr()"));
      expect(sheet, contains("'label_depth'.tr()"));
    });

    test('they are written onto the preset block, not the session note', () {
      expect(sheet, contains("indexWhere((b) => b.id == 'authors_note')"));
      expect(sheet, contains('.updatePreset(preset.copyWith(blocks: blocks))'));
    });

    test('the preset is the one the chat resolves to', () {
      expect(sheet, contains('getEffectivePreset('));
      // Unless the sheet was opened from an editor that already has one open.
      expect(sheet, contains('widget.presetId'));
    });

    test('the hint names that preset', () {
      expect(sheet, contains("'authors_note_role_hint'.tr("));
      expect(sheet, contains("namedArgs: {'preset': preset.name}"));
    });
  });

  test('the hint says whose settings these are, in both languages', () {
    for (final path in [
      'assets/translations/en.json',
      'assets/translations/ru.json',
    ]) {
      final json = File(path).readAsStringSync();
      final line = json
          .split('\n')
          .firstWhere((l) => l.contains('"authors_note_role_hint"'));
      expect(line, contains('{preset}'), reason: 'no preset name in $path');
      // It must no longer send the reader to the preset editor.
      expect(line.toLowerCase(), isNot(contains('preset editor')));
    }
  });
}
