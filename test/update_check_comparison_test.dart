import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/constants/build_channel.dart';
import 'package:glaze_flutter/core/services/update_check_service.dart';

/// #132: the update sheet offered a build two weeks *older* than the installed
/// one. Availability was decided on SHA inequality alone — two different SHAs
/// were taken to mean the branch had moved on, when the installed build can
/// perfectly well be the newer of the two.
void main() {
  group('CommitComparison', () {
    test('a branch that has moved on is an update', () {
      const comparison = CommitComparison(status: 'ahead', commits: ['a']);
      expect(comparison.installedIsAtLeastAsNew, isFalse);
    });

    test('a branch behind the installed build is not', () {
      const comparison = CommitComparison(status: 'behind', commits: []);
      expect(comparison.installedIsAtLeastAsNew, isTrue);
    });

    test('the same commit under another name is not', () {
      const comparison = CommitComparison(status: 'identical', commits: []);
      expect(comparison.installedIsAtLeastAsNew, isTrue);
    });

    test('a diverged branch still counts as something to offer', () {
      // It carries commits the installed build does not, and it is the build
      // the channel is publishing.
      const comparison = CommitComparison(status: 'diverged', commits: ['a']);
      expect(comparison.installedIsAtLeastAsNew, isFalse);
    });

    test('an unresolved comparison does not silence the update', () {
      // A force-pushed branch leaves an installed SHA that can never be
      // compared again. Treating that as up to date would stop updates for
      // that install permanently, and silently — worse than the bug being
      // fixed here.
      const comparison = CommitComparison.unresolved();
      expect(comparison.status, isEmpty);
      expect(comparison.installedIsAtLeastAsNew, isFalse);
    });
  });

  group('UpdateCheckService on a pre-release channel', () {
    // The stable channel takes the releases path instead, which already
    // compared versions rather than identity.
    if (isStableChannel) return;

    final installed = 'a' * 40;
    final head = 'b' * 40;

    /// A Dio whose compare endpoint answers with [status].
    Dio dioAnswering({required String status, List<String> subjects = const []}) {
      final dio = Dio(BaseOptions(validateStatus: (_) => true));
      dio.httpClientAdapter = _StubAdapter({
        'runs': {
          'workflow_runs': [
            {
              'head_sha': head,
              'run_number': 412,
              'created_at': '2026-09-01T10:00:00Z',
              'html_url': 'https://github.com/hydall/Glaze/actions/runs/1',
            },
          ],
        },
        'compare': {
          'status': status,
          'commits': [
            for (final subject in subjects)
              {
                'parents': [
                  {'sha': 'x'},
                ],
                'commit': {'message': subject},
              },
          ],
        },
      });
      return dio;
    }

    test('#132 — a run older than the installed build is not offered', () async {
      final result = await UpdateCheckService(
        dio: dioAnswering(status: 'behind'),
        installedCommit: installed,
      ).check();
      expect(result.status, UpdateStatus.upToDate);
      expect(result.info, isNull);
    });

    test('a run ahead of the installed build is offered, with its notes', () async {
      final result = await UpdateCheckService(
        dio: dioAnswering(status: 'ahead', subjects: ['first', 'second']),
        installedCommit: installed,
      ).check();
      expect(result.status, UpdateStatus.available);
      expect(result.info!.dismissId, head);
      expect(result.info!.label, '#412');
      // Newest first: the endpoint answers oldest-first.
      expect(result.info!.notes, ['second', 'first']);
    });

    test('an identical run is up to date, not an update', () async {
      final result = await UpdateCheckService(
        dio: dioAnswering(status: 'identical'),
        installedCommit: installed,
      ).check();
      expect(result.status, UpdateStatus.upToDate);
    });

    test('the same SHA never reaches the comparison at all', () async {
      final result = await UpdateCheckService(
        dio: dioAnswering(status: 'ahead'),
        installedCommit: head,
      ).check();
      expect(result.status, UpdateStatus.upToDate);
    });

    test('a build with no embedded SHA cannot tell', () async {
      final result = await UpdateCheckService(
        dio: dioAnswering(status: 'ahead'),
        installedCommit: '',
      ).check();
      expect(result.status, UpdateStatus.unknown);
    });
  });
}

/// Answers the two endpoints the pre-release check uses, by path fragment.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.bodies);

  final Map<String, Object> bodies;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = bodies.keys.firstWhere(
      (fragment) => options.path.contains(fragment),
      orElse: () => '',
    );
    if (key.isEmpty) {
      return ResponseBody.fromString('{}', 404, headers: _jsonHeaders);
    }
    return ResponseBody.fromString(
      jsonEncode(bodies[key]),
      200,
      headers: _jsonHeaders,
    );
  }

  static const _jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };
}
