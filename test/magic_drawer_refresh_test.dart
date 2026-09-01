import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
      // The dispatch lives in MagicDrawerActions, shared with the desktop
      // sidebar strip. Its half of the contract is that every action is
      // awaited inside a try/finally that runs the caller's [onFinished].
      final actions = File(
        'lib/features/chat/services/magic_drawer_actions.dart',
      ).readAsStringSync();

      final handlerStart = actions.indexOf('Future<void> handleTap(');
      final nextMethod = actions.indexOf(
        'Future<void> _showCardRewriter(',
        handlerStart,
      );
      expect(handlerStart, isNonNegative);
      expect(nextMethod, greaterThan(handlerStart));
      final handler = actions.substring(handlerStart, nextMethod);

      expect(handler, contains('try {'));
      expect(handler, contains('finally {'));
      expect(handler, contains('if (onFinished != null) await onFinished();'));
      expect(handler, contains('await showPromptInspectorSheet('));

      // The panel's half: it hands in a refresh, so a closed route still
      // brings the card subtitles back up to date.
      final panel = File(
        'lib/features/chat/widgets/magic_drawer.dart',
      ).readAsStringSync();
      expect(panel, contains('_actions.handleTap('));
      expect(panel, contains('if (mounted) await _refreshStats();'));
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
