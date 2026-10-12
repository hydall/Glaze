import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/services/catalog_creators.dart';
import 'package:glaze_flutter/features/catalog/widgets/catalog_creator_screen.dart';

class _FakeFeed implements CatalogCreatorFeed {
  int nextCalls = 0;

  @override
  CatalogProvider get provider => CatalogProvider.chub;

  List<CatalogItem> _items(int from) => [
    for (var i = from; i < from + 4; i++)
      CatalogItem(id: 'c$i', name: 'Card $i', creator: 'bob'),
  ];

  @override
  Future<CatalogCreatorFirstPage> first(CatalogFilters filters) async =>
      CatalogCreatorFirstPage(
        profile: const CatalogCreatorProfile(
          name: 'Bob',
          handle: 'bob',
          about: 'Makes cards.',
          verified: true,
          characterCount: 8,
          followerCount: 3,
        ),
        characters: CatalogSearchResult(
          characters: _items(0),
          total: 8,
          hasMore: true,
        ),
      );

  @override
  Future<CatalogSearchResult> next(CatalogFilters filters) async {
    nextCalls++;
    return CatalogSearchResult(characters: _items(4), total: 8, hasMore: false);
  }
}

void main() {
  for (final size in const [Size(400, 800), Size(1300, 900)]) {
    testWidgets('lays out at ${size.width.toInt()} wide', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final feed = _FakeFeed();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: CatalogCreatorScreen(feed: feed)),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Makes cards.'), findsOneWidget);
      // A wide window shows the first page without scrolling, so the next
      // one is fetched straight away.
      if (size.width > 1000) expect(feed.nextCalls, 1);
    });
  }
}
