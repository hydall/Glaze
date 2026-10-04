import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/tools/tools_layout_service.dart';
import 'package:glaze_flutter/features/tools/tools_tile_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds a live [WidgetRef] backed by a fresh [ProviderContainer], with the
  /// mock SharedPreferences seeded from [prefs].
  Future<WidgetRef> makeRef(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    late WidgetRef widgetRef;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, child) {
            widgetRef = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    return widgetRef;
  }

  List<ToolsTileDef> catalog() => buildToolsTileCatalog();

  group('ToolsTileSize', () {
    test('cycles small -> wide -> large -> small', () {
      expect(ToolsTileSize.small.next, ToolsTileSize.wide);
      expect(ToolsTileSize.wide.next, ToolsTileSize.large);
      expect(ToolsTileSize.large.next, ToolsTileSize.small);
    });

    test('small is single-column, wide and large span both', () {
      expect(ToolsTileSize.small.columns, 1);
      expect(ToolsTileSize.wide.columns, 2);
      expect(ToolsTileSize.large.columns, 2);
    });
  });

  group('catalog', () {
    test('ids are unique', () {
      final ids = catalog().map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every def carries an icon or svg path', () {
      for (final tile in catalog()) {
        expect(
          tile.svgPath != null || tile.icon != null,
          isTrue,
          reason: tile.id,
        );
      }
    });
  });

  group('ToolsLayoutService', () {
    testWidgets('defaults to the catalog order with no stored layout', (
      tester,
    ) async {
      final ref = await makeRef(tester);
      final layout = await ToolsLayoutService(ref).loadLayout(catalog());
      expect(layout.itemIds, catalog().map((t) => t.id).toList());
      expect(layout.sizes, isEmpty);
      expect(layout.deletedIds, isEmpty);
    });

    testWidgets('round-trips order, sizes and deleted ids', (tester) async {
      final ref = await makeRef(tester);
      final svc = ToolsLayoutService(ref);
      await svc.saveLayout(
        ['api', 'personas'],
        {'api': ToolsTileSize.wide, 'personas': ToolsTileSize.small},
        {'stats'},
      );

      final layout = await svc.loadLayout(catalog());
      expect(layout.itemIds.take(2).toList(), ['api', 'personas']);
      expect(layout.itemIds, isNot(contains('stats')));
      expect(
        layout.itemIds.toSet(),
        catalog().map((t) => t.id).where((id) => id != 'stats').toSet(),
      );
      expect(layout.sizes, {
        'api': ToolsTileSize.wide,
        'personas': ToolsTileSize.small,
      });
      expect(layout.deletedIds, {'stats'});
    });

    testWidgets('drops ids this build no longer knows', (tester) async {
      final ref = await makeRef(
        tester,
        prefs: {
          ToolsLayoutService.orderKey: ['api', 'gone-tile'],
        },
      );
      final layout = await ToolsLayoutService(ref).loadLayout(catalog());
      expect(layout.itemIds, contains('api'));
      expect(layout.itemIds, isNot(contains('gone-tile')));
    });

    testWidgets('appends a new tile the stored order is missing', (
      tester,
    ) async {
      final ref = await makeRef(
        tester,
        prefs: {
          ToolsLayoutService.orderKey: ['api'],
        },
      );
      final layout = await ToolsLayoutService(ref).loadLayout(catalog());
      expect(layout.itemIds.first, 'api');
      final tail = layout.itemIds.skip(1).toList();
      expect(
        tail.toSet(),
        catalog().map((t) => t.id).where((id) => id != 'api').toSet(),
      );
    });

    testWidgets('keeps a deleted tile hidden across a fresh load', (
      tester,
    ) async {
      final ref = await makeRef(
        tester,
        prefs: {
          ToolsLayoutService.deletedKey: ['stats'],
        },
      );
      final layout = await ToolsLayoutService(ref).loadLayout(catalog());
      expect(layout.itemIds, isNot(contains('stats')));
      expect(layout.deletedIds, {'stats'});
    });

    testWidgets('ignores an unknown size name instead of crashing', (
      tester,
    ) async {
      final ref = await makeRef(
        tester,
        prefs: {
          ToolsLayoutService.sizesKey: ['api:huge', 'stats:wide'],
        },
      );
      final layout = await ToolsLayoutService(ref).loadLayout(catalog());
      expect(layout.sizes, {'stats': ToolsTileSize.wide});
    });
  });
}
