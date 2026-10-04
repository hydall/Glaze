import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_provider.dart';

void main() {
  // JanitorAI has two tag vocabularies. The curated ones (`/hampter/tags`) are
  // searched by numeric id; a custom tag is free text, searched through
  // `custom_tags[]` — which `janitorSearch` has always sent and the filter
  // sheet has always accepted, but only if the reader typed it. The popular
  // ones ride along with every listing as `top_custom_tags` and were thrown
  // away, so half the vocabulary was reachable only by knowing it already.
  group('parseTopCustomTags', () {
    test('reads bare strings in the order they were ranked', () {
      expect(
        parseTopCustomTags(['femboy', 'yandere', 'oc']),
        ['femboy', 'yandere', 'oc'],
      );
    });

    test('reads objects by whichever name field they carry', () {
      expect(
        parseTopCustomTags([
          {'name': 'femboy', 'count': 900},
          {'tag': 'yandere'},
          {'slug': 'slice-of-life'},
        ]),
        ['femboy', 'yandere', 'slice-of-life'],
      );
    });

    test('drops duplicates without reordering the survivors', () {
      expect(
        parseTopCustomTags(['Femboy', 'oc', 'femboy', 'OC', 'vampire']),
        ['Femboy', 'oc', 'vampire'],
      );
    });

    test('skips what it cannot read instead of failing the search', () {
      // This runs inside the response parsing of every listing request, so a
      // surprise in one entry must not cost the reader their search results.
      expect(
        parseTopCustomTags(['ok', '', '   ', 42, null, <String>[], <String, Object>{}]),
        ['ok'],
      );
    });

    test('a payload without the field is simply no custom tags', () {
      expect(parseTopCustomTags(null), isEmpty);
      expect(parseTopCustomTags('femboy'), isEmpty);
      expect(parseTopCustomTags(const <Object>[]), isEmpty);
    });
  });

  group('withPopularCustomTags', () {
    const curated = [
      CatalogTag(id: 49, name: 'Action'),
      CatalogTag(id: 50, name: 'Romance'),
    ];

    test('appends after the curated tags, never among them', () {
      final merged = withPopularCustomTags(curated, ['femboy', 'oc']);

      expect(merged.map((t) => t.name), [
        'Action',
        'Romance',
        'femboy',
        'oc',
      ]);
      // Selecting one has to land in `custom_tags[]`, and it is the absent id
      // that routes it there.
      expect(merged.last.id, isNull);
      expect(merged.first.id, 49);
    });

    test('a custom tag duplicating a curated one is not listed twice', () {
      final merged = withPopularCustomTags(curated, ['romance', 'femboy']);

      expect(merged.map((t) => t.name), ['Action', 'Romance', 'femboy']);
    });

    test('nothing popular leaves the curated list exactly as it was', () {
      expect(withPopularCustomTags(curated, const []), curated);
    });

    test('no curated tags is still a usable list', () {
      // `/hampter/tags` can fail or return nothing; the popular ones are then
      // all there is to offer.
      final merged = withPopularCustomTags(const [], ['femboy']);
      expect(merged.single.name, 'femboy');
    });
  });

  group('the listing a search already makes is where these come from', () {
    final source = File(
      'lib/features/catalog/services/janitor_provider.dart',
    ).readAsStringSync();

    /// The brace group that starts at [from], by matching.
    ({String text, int end}) braceGroup(int from) {
      final open = source.indexOf('{', from);
      expect(open, greaterThan(-1), reason: 'no brace after offset $from');
      var depth = 0;
      for (var i = open; i < source.length; i++) {
        if (source[i] == '{') depth++;
        if (source[i] == '}') {
          depth--;
          if (depth == 0) {
            return (text: source.substring(open, i + 1), end: i + 1);
          }
        }
      }
      fail('unbalanced braces after offset $from');
    }

    /// Body of the function named [signature]. A named-parameter list is a
    /// brace group of its own, so the first group after the signature is
    /// skipped when the body follows it.
    String bodyOf(String signature) {
      final start = source.indexOf(signature);
      expect(start, greaterThan(-1), reason: 'missing $signature');
      final first = braceGroup(start);
      final after = source.substring(first.end, source.indexOf('{', first.end));
      return after.contains(')') ? braceGroup(first.end).text : first.text;
    }

    test('the search itself harvests them, so no extra request is needed', () {
      // Asserted against `janitorSearch`'s own body, not the file: the
      // standalone fetch mentions the same call, and matching that instead
      // would let the harvest be deleted without anything noticing.
      expect(
        bodyOf('Future<CatalogSearchResult> janitorSearch('),
        contains("parseTopCustomTags(data['top_custom_tags'])"),
      );
    });

    test('and selecting one is sent as a custom tag, not a tag id', () {
      expect(source, contains(r"&custom_tags[]=${Uri.encodeComponent(tagName)}"));
    });
  });
}
