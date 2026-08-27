import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/menu/search/menu_search_entry.dart';

MenuSearchEntry _entry(
  String title, {
  String? description,
  List<String> breadcrumb = const ['Menu'],
  List<String> keywords = const [],
}) => MenuSearchEntry(
  title: title,
  description: description,
  breadcrumb: breadcrumb,
  keywords: keywords,
  icon: Icons.settings,
  open: (_) {},
);

void main() {
  group('filterMenuSearchEntries', () {
    test('a blank query matches nothing', () {
      final entries = [_entry('Language'), _entry('Backups')];
      expect(filterMenuSearchEntries(entries, ''), isEmpty);
      expect(filterMenuSearchEntries(entries, '   '), isEmpty);
    });

    test('matches on title, description, breadcrumb and keywords', () {
      final entries = [
        _entry('Language'),
        _entry('Battery saver', description: 'Reduces animations'),
        _entry('Haptic feedback', keywords: const ['вибрация']),
        _entry('Enter to send', breadcrumb: const ['Menu', 'Desktop']),
      ];

      expect(
        filterMenuSearchEntries(entries, 'animations').single.title,
        'Battery saver',
      );
      expect(
        filterMenuSearchEntries(entries, 'вибрация').single.title,
        'Haptic feedback',
      );
      expect(
        filterMenuSearchEntries(entries, 'desktop').single.title,
        'Enter to send',
      );
    });

    test('is case insensitive and requires every token to match', () {
      final entries = [
        _entry('Hide token count', description: 'Chat'),
        _entry('Hide generation time', description: 'Chat'),
      ];

      expect(filterMenuSearchEntries(entries, 'HIDE').length, 2);
      expect(
        filterMenuSearchEntries(entries, 'hide token').single.title,
        'Hide token count',
      );
      expect(filterMenuSearchEntries(entries, 'hide missing'), isEmpty);
    });

    test('ranks a title prefix above a title hit above a description hit', () {
      final entries = [
        _entry('Battery saver', description: 'Lower the language load'),
        _entry('Interface language'),
        _entry('Language'),
      ];

      expect(filterMenuSearchEntries(entries, 'language').map((e) => e.title), [
        'Language',
        'Interface language',
        'Battery saver',
      ]);
    });

    test('keeps menu order between equally scored hits', () {
      final entries = [
        _entry('Hide message id'),
        _entry('Hide generation time'),
        _entry('Hide token count'),
      ];

      expect(filterMenuSearchEntries(entries, 'hide').map((e) => e.title), [
        'Hide message id',
        'Hide generation time',
        'Hide token count',
      ]);
    });
  });
}
