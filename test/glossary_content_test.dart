import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The glossary is content, not code, and nothing else checks it. A term that
/// exists in one language and not the other is an article a reader simply does
/// not get, and a `[[link]]` to a term that was renamed is a dead end inside
/// the article that needed it most.
void main() {
  final en = _Glossary('assets/translations/glossary_en.json');
  final ru = _Glossary('assets/translations/glossary_ru.json');

  test('every glossary term exists in both languages', () {
    expect(en.termIds, isNotEmpty);
    expect(ru.termIds, en.termIds);
    expect(ru.categoryIds, en.categoryIds);
  });

  test('the tokenizer estimate is explained in both languages', () {
    for (final glossary in [en, ru]) {
      final desc = glossary.descOf('token-estimate');
      expect(desc, contains('o200k_base'), reason: glossary.path);
      expect(desc, contains('[[token'), reason: glossary.path);
    }
  });

  test('every term link points at a term that exists', () {
    for (final glossary in [en, ru]) {
      for (final entry in glossary.links.entries) {
        for (final target in entry.value) {
          expect(
            glossary.termIds,
            contains(target),
            reason: '${glossary.path}: ${entry.key} links to missing $target',
          );
        }
      }
    }
  });

  test('a term listed under two categories says the same thing twice', () {
    // Cross-listing a term is allowed — `chat-session` is filed under both
    // Characters and Chat in EN. Two articles under one id that have *drifted*
    // are not: the id is what a link resolves to, and which copy a reader gets
    // would then depend on the order of the file.
    for (final glossary in [en, ru]) {
      for (final id in glossary.termIds) {
        final copies = glossary.copiesOf(id).toSet();
        expect(
          copies,
          hasLength(1),
          reason: '${glossary.path}: "$id" is defined twice, differently',
        );
      }
    }
  });
}

class _Glossary {
  _Glossary(this.path) {
    final decoded =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    for (final category in decoded['categories'] as List) {
      final map = category as Map<String, dynamic>;
      categoryIds.add('${map['id']}');
      for (final term in map['terms'] as List) {
        _terms.add((term as Map).cast<String, dynamic>());
      }
    }
  }

  final String path;
  final Set<String> categoryIds = <String>{};
  final List<Map<String, dynamic>> _terms = [];

  Set<String> get termIds => _terms.map((term) => '${term['id']}').toSet();

  Iterable<String> copiesOf(String id) =>
      _terms.where((term) => term['id'] == id).map((term) => '${term['desc']}');

  String descOf(String id) => copiesOf(id).first;

  /// Term id → the ids its article links to. `[[target]]` and
  /// `[[target|label]]` are the two forms the glossary renderer accepts.
  Map<String, Set<String>> get links => {
    for (final term in _terms)
      '${term['id']}': RegExp(r'\[\[([^\]]+)\]\]')
          .allMatches('${term['desc']}')
          .map((match) => match.group(1)!.split('|').first)
          .toSet(),
  };
}
