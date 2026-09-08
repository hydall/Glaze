import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Quick Access refresh contract', () {
    test('uses the canonical active API configuration', () {
      final source = File(
        'lib/features/chat/services/magic_drawer_stats_service.dart',
      ).readAsStringSync();

      expect(source, contains('await _ref.read(apiListProvider.future);'));
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
      final nextMethod = source.indexOf(
        'Future<void> _showStudioMenu()',
        handlerStart,
      );
      final handler = source.substring(handlerStart, nextMethod);

      expect(handler, contains('try {'));
      expect(handler, contains('finally {'));
      expect(handler, contains('if (mounted) await _refreshStats();'));
      expect(handler, contains('await showPromptInspectorSheet('));
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
  });
}
