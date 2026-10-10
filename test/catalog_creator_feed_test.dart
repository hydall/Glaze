import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/services/catalog_creators.dart';

void main() {
  CatalogItem item({String? creator, String? creatorId, String? creatorRef}) =>
      CatalogItem(
        id: 'c1',
        name: 'Card',
        creator: creator,
        creatorId: creatorId,
        creatorRef: creatorRef,
      );

  test('DataCat opens by ref, not by raw id', () {
    final feed = catalogCreatorFeedFor(
      item(creatorId: 'raw', creatorRef: 'saucepan:raw'),
      CatalogProvider.datacat,
    );
    expect(feed, isA<DatacatCreatorFeed>());
    expect((feed! as DatacatCreatorFeed).creatorRef, 'saucepan:raw');
    expect(
      catalogCreatorFeedFor(item(creatorId: 'raw'), CatalogProvider.datacat),
      isNull,
    );
  });

  test('JanitorAI opens by creator id and keeps the name for the profile', () {
    final feed = catalogCreatorFeedFor(
      item(creator: 'alice', creatorId: 'uuid-1'),
      CatalogProvider.janitor,
    );
    expect(feed, isA<JanitorCreatorFeed>());
    final janitor = feed! as JanitorCreatorFeed;
    expect(janitor.creatorId, 'uuid-1');
    expect(janitor.name, 'alice');
    expect(
      catalogCreatorFeedFor(item(creator: 'alice'), CatalogProvider.janitor),
      isNull,
    );
  });

  test('Chub opens by username and carries the account settings', () {
    final feed = catalogCreatorFeedFor(
      item(creator: 'bob', creatorId: 'bob'),
      CatalogProvider.chub,
      chubApiKey: 'key',
      chubAccountNsfl: true,
    );
    expect(feed, isA<ChubCreatorFeed>());
    final chub = feed! as ChubCreatorFeed;
    expect(chub.username, 'bob');
    expect(chub.apiKey, 'key');
    expect(chub.accountNsfl, isTrue);
    expect(feed.provider, CatalogProvider.chub);
  });

  test('JannyAI has no creator pages', () {
    expect(
      catalogCreatorFeedFor(
        item(creator: 'carol', creatorId: 'uuid-2'),
        CatalogProvider.janny,
      ),
      isNull,
    );
  });
}
