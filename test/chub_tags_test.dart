import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/catalog_http.dart';
import 'package:glaze_flutter/features/catalog/services/chub_provider.dart';
import 'package:glaze_flutter/shared/widgets/filter_sheet.dart';

/// Answers every catalog request from [reply] and keeps what was asked.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);

  final ({int status, String body}) Function(RequestOptions options) reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final answer = reply(options);
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _tags(List<(String, int)> tags) => jsonEncode({
  'count': tags.length,
  'tags': [
    for (final (name, n) in tags)
      {'id': name.length, 'name': name, 'non_private_projects_count': n},
  ],
});

void main() {
  group('parseChubTags', () {
    test('orders by card count, lowercases and drops duplicates', () {
      final tags = parseChubTags(
        jsonDecode(
              _tags([('Fantasy', 10), ('female', 50), ('fantasy', 3), ('', 9)]),
            )
            as Map<String, dynamic>,
      );
      expect(tags.map((t) => t.name), ['female', 'fantasy']);
      // Name-only: Chub filters by topic name, so an id would send the pick to
      // tagIds, which chub search ignores.
      expect(tags.every((t) => t.id == null), isTrue);
    });
  });

  group('fetchChubTags', () {
    setUp(resetChubTagCache);

    test('reads the tag index in one request', () async {
      final adapter = _Adapter(
        (o) => (status: 200, body: _tags([('female', 5), ('elf', 2)])),
      );
      setCatalogHttpAdapter(adapter);

      final tags = await fetchChubTags();

      expect(tags.map((t) => t.name), ['female', 'elf']);
      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.single;
      expect(req.method, 'POST');
      expect(req.uri.path, '/tags');
      expect(jsonDecode(req.data as String), containsPair('limit', 500));
    });

    test('falls back to sampling search results when the index fails',
        () async {
      final adapter = _Adapter((o) {
        if (o.uri.path == '/tags') return (status: 500, body: '{}');
        return (
          status: 200,
          body: jsonEncode({
            'nodes': [
              {
                'topics': ['Elf', 'female'],
              },
              {
                'topics': ['female'],
              },
            ],
          }),
        );
      });
      setCatalogHttpAdapter(adapter);

      final tags = await fetchChubTags();

      expect(tags.map((t) => t.name), ['female', 'elf']);
    });

    test('does not cache an empty result', () async {
      setCatalogHttpAdapter(_Adapter((o) => (status: 500, body: '{}')));
      expect(await fetchChubTags(), isEmpty);

      setCatalogHttpAdapter(
        _Adapter((o) => (status: 200, body: _tags([('elf', 1)]))),
      );
      expect((await fetchChubTags()).map((t) => t.name), ['elf']);
    });
  });

  test('fetchChubTagSuggestions searches the index by name', () async {
    final adapter = _Adapter(
      (o) => (status: 200, body: _tags([('genshin impact', 9)])),
    );
    setCatalogHttpAdapter(adapter);

    expect(await fetchChubTagSuggestions(' gen '), ['genshin impact']);
    expect(
      jsonDecode(adapter.requests.single.data as String),
      containsPair('search', 'gen'),
    );

    setCatalogHttpAdapter(_Adapter((o) => (status: 500, body: '{}')));
    expect(await fetchChubTagSuggestions('gen'), isEmpty);
  });

  group('FilterSheet', () {
    Future<void> pump(WidgetTester tester, List<FilterSection> sections) {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: FilterSheet(title: 'Filters', sections: sections),
            ),
          ),
        ),
      );
    }

    FilterTagsSection tagsSection({
      required List<String> names,
      Set<String> selected = const {},
      ValueChanged<FilterTag>? onToggle,
      Future<List<String>> Function(String)? fetchSuggestions,
    }) {
      return FilterTagsSection(
        title: 'Tags',
        searchHint: 'Search',
        tags: [for (final n in names) FilterTag(name: n)],
        selectedIds: const {},
        selectedNames: selected,
        onToggle: onToggle ?? (_) {},
        onClear: () {},
        fetchSuggestions: fetchSuggestions,
        collapsedCount: 10,
      );
    }

    testWidgets('folds a long tag list and opens it on demand', (tester) async {
      await pump(tester, [
        tagsSection(names: [for (var i = 0; i < 40; i++) 'tag$i']),
      ]);

      expect(find.byType(FilterTagChip), findsNWidgets(10));
      await tester.tap(find.byType(TextButton).last);
      await tester.pump();
      expect(find.byType(FilterTagChip), findsNWidgets(40));
    });

    testWidgets('keeps a short list unfolded', (tester) async {
      await pump(tester, [
        tagsSection(names: [for (var i = 0; i < 14; i++) 'tag$i']),
      ]);
      expect(find.byType(FilterTagChip), findsNWidgets(14));
    });

    testWidgets('a selected tag is not repeated in the grid', (tester) async {
      await pump(tester, [
        tagsSection(names: ['elf', 'orc'], selected: {'elf'}),
      ]);
      expect(find.text('elf'), findsOneWidget);
      expect(find.text('orc'), findsOneWidget);
    });

    testWidgets('search shows tags only the remote index knows',
        (tester) async {
      FilterTag? picked;
      await pump(tester, [
        tagsSection(
          names: ['elf'],
          onToggle: (t) => picked = t,
          fetchSuggestions: (q) async => ['genshin impact'],
        ),
      ]);

      await tester.enterText(find.byType(TextField), 'gen');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.text('elf'), findsNothing);
      await tester.tap(find.text('genshin impact'));
      expect(picked?.name, 'genshin impact');
    });

    testWidgets('a number commits as it is typed, without Enter',
        (tester) async {
      var value = 0;
      await pump(tester, [
        FilterNumberSection(
          title: 'Min rating',
          label: 'Min',
          value: 0,
          onChanged: (v) => value = v,
        ),
      ]);

      await tester.enterText(find.byType(TextField), '4');
      expect(value, 4);
    });
  });
}
