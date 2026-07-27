import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/catalog_provider.dart';
import 'package:glaze_flutter/features/catalog/third_party_providers_provider.dart';

/// Regression tests for the catalog provider switch race: picking a second
/// provider while the first one is still loading used to be a no-op (the
/// `state.loading` guard swallowed the reset-search), so the first provider's
/// results landed under the second provider's label.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CatalogItem item(String id) => CatalogItem(id: id, name: 'char-$id');

  /// Records every fetch and lets the test resolve them out of order.
  final pending = <(CatalogProvider, Completer<CatalogSearchResult>)>[];

  CatalogFetcher makeFetcher() => (provider) {
    final completer = Completer<CatalogSearchResult>();
    pending.add((provider, completer));
    return completer.future;
  };

  late ProviderContainer container;
  late StateNotifierProvider<CatalogNotifier, CatalogState> testCatalogProvider;

  setUp(() async {
    pending.clear();
    // Start on chub: janitor/janny kick off a real tag fetch inside search().
    // With the new janitor-only default we must also ensure all providers are
    // marked enabled so the catalog sees chub / datacat.
    SharedPreferences.setMockInitialValues({
      'gz_catalog_provider': 'chub',
      'gz_disabled_third_party_providers': <String>[],
    });
    testCatalogProvider =
        StateNotifierProvider<CatalogNotifier, CatalogState>(
          (ref) => CatalogNotifier(ref, fetchOverride: makeFetcher()),
        );
    container = ProviderContainer();
    // Let the third-party provider loader settle so enabledCatalogProvidersProvider
    // sees the saved (all-enabled) set before the catalog notifier queries it.
    container.read(thirdPartyProvidersProvider);
    await pumpEventQueue();
    addTearDown(container.dispose);
  });

  Future<CatalogNotifier> startedNotifier() async {
    final notifier = container.read(testCatalogProvider.notifier);
    // Let _loadSavedState resolve prefs and fire its initial search.
    await pumpEventQueue();
    expect(pending.length, 1);
    expect(pending.first.$1, CatalogProvider.chub);
    return notifier;
  }

  test('switching provider mid-load fetches the new provider', () async {
    final notifier = await startedNotifier();

    // chub is still in flight; the user picks datacat.
    unawaited(notifier.setProvider(CatalogProvider.datacat));
    await pumpEventQueue();

    expect(
      container.read(testCatalogProvider).activeProvider,
      CatalogProvider.datacat,
    );
    // The reset-search must not have been swallowed by the in-flight chub load.
    expect(pending.length, 2);
    expect(pending[1].$1, CatalogProvider.datacat);
  });

  test('late result from the previous provider is discarded', () async {
    final notifier = await startedNotifier();

    unawaited(notifier.setProvider(CatalogProvider.datacat));
    await pumpEventQueue();

    // The new provider answers first.
    pending[1].$2.complete(
      CatalogSearchResult(characters: [item('datacat-1')], total: 1),
    );
    await pumpEventQueue();

    var state = container.read(testCatalogProvider);
    expect(state.results.map((c) => c.id), ['datacat-1']);
    expect(state.loading, isFalse);
    expect(state.page, 2);

    // The superseded chub request resolves late and must be dropped.
    pending[0].$2.complete(
      CatalogSearchResult(characters: [item('chub-1')], total: 1),
    );
    await pumpEventQueue();

    state = container.read(testCatalogProvider);
    expect(state.activeProvider, CatalogProvider.datacat);
    expect(state.results.map((c) => c.id), ['datacat-1']);
    expect(state.page, 2, reason: 'stale page must not bump pagination');
  });

  test('late error from the previous provider is discarded', () async {
    final notifier = await startedNotifier();

    unawaited(notifier.setProvider(CatalogProvider.datacat));
    await pumpEventQueue();

    pending[1].$2.complete(
      CatalogSearchResult(characters: [item('datacat-1')], total: 1),
    );
    await pumpEventQueue();

    pending[0].$2.completeError(Exception('chub timed out'));
    await pumpEventQueue();

    final state = container.read(testCatalogProvider);
    expect(state.error, isNull);
    expect(state.loading, isFalse);
    expect(state.results.map((c) => c.id), ['datacat-1']);
  });

  test('the last of two rapid picks wins', () async {
    final notifier = await startedNotifier();

    // Two picks back to back, before the first one's prefs read resolves.
    unawaited(notifier.setProvider(CatalogProvider.datacat));
    unawaited(notifier.setProvider(CatalogProvider.chub));
    await pumpEventQueue();

    expect(
      container.read(testCatalogProvider).activeProvider,
      CatalogProvider.chub,
    );
    expect(
      pending.map((p) => p.$1),
      isNot(contains(CatalogProvider.datacat)),
      reason: 'the superseded pick must not fetch',
    );

    // The final pick's fetch is the one that fills the grid.
    pending.last.$2.complete(
      CatalogSearchResult(characters: [item('chub-1')], total: 1),
    );
    await pumpEventQueue();
    expect(
      container.read(testCatalogProvider).results.map((c) => c.id),
      ['chub-1'],
    );
  });

  test('a saved provider that is now disabled is not restored', () async {
    // disable chub, janitor, and janny so only datacat remains enabled
    final tpNotifier = container.read(thirdPartyProvidersProvider.notifier);
    await tpNotifier.setEnabled(ThirdPartyProvider.chub, false);
    await tpNotifier.setEnabled(ThirdPartyProvider.janitor, false);
    await tpNotifier.setEnabled(ThirdPartyProvider.janny, false);
    await tpNotifier.setEnabled(ThirdPartyProvider.saucepan, false);
    expect(container.read(enabledCatalogProvidersProvider), [
      CatalogProvider.datacat,
    ]);

    container.read(testCatalogProvider.notifier);
    await pumpEventQueue();

    expect(
      container.read(testCatalogProvider).activeProvider,
      CatalogProvider.datacat,
    );
    expect(
      pending.map((p) => p.$1),
      [CatalogProvider.datacat],
      reason: 'restore must not fetch the disabled provider first',
    );
  });

  test('loadMore is still ignored while a page is in flight', () async {
    final notifier = await startedNotifier();

    pending[0].$2.complete(
      CatalogSearchResult(characters: [item('chub-1')], total: 10),
    );
    await pumpEventQueue();

    unawaited(notifier.loadMore());
    await pumpEventQueue();
    expect(pending.length, 2);

    // Second loadMore while page 2 is in flight must not stack another request.
    unawaited(notifier.loadMore());
    await pumpEventQueue();
    expect(pending.length, 2);

    pending[1].$2.complete(
      CatalogSearchResult(characters: [item('chub-2')], total: 10),
    );
    await pumpEventQueue();

    final state = container.read(testCatalogProvider);
    expect(state.results.map((c) => c.id), ['chub-1', 'chub-2']);
  });
}
