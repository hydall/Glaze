import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';

/// Characterization test for the memory-workflow lease registry. Manual and
/// automatic memory jobs use [memoryActiveDraftsProvider] to coordinate work
/// for a session. Chat generation does not read this registry and may overlap.
void main() {
  group('MemoryActiveDraftsNotifier memory workflow leases', () {
    test('initial state is empty', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(memoryActiveDraftsProvider), isEmpty);
    });

    test('acquire adds a sessionId; isActive reports true', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(memoryActiveDraftsProvider.notifier).acquire('s1');

      expect(container.read(memoryActiveDraftsProvider), {'s1'});
      expect(
        container.read(memoryActiveDraftsProvider.notifier).isActive('s1'),
        isTrue,
      );
    });

    test('release removes a sessionId; isActive reports false', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(memoryActiveDraftsProvider.notifier);

      final lease = notifier.acquire('s1');
      lease.release();

      expect(container.read(memoryActiveDraftsProvider), isEmpty);
      expect(notifier.isActive('s1'), isFalse);
    });

    test('multiple sessionIds can be active simultaneously', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(memoryActiveDraftsProvider.notifier);

      final first = notifier.acquire('s1');
      final second = notifier.acquire('s2');
      final third = notifier.acquire('s3');

      expect(container.read(memoryActiveDraftsProvider), {'s1', 's2', 's3'});
      expect(notifier.isActive('s2'), isTrue);

      second.release();

      expect(container.read(memoryActiveDraftsProvider), {'s1', 's3'});
      expect(notifier.isActive('s2'), isFalse);
      first.release();
      third.release();
    });

    test('multiple owners keep a session active until all release', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(memoryActiveDraftsProvider.notifier);

      final first = notifier.acquire('s1');
      final second = notifier.acquire('s1');

      expect(container.read(memoryActiveDraftsProvider), {'s1'});
      first.release();
      expect(container.read(memoryActiveDraftsProvider), {'s1'});
      second.release();
      expect(container.read(memoryActiveDraftsProvider), isEmpty);
    });

    test('lease release is idempotent', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(memoryActiveDraftsProvider.notifier);

      final lease = notifier.acquire('s1');
      lease.release();
      lease.release();

      expect(container.read(memoryActiveDraftsProvider), isEmpty);
    });

    test('the notifier emits a NEW Set instance on every mutation', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(memoryActiveDraftsProvider.notifier);

      final before = container.read(memoryActiveDraftsProvider);
      notifier.acquire('s1');
      final after = container.read(memoryActiveDraftsProvider);

      expect(
        identical(before, after),
        isFalse,
        reason: 'set must be reassigned so listeners rebuild',
      );
    });

    test('exclusive acquisition fails while another owner is active', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(memoryActiveDraftsProvider.notifier);

      final first = notifier.tryAcquireExclusive('s1');
      expect(first, isNotNull);
      expect(notifier.tryAcquireExclusive('s1'), isNull);
      first!.release();
      expect(notifier.tryAcquireExclusive('s1'), isNotNull);
    });
  });
}
