import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/utils/text_insert.dart';

void main() {
  TextEditingController controllerFor(String text, TextSelection selection) {
    final controller = TextEditingController(text: text);
    controller.selection = selection;
    return controller;
  }

  group('insertSurroundingText', () {
    test('wraps a collapsed caret and leaves the caret between the pair', () {
      final controller = controllerFor(
        'hello world',
        const TextSelection.collapsed(offset: 5),
      );
      addTearDown(controller.dispose);

      insertSurroundingText(controller, '*');

      expect(controller.text, 'hello** world');
      expect(controller.selection, const TextSelection.collapsed(offset: 6));
    });

    test('wraps a non-empty selection and lands after it', () {
      final controller = controllerFor(
        'abc',
        const TextSelection(baseOffset: 0, extentOffset: 3),
      );
      addTearDown(controller.dispose);

      insertSurroundingText(controller, '"');

      expect(controller.text, '"abc"');
      expect(controller.selection, const TextSelection.collapsed(offset: 4));
    });

    test('appends a pair when the field has never been focused', () {
      final controller = controllerFor(
        'note',
        const TextSelection.collapsed(offset: -1),
      );
      addTearDown(controller.dispose);

      insertSurroundingText(controller, '*');

      expect(controller.text, 'note**');
      expect(controller.selection, const TextSelection.collapsed(offset: 5));
    });

    test('ignores an empty token', () {
      final controller = controllerFor(
        'x',
        const TextSelection.collapsed(offset: 1),
      );
      addTearDown(controller.dispose);

      insertSurroundingText(controller, '');

      expect(controller.text, 'x');
    });
  });
}
