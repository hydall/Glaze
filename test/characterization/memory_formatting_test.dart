import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/llm/memory_excerpt_selector.dart';
import 'package:glaze_flutter/core/llm/memory_formatting.dart';

MemoryInjectionItem _item({
  required String id,
  String title = '',
  String text = 'body text',
  bool excerpt = false,
  int? rangeStart,
  int? rangeEnd,
}) {
  return MemoryInjectionItem(
    entry: MemoryEntry(
      id: id,
      title: title,
      content: text,
      messageRange: (rangeStart != null && rangeEnd != null)
          ? MessageRange(start: rangeStart, end: rangeEnd)
          : null,
    ),
    excerpt: excerpt,
    text: text,
    tokenCost: 10,
    originalTokenCost: 10,
  );
}

void main() {
  group('formatMemoryRange', () {
    test('returns start-end when messageRange is present', () {
      final entry = MemoryEntry(
        id: 'e1',
        messageRange: MessageRange(start: 12, end: 30),
      );
      expect(formatMemoryRange(entry), '12-30');
    });

    test('returns null when messageRange is absent', () {
      const entry = MemoryEntry(id: 'e1');
      expect(formatMemoryRange(entry), isNull);
    });
  });

  group('formatMemoryItems', () {
    test('empty items list without header returns empty string', () {
      expect(formatMemoryItems([], includeContextHeader: false), '');
    });

    test('empty items list with header returns only the header', () {
      expect(formatMemoryItems([], includeContextHeader: true), 'Memory context:');
    });

    test('includeContextHeader prepends "Memory context:"', () {
      final out = formatMemoryItems(
        [_item(id: 'e1', title: 'T1', text: 'hello')],
        includeContextHeader: true,
      );
      expect(out, startsWith('Memory context:\n\n'));
    });

    test('no context header when includeContextHeader is false', () {
      final out = formatMemoryItems(
        [_item(id: 'e1', title: 'T1', text: 'hello')],
        includeContextHeader: false,
      );
      expect(out, isNot(contains('Memory context:')));
    });

    test('heading uses title when title is non-empty', () {
      final out = formatMemoryItems(
        [_item(id: 'e1', title: 'My Title', text: 'hello')],
        includeContextHeader: false,
      );
      expect(out, contains('Memory: My Title'));
    });

    test('heading falls back to range when title is empty', () {
      final out = formatMemoryItems(
        [_item(id: 'e1', title: '', text: 'hello', rangeStart: 5, rangeEnd: 9)],
        includeContextHeader: false,
      );
      expect(out, contains('Memory: 5-9'));
    });

    test('heading falls back to "Memory" when title and range are empty', () {
      final out = formatMemoryItems(
        [_item(id: 'e1', title: '', text: 'hello')],
        includeContextHeader: false,
      );
      expect(out, contains('Memory: Memory'));
    });

    test('heading shows title plus range in parens when both present', () {
      final out = formatMemoryItems(
        [_item(
          id: 'e1',
          title: 'Arc',
          text: 'hello',
          rangeStart: 1,
          rangeEnd: 4,
        )],
        includeContextHeader: false,
      );
      expect(out, contains('Memory: Arc (1-4)'));
    });

    test('excerpt item appends excerpt suffix', () {
      final out = formatMemoryItems(
        [_item(id: 'e1', title: 'T1', text: 'hello', excerpt: true)],
        includeContextHeader: false,
      );
      expect(out, contains('[Excerpted from a larger Memory Book entry]'));
    });

    test('non-excerpt item has no excerpt suffix', () {
      final out = formatMemoryItems(
        [_item(id: 'e1', title: 'T1', text: 'hello', excerpt: false)],
        includeContextHeader: false,
      );
      expect(out, isNot(contains('Excerpted')));
    });

    test('multiple items are joined with blank line', () {
      final out = formatMemoryItems(
        [
          _item(id: 'e1', title: 'A', text: 'aaa'),
          _item(id: 'e2', title: 'B', text: 'bbb'),
        ],
        includeContextHeader: false,
      );
      expect(out, contains('Memory: A\naaa\n\nMemory: B\nbbb'));
    });

    test('whitespace-only text body keeps heading with empty body line', () {
      final out = formatMemoryItems(
        [_item(id: 'e1', title: 'T1', text: '   ')],
        includeContextHeader: false,
      );
      expect(out, 'Memory: T1\n');
    });
  });
}
