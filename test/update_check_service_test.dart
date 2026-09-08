import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/update_check_service.dart';

void main() {
  group('parseVersion', () {
    test('accepts a bare and a v-prefixed tag', () {
      expect(UpdateCheckService.parseVersion('0.7.1'), [0, 7, 1]);
      expect(UpdateCheckService.parseVersion('v0.7.1'), [0, 7, 1]);
      expect(UpdateCheckService.parseVersion('V0.7.1'), [0, 7, 1]);
    });

    test('drops pre-release and build metadata', () {
      expect(UpdateCheckService.parseVersion('0.7.1-alpha'), [0, 7, 1]);
      expect(UpdateCheckService.parseVersion('v0.7.1+3'), [0, 7, 1]);
      expect(UpdateCheckService.parseVersion('0.6.3-alpha.2'), [0, 6, 3]);
    });

    test('tolerates a short version', () {
      expect(UpdateCheckService.parseVersion('1.2'), [1, 2]);
      expect(UpdateCheckService.parseVersion('3'), [3]);
    });

    test('returns null for anything non-numeric', () {
      expect(UpdateCheckService.parseVersion(''), isNull);
      expect(UpdateCheckService.parseVersion('v'), isNull);
      expect(UpdateCheckService.parseVersion('nightly'), isNull);
      expect(UpdateCheckService.parseVersion('1.x.3'), isNull);
    });
  });

  group('compareVersions', () {
    test('orders by numeric component, not lexically', () {
      // The classic trap: "0.10.0" sorts before "0.9.0" as a string.
      expect(
        UpdateCheckService.compareVersions([0, 10, 0], [0, 9, 0]),
        greaterThan(0),
      );
      expect(
        UpdateCheckService.compareVersions([0, 9, 0], [0, 10, 0]),
        lessThan(0),
      );
    });

    test('treats a missing component as zero', () {
      expect(UpdateCheckService.compareVersions([0, 7], [0, 7, 0]), 0);
      expect(
        UpdateCheckService.compareVersions([0, 7, 1], [0, 7]),
        greaterThan(0),
      );
    });

    test('reports equality', () {
      expect(UpdateCheckService.compareVersions([1, 2, 3], [1, 2, 3]), 0);
    });

    test('a same-version release is not an update', () {
      final installed = UpdateCheckService.parseVersion('0.7.0')!;
      final latest = UpdateCheckService.parseVersion('v0.7.0')!;
      expect(UpdateCheckService.compareVersions(latest, installed), 0);
    });

    test('a pre-release tag of the installed version is not an update', () {
      // 'v0.7.0-rc1' parses to 0.7.0, so it must not read as newer than 0.7.0.
      final installed = UpdateCheckService.parseVersion('0.7.0')!;
      final latest = UpdateCheckService.parseVersion('v0.7.0-rc1')!;
      expect(
        UpdateCheckService.compareVersions(latest, installed),
        lessThanOrEqualTo(0),
      );
    });
  });

  group('releaseNotes', () {
    test('flattens GitHub generated notes into one line per change', () {
      const body = '''
## What's Changed
* Memory book rework by @hydall in https://github.com/hydall/Glaze/pull/1
* Cloud sync fixes by @danvitv in https://github.com/hydall/Glaze/pull/2

**Full Changelog**: https://github.com/hydall/Glaze/compare/v0.7.0...v0.8.0
''';
      expect(UpdateCheckService.releaseNotes(body), [
        'Memory book rework by @hydall in https://github.com/hydall/Glaze/pull/1',
        'Cloud sync fixes by @danvitv in https://github.com/hydall/Glaze/pull/2',
      ]);
    });

    test('drops the Full Changelog footer', () {
      const body = 'one\n\n**Full Changelog**: https://example.invalid/compare';
      expect(UpdateCheckService.releaseNotes(body), ['one']);
    });

    test('strips assorted bullet markers', () {
      expect(UpdateCheckService.releaseNotes('- one\n* two\n• three'), [
        'one',
        'two',
        'three',
      ]);
    });

    test('returns empty for an absent or non-string body', () {
      expect(UpdateCheckService.releaseNotes(null), isEmpty);
      expect(UpdateCheckService.releaseNotes(42), isEmpty);
      expect(UpdateCheckService.releaseNotes('   \n\n  '), isEmpty);
      expect(UpdateCheckService.releaseNotes('## Heading only'), isEmpty);
    });
  });

  group('UpdateInfo', () {
    test('extraNotes reports how many were capped away', () {
      final info = UpdateInfo(
        source: UpdateSource.ciBuild,
        dismissId: 'abc',
        label: '#12',
        createdAt: DateTime.utc(2026, 1, 1),
        url: 'https://example.invalid',
        notes: const ['a', 'b'],
        totalNotes: 7,
      );
      expect(info.extraNotes, 5);
    });

    test('extraNotes is zero when nothing was capped', () {
      final info = UpdateInfo(
        source: UpdateSource.release,
        dismissId: 'v1.0.0',
        label: 'v1.0.0',
        createdAt: DateTime.utc(2026, 1, 1),
        url: 'https://example.invalid',
        notes: const ['a', 'b'],
        totalNotes: 2,
      );
      expect(info.extraNotes, 0);
    });
  });
}
