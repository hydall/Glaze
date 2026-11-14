import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/widgets/post_cleaner_line_diff.dart';

void main() {
  group('computeLineDiff', () {
    test('identical text → all same lines', () {
      final result = computeLineDiff('a\nb\nc', 'a\nb\nc');
      expect(result.removedLines, 0);
      expect(result.addedLines, 0);
      expect(result.leftLines.length, 3);
      expect(result.rightLines.length, 3);
      for (final line in result.leftLines) {
        expect(line.type, DiffLineType.same);
      }
    });

    test('completely different text → all removed + all added (paired)', () {
      final result = computeLineDiff('x\ny', 'a\nb');
      // With word-level pairing, removed and added are paired 1:1
      expect(result.removedLines, 2);
      expect(result.addedLines, 2);
      // Left lines: x (removed, paired with a), y (removed, paired with b)
      expect(result.leftLines[0].type, DiffLineType.removed);
      expect(result.leftLines[0].text, 'x');
      expect(result.leftLines[1].type, DiffLineType.removed);
      expect(result.leftLines[1].text, 'y');
      // Right lines: a (added, paired with x), b (added, paired with y)
      expect(result.rightLines[0].type, DiffLineType.added);
      expect(result.rightLines[0].text, 'a');
      expect(result.rightLines[1].type, DiffLineType.added);
      expect(result.rightLines[1].text, 'b');
    });

    test('middle line removed from left (no matching right line)', () {
      final result = computeLineDiff('a\nb\nc', 'a\nc');
      expect(result.removedLines, 1);
      expect(result.addedLines, 0);
      // a=same, b=removed (unpaired), c=same
      expect(result.leftLines[0].type, DiffLineType.same);
      expect(result.leftLines[1].type, DiffLineType.removed);
      expect(result.leftLines[1].text, 'b');
      expect(result.rightLines[1].type, DiffLineType.removed);
      expect(result.rightLines[1].text, '');
    });

    test('middle line added on right (no matching left line)', () {
      final result = computeLineDiff('a\nc', 'a\nb\nc');
      expect(result.addedLines, 1);
      expect(result.removedLines, 0);
      // a=same, b=added (unpaired), c=same
      expect(result.rightLines[1].type, DiffLineType.added);
      expect(result.rightLines[1].text, 'b');
      expect(result.leftLines[1].type, DiffLineType.added);
      expect(result.leftLines[1].text, '');
    });

    test('line changed → paired removed+added with word diff', () {
      final result = computeLineDiff('a\nold\nc', 'a\nnew\nc');
      expect(result.removedLines, 1);
      expect(result.addedLines, 1);
      final removedLeft = result.leftLines.where((l) => l.type == DiffLineType.removed).first;
      expect(removedLeft.text, 'old');
      final addedRight = result.rightLines.where((l) => l.type == DiffLineType.added).first;
      expect(addedRight.text, 'new');
      // Word diff should be present
      expect(removedLeft.words, isNotNull);
      expect(addedRight.words, isNotNull);
    });

    test('empty original → all added', () {
      final result = computeLineDiff('', 'a\nb');
      expect(result.removedLines, 0);
      expect(result.addedLines, 2);
    });

    test('empty cleaned → all removed', () {
      final result = computeLineDiff('a\nb', '');
      expect(result.removedLines, 2);
      expect(result.addedLines, 0);
    });

    test('both empty → no diff', () {
      final result = computeLineDiff('', '');
      expect(result.removedLines, 0);
      expect(result.addedLines, 0);
      expect(result.leftLines, isEmpty);
      expect(result.rightLines, isEmpty);
    });

    test('prefix preserved, suffix added', () {
      final result = computeLineDiff('a\nb', 'a\nb\nc\nd');
      expect(result.removedLines, 0);
      expect(result.addedLines, 2);
      expect(result.leftLines[0].type, DiffLineType.same);
      expect(result.leftLines[1].type, DiffLineType.same);
      final added = result.rightLines.where((l) => l.type == DiffLineType.added).toList();
      expect(added.length, 2);
      expect(added[0].text, 'c');
      expect(added[1].text, 'd');
    });

    test('preserves line count alignment (left and right same length)', () {
      final result = computeLineDiff('a\nb\nc', 'a\nx\nc');
      expect(result.leftLines.length, result.rightLines.length);
    });

    test('multiline prose with changed paragraph', () {
      final orig = 'First paragraph stays.\n\nSecond paragraph is old text.\n\nThird paragraph stays.';
      final cleaned = 'First paragraph stays.\n\nSecond paragraph is new text.\n\nThird paragraph stays.';
      final result = computeLineDiff(orig, cleaned);
      expect(result.removedLines, 1);
      expect(result.addedLines, 1);
      final removedLine = result.leftLines.where((l) => l.type == DiffLineType.removed).first;
      expect(removedLine.text, 'Second paragraph is old text.');
      final addedLine = result.rightLines.where((l) => l.type == DiffLineType.added).first;
      expect(addedLine.text, 'Second paragraph is new text.');
    });

    test('word-level diff highlights only changed words within a line', () {
      final result = computeLineDiff('The quick brown fox', 'The slow brown fox');
      expect(result.removedLines, 1);
      expect(result.addedLines, 1);
      final removedLine = result.leftLines.where((l) => l.type == DiffLineType.removed).first;
      final addedLine = result.rightLines.where((l) => l.type == DiffLineType.added).first;
      expect(removedLine.words, isNotNull);
      expect(addedLine.words, isNotNull);
      // "quick" should be marked as changed on the left
      final changedLeft = removedLine.words!.where((w) => w.isChanged).toList();
      expect(changedLeft.any((w) => w.text == 'quick'), true);
      // "slow" should be marked as changed on the right
      final changedRight = addedLine.words!.where((w) => w.isChanged).toList();
      expect(changedRight.any((w) => w.text == 'slow'), true);
      // "The", "brown", "fox" should NOT be changed
      final sameLeft = removedLine.words!.where((w) => !w.isChanged).map((w) => w.text).toList();
      expect(sameLeft.contains('The'), true);
      expect(sameLeft.contains('brown'), true);
      expect(sameLeft.contains('fox'), true);
    });

    test('word-level diff with multiple changed words', () {
      final result = computeLineDiff('one two three four', 'five six three seven');
      final removedLine = result.leftLines.where((l) => l.type == DiffLineType.removed).first;
      final addedLine = result.rightLines.where((l) => l.type == DiffLineType.added).first;
      // "three" is common → not changed; others are changed
      final sameLeft = removedLine.words!.where((w) => !w.isChanged).map((w) => w.text).toList();
      expect(sameLeft.contains('three'), true);
      final sameRight = addedLine.words!.where((w) => !w.isChanged).map((w) => w.text).toList();
      expect(sameRight.contains('three'), true);
    });
  });
}
