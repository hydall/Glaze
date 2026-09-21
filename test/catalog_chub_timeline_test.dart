import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/catalog_provider.dart';
import 'package:glaze_flutter/features/catalog/third_party_providers_provider.dart';

/// Chub's "Timeline" feed is served by its own endpoint that reads only `nsfw`
/// and `nsfl`. Selecting it must drop the query and every other filter, and keep
/// them from being set while it is active.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late StateNotifierProvider<CatalogNotifier, CatalogState> provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'gz_catalog_provider': 'chub',
      'gz_disabled_third_party_providers': <String>[],
    });
    provider = StateNotifierProvider<CatalogNotifier, CatalogState>(
      (ref) => CatalogNotifier(
        ref,
        fetchOverride: (_) async =>
            CatalogSearchResult(characters: const [], total: 0),
      ),
    );
    container = ProviderContainer();
    // Let the third-party loader settle so the saved chub provider survives.
    container.read(thirdPartyProvidersProvider);
    await pumpEventQueue();
    addTearDown(container.dispose);
  });

  Future<CatalogNotifier> started() async {
    final notifier = container.read(provider.notifier);
    await pumpEventQueue();
    return notifier;
  }

  test('selecting Timeline clears the query and the unsupported filters',
      () async {
    final notifier = await started();
    notifier.setQuery('dragon');
    notifier.setFilters(
      const CatalogFilters(
        sort: 'popular',
        nsfw: true,
        nsfl: true,
        tagIds: [7],
        tagNames: ['Fantasy'],
        minTokens: 500,
        maxTokens: 7000,
        nsfwOnly: true,
        requireImages: true,
        minAiRating: 4,
        minTags: 3,
      ),
    );
    await pumpEventQueue();

    notifier.setSort('timeline');
    await pumpEventQueue();

    final state = container.read(provider);
    expect(state.chubTimelineActive, isTrue);
    expect(state.query, '');
    // nsfw/nsfl are the only filters the feed accepts, so they survive.
    expect(state.filters.nsfw, isTrue);
    expect(state.filters.nsfl, isTrue);
    expect(state.filters.tagIds, isEmpty);
    expect(state.filters.tagNames, isEmpty);
    expect(state.filters.excludeTagNames, isEmpty);
    expect(state.filters.minTokens, 29);
    expect(state.filters.maxTokens, 100000);
    expect(state.filters.nsfwOnly, isFalse);
    expect(state.filters.requireImages, isFalse);
    expect(state.filters.minAiRating, 0);
    expect(state.filters.minTags, 0);
  });

  test('unsupported filters are stripped while Timeline is active', () async {
    final notifier = await started();
    notifier.setSort('timeline');
    await pumpEventQueue();

    notifier.setQuery('dragon');
    notifier.setFilters(
      const CatalogFilters(
        sort: 'timeline',
        nsfw: true,
        nsfl: true,
        tagIds: [7],
        tagNames: ['Fantasy'],
        nsfwOnly: true,
        requireLore: true,
        minAiRating: 4,
      ),
    );
    await pumpEventQueue();

    final state = container.read(provider);
    expect(state.query, '');
    expect(state.filters.nsfw, isTrue);
    expect(state.filters.nsfl, isTrue);
    expect(state.filters.tagIds, isEmpty);
    expect(state.filters.tagNames, isEmpty);
    expect(state.filters.nsfwOnly, isFalse);
    expect(state.filters.requireLore, isFalse);
    expect(state.filters.minAiRating, 0);
  });
}
