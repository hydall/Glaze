import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/diagnostics/crash_detector.dart';
import 'package:glaze_flutter/core/diagnostics/diagnostics_store.dart';
import 'package:glaze_flutter/core/diagnostics/log_redactor.dart';
import 'package:glaze_flutter/core/diagnostics/native_diagnostics.dart';
import 'package:glaze_flutter/core/diagnostics/session_tracker.dart';
import 'package:path/path.dart' as p;

AndroidExitInfo _exit(String reason) => AndroidExitInfo(
  reason: reason,
  description: null,
  timestamp: DateTime(2026, 10, 6, 12),
  importance: 100,
  status: 0,
  pssKb: 0,
  rssKb: 0,
  trace: null,
);

SessionRecord _session(SessionState state) => SessionRecord(
  logFile: 'sessions/2026-10-06_11-00-00.log',
  startedAt: DateTime(2026, 10, 6, 11),
  state: state,
);

void main() {
  group('LogRedactor', () {
    test('masks bearer tokens and provider keys', () {
      final out = LogRedactor.redact(
        'Authorization: Bearer sk-proj-abcdefghijklmnop1234 '
        'and key sk-ant-api03-ZZZZZZZZZZZZZZ',
      );
      expect(out, isNot(contains('abcdefghijklmnop1234')));
      expect(out, isNot(contains('ZZZZZZZZZZZZZZ')));
      expect(out, contains('Bearer sk-p***'));
    });

    test('masks key=value and JSON-style secrets', () {
      final out = LogRedactor.redact(
        'GET /v1/models?key=AIzaSyA1234567890abcdefghij "api_key": "hunter22secret"',
      );
      expect(out, isNot(contains('AIzaSyA1234567890abcdefghij')));
      expect(out, isNot(contains('hunter22secret')));
    });

    test('leaves ordinary lines alone', () {
      const line = '[tokenizer] count failed: RangeError (index): 3';
      expect(LogRedactor.redact(line), line);
    });
  });

  group('CrashDetector.classify', () {
    test('a run that ended in the background is not a crash', () {
      expect(
        CrashDetector.classify(
          previous: _session(SessionState.background),
          exit: _exit('SIGNALED'),
          hasJavaCrash: false,
        ),
        isNull,
      );
    });

    test('a run that ended on screen is an unclean exit', () {
      expect(
        CrashDetector.classify(
          previous: _session(SessionState.foreground),
          exit: null,
          hasJavaCrash: false,
        ),
        'UNCLEAN_EXIT',
      );
    });

    test('Android crash reasons win over the marker', () {
      expect(
        CrashDetector.classify(
          previous: _session(SessionState.background),
          exit: _exit('CRASH_NATIVE'),
          hasJavaCrash: false,
        ),
        'CRASH_NATIVE',
      );
    });

    test('an update or force stop while on screen is not a crash', () {
      for (final reason in ['PACKAGE_UPDATED', 'USER_REQUESTED', 'EXIT_SELF']) {
        expect(
          CrashDetector.classify(
            previous: _session(SessionState.foreground),
            exit: _exit(reason),
            hasJavaCrash: false,
          ),
          isNull,
          reason: reason,
        );
      }
    });

    test('an OOM kill on screen is reported as memory', () {
      expect(
        CrashDetector.classify(
          previous: _session(SessionState.foreground),
          exit: _exit('LOW_MEMORY'),
          hasJavaCrash: false,
        ),
        'LOW_MEMORY',
      );
    });

    test('a recorded JVM exception is always a crash', () {
      expect(
        CrashDetector.classify(previous: null, exit: null, hasJavaCrash: true),
        'CRASH',
      );
    });
  });

  test('report carries the kind, environment and log tail', () async {
    final report = await CrashDetector.buildReport(
      kind: 'ANR',
      previous: _session(SessionState.foreground),
      exit: _exit('ANR'),
      javaCrash: null,
      environment: 'Glaze 0.8.0 · nightly · release',
      previousLogTail: '12:00:00.000 I last line',
      now: DateTime(2026, 10, 6, 12, 1),
    );
    expect(report, contains('Kind:             ANR'));
    expect(report, contains('Glaze 0.8.0 · nightly · release'));
    expect(report, contains('--- Android exit info ---'));
    expect(report, endsWith('12:00:00.000 I last line\n'));
  });

  group('files', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('glaze_logs_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('session marker hands the previous run to the next one', () {
      final first = _session(SessionState.foreground);
      final (tracker, none) = SessionTracker.begin(
        logsRoot: dir.path,
        current: first,
      );
      expect(none, isNull);
      tracker.update(SessionState.background);

      final (_, previous) = SessionTracker.begin(
        logsRoot: dir.path,
        current: _session(SessionState.foreground),
      );
      expect(previous?.state, SessionState.background);
      expect(previous?.logFile, first.logFile);
    });

    test('a torn marker is ignored', () {
      File(p.join(dir.path, SessionTracker.markerName)).writeAsStringSync('{');
      final (_, previous) = SessionTracker.begin(
        logsRoot: dir.path,
        current: _session(SessionState.foreground),
      );
      expect(previous, isNull);
    });

    test('tail returns the last lines only', () async {
      final file = File(p.join(dir.path, 'a.log'))
        ..writeAsStringSync(
          [for (var i = 0; i < 1000; i++) 'line $i'].join('\n'),
        );
      final tail = await DiagnosticsStore.tail(file.path, maxLines: 3);
      expect(tail, 'line 997\nline 998\nline 999');
    });

    test('crash kind is read from the report header', () async {
      final file = File(p.join(dir.path, 'c.txt'))
        ..writeAsStringSync(
          'Glaze crash report\n===\nKind:             CRASH_NATIVE\n',
        );
      expect(await DiagnosticsStore.crashKind(file.path), 'CRASH_NATIVE');
    });
  });

  test('file stamps round-trip', () {
    final t = DateTime(2026, 10, 6, 9, 5, 7);
    expect(DiagnosticsStore.parseStamp(DiagnosticsStore.stamp(t)), t);
    expect(DiagnosticsStore.parseStamp('${DiagnosticsStore.stamp(t)}_2'), t);
    expect(DiagnosticsStore.parseStamp('random.log'), isNull);
  });
}
