import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/repositories/global_variables_repo.dart';
import 'package:glaze_flutter/features/extensions/state/message_variables_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('GlobalVariablesRepo', () {
    test('read returns an empty map when nothing is stored', () async {
      final repo = GlobalVariablesRepo.withPrefsLoader(
        SharedPreferences.getInstance,
      );
      expect(await repo.read(), <String, dynamic>{});
    });

    test('update persists a nested object across instances', () async {
      Future<GlobalVariablesRepo> build() async =>
          GlobalVariablesRepo.withPrefsLoader(
            SharedPreferences.getInstance,
          );

      final repo1 = await build();
      await repo1.update((root) {
        root['flags'] = {'met': true};
        return root;
      });
      // Build a fresh instance — the storage is backed by the same
      // SharedPreferences mock, so the data must round-trip.
      final repo2 = await build();
      expect((await repo2.read())['flags'], {'met': true});
    });

    test('update serializes concurrent writes (no lost update)', () async {
      final repo = GlobalVariablesRepo.withPrefsLoader(
        SharedPreferences.getInstance,
      );

      // Fire 20 concurrent updates that all increment a counter.
      final futures = <Future<void>>[];
      for (var i = 0; i < 20; i++) {
        futures.add(repo.update((root) {
          final n = (root['counter'] as int?) ?? 0;
          root['counter'] = n + 1;
          return root;
        }));
      }
      await Future.wait(futures);
      expect((await repo.read())['counter'], 20);
    });

    test('replaceAll clears missing keys', () async {
      final repo = GlobalVariablesRepo.withPrefsLoader(
        SharedPreferences.getInstance,
      );
      await repo.replaceAll({'a': 1, 'b': 2});
      await repo.replaceAll({'a': 1});
      expect(await repo.read(), {'a': 1});
    });

    test('update rejects payloads over the size cap', () async {
      final repo = GlobalVariablesRepo.withPrefsLoader(
        SharedPreferences.getInstance,
      );
      // 70 KiB string (cap is 64 KiB).
      final big = 'x' * (70 * 1024);
      expect(
        () => repo.replaceAll({'huge': big}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('MessageVariablesNotifier', () {
    test('reads return an empty map for unknown message ids', () {
      final notifier = MessageVariablesNotifier();
      expect(notifier.read('s1', 'm1'), <String, dynamic>{});
    });

    test('update writes a per-message payload', () {
      final notifier = MessageVariablesNotifier();
      notifier.update('s1', 'm1', (root) {
        root['mood'] = 'tense';
        return root;
      });
      expect(notifier.read('s1', 'm1'), {'mood': 'tense'});
      expect(notifier.read('s1', 'm2'), <String, dynamic>{});
    });

    test('messages in different sessions do not collide', () {
      final notifier = MessageVariablesNotifier();
      notifier.update('s1', 'm1', (root) {
        root['x'] = 1;
        return root;
      });
      notifier.update('s2', 'm1', (root) {
        root['x'] = 2;
        return root;
      });
      expect(notifier.read('s1', 'm1'), {'x': 1});
      expect(notifier.read('s2', 'm1'), {'x': 2});
    });

    test('clearSession drops every message in the session', () {
      final notifier = MessageVariablesNotifier();
      notifier.update('s1', 'm1', (root) {
        root['x'] = 1;
        return root;
      });
      notifier.update('s1', 'm2', (root) {
        root['x'] = 2;
        return root;
      });
      notifier.update('s2', 'm1', (root) {
        root['x'] = 3;
        return root;
      });
      notifier.clearSession('s1');
      expect(notifier.read('s1', 'm1'), <String, dynamic>{});
      expect(notifier.read('s1', 'm2'), <String, dynamic>{});
      expect(notifier.read('s2', 'm1'), {'x': 3});
    });

    test('clearMessage drops only the targeted message', () {
      final notifier = MessageVariablesNotifier();
      notifier.update('s1', 'm1', (root) {
        root['x'] = 1;
        return root;
      });
      notifier.update('s1', 'm2', (root) {
        root['x'] = 2;
        return root;
      });
      notifier.clearMessage('s1', 'm1');
      expect(notifier.read('s1', 'm1'), <String, dynamic>{});
      expect(notifier.read('s1', 'm2'), {'x': 2});
    });

    test('Riverpod provider exposes the same notifier instance', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(messageVariablesProvider.notifier);
      notifier.update('s1', 'm1', (root) {
        root['k'] = 'v';
        return root;
      });
      expect(container.read(messageVariablesProvider)['s1::m1']!.vars,
          {'k': 'v'});
    });
  });
}
