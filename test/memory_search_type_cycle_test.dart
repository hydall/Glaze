import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The memory sheet's retrieval-mode row is a cycler: tapping it walks
/// keys → vector → vector + keys. It used to read its label from the per-book
/// settings snapshot while writing only the global settings, so the row was
/// pinned to whatever the book was last saved with and tapping it did nothing
/// visible. [MemoryBookController] now reads and writes the same source.
void main() {
  final source = File(
    'lib/features/memory/controllers/memory_book_controller.dart',
  ).readAsStringSync();

  String memberBody(String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: 'missing $signature');
    final end = source.indexOf('\n  }', start);
    return source.substring(start, end);
  }

  group('memory search-type cycler', () {
    test('labels the row from the settings the cycler writes', () {
      final body = memberBody('String get searchTypeLabel {');

      expect(body, contains('final s = globalSettings;'));
      expect(body, isNot(contains('_book?.settings')));
    });

    test('mirrors the cycled mode into the book snapshot retrieval reads', () {
      final body = memberBody('Future<void> cycleSearchType() async {');

      expect(body, contains('memoryGlobalSettingsProvider.notifier'));
      expect(body, contains('book.settings.copyWith('));
      expect(body, contains('.updateSettings(_sessionId, bookSettings)'));
    });
  });
}
