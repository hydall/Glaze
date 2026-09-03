import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glaze_flutter/features/chat/state/magic_drawer_stats_cache.dart';
import 'package:glaze_flutter/features/chat/widgets/magic_drawer_models.dart';

void main() {
  group('Quick Access refresh contract', () {
    test('uses the canonical active API configuration', () {
      final source = File(
        'lib/features/chat/services/magic_drawer_stats_service.dart',
      ).readAsStringSync();

      // The API list is warmed through its provider and the active config is
      // read from activeApiConfigProvider — never straight from the repo.
      // Matched loosely: computeStats starts the read as one of a batch of
      // parallel futures, so the exact call formatting is not the contract.
      expect(source, contains('_ref.read(apiListProvider.future)'));
      expect(source, contains('await apiListFuture;'));
      expect(source, contains('_ref.read(activeApiConfigProvider)'));
      expect(source, isNot(contains('apiConfigRepoProvider')));
    });

    test('refreshes stats after every action route closes', () {
      final source = File(
        'lib/features/chat/widgets/magic_drawer.dart',
      ).readAsStringSync();

      final handlerStart = source.indexOf(
        'Future<void> _handleTap(MagicDrawerItemDef item)',
      );
      final nextMethod = source.indexOf('\n  @override', handlerStart);
      final handler = source.substring(handlerStart, nextMethod);

      expect(handler, contains('try {'));
      expect(handler, contains('finally {'));
      expect(handler, contains('if (mounted) await _refreshStats();'));
      // Every card routes through the one launcher, so a single try/finally
      // covers all of them. The launcher itself must not refresh: it also
      // serves the composer's pinned row, where there is no open drawer and
      // no stats on screen to bring up to date.
      expect(handler, contains('DrawerItemLauncher('));

      final launcher = File(
        'lib/features/chat/services/drawer_item_launcher.dart',
      ).readAsStringSync();
      expect(launcher, contains('await showPromptInspectorSheet('));
      expect(launcher, isNot(contains('_refreshStats')));
    });

    test('rejects token results calculated from an older stats snapshot', () {
      final source = File(
        'lib/features/chat/widgets/magic_drawer.dart',
      ).readAsStringSync();

      expect(source, contains('final request = _statsRequest;'));
      expect(
        source,
        contains('if (!mounted || request != _statsRequest) return;'),
      );
    });

    test('does not schedule token work after the drawer unmounts', () {
      final source = File(
        'lib/features/chat/widgets/magic_drawer.dart',
      ).readAsStringSync();

      final schedulerStart = source.indexOf('void _scheduleTokenStats()');
      final schedulerEnd = source.indexOf(
        'Future<void> _loadTokenStats()',
        schedulerStart,
      );
      final refreshStart = source.indexOf('Future<void> _refreshStats()');
      final refreshEnd = source.indexOf(
        'void _scheduleRefresh()',
        refreshStart,
      );

      expect(
        source.substring(schedulerStart, schedulerEnd),
        contains('if (!mounted) return;'),
      );
      expect(
        source.substring(refreshStart, refreshEnd),
        contains('if (!mounted) return;'),
      );
    });

    test('keeps cached stats isolated between sessions of one character', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const first = (charId: 'character', sessionId: 'session-a');
      const second = (charId: 'character', sessionId: 'session-b');

      container.read(magicDrawerStatsCacheProvider(first).notifier).state =
          const MagicDrawerStats(memoryEntryCount: 13);

      expect(
        container.read(magicDrawerStatsCacheProvider(first))?.memoryEntryCount,
        13,
      );
      expect(container.read(magicDrawerStatsCacheProvider(second)), isNull);
    });

    test('keys the MemoryBook controller subtree by active session', () {
      final source = File(
        'lib/features/chat/widgets/memory_sheet.dart',
      ).readAsStringSync();

      expect(source, contains('key: ValueKey(session.id)'));
    });
  });
}
