import 'dart:io';

import 'package:path/path.dart' as p;

import 'diagnostics_store.dart';
import 'native_diagnostics.dart';
import 'session_tracker.dart';

/// A crash of the previous run, found at this launch and written down.
class DetectedCrash {
  final String reportPath;

  /// Short machine label, e.g. `CRASH_NATIVE`, `UNCLEAN_EXIT`.
  final String kind;

  const DetectedCrash({required this.reportPath, required this.kind});
}

/// Decides whether the previous run crashed and, if so, writes a report.
///
/// No single signal is enough. The session marker catches every way an
/// on-screen app can die — a native fault in a WebView, an OOM kill, a frozen
/// UI the user gave up on — but cannot tell them apart. Android's exit record
/// names the cause, and also clears runs that only *look* unclean (the app was
/// updated or force-stopped while visible). iOS and desktop have the marker
/// alone.
abstract final class CrashDetector {
  /// How far an Android exit record may predate the previous run's start and
  /// still be counted as its end (clock skew between the two stamps).
  static const _exitSlack = Duration(seconds: 5);

  static Future<DetectedCrash?> inspect({
    required SessionRecord? previous,
    required String logsRoot,
    required String environment,
    DateTime? now,
    Future<AndroidExitInfo?> Function() lastExit = NativeDiagnostics.lastExit,
    Future<String?> Function() takeJavaCrash = NativeDiagnostics.takeJavaCrash,
  }) async {
    final javaCrash = await takeJavaCrash();
    var exit = await lastExit();
    if (exit != null &&
        (previous == null ||
            exit.timestamp.isBefore(previous.startedAt.subtract(_exitSlack)))) {
      exit = null; // Belongs to an older run already accounted for.
    }

    final kind = classify(
      previous: previous,
      exit: exit,
      hasJavaCrash: javaCrash != null,
    );
    if (kind == null) return null;

    final previousLog = previous == null
        ? null
        : p.join(logsRoot, previous.logFile);
    final report = await buildReport(
      kind: kind,
      previous: previous,
      exit: exit,
      javaCrash: javaCrash,
      environment: environment,
      previousLogTail: previousLog == null
          ? ''
          : await DiagnosticsStore.tail(previousLog),
      now: now ?? DateTime.now(),
    );
    final dir = await DiagnosticsStore.crashesDir();
    final path = p.join(
      dir.path,
      '${DiagnosticsStore.stamp(now ?? DateTime.now())}.txt',
    );
    await File(path).writeAsString(report);
    return DetectedCrash(reportPath: path, kind: kind);
  }

  /// The crash kind, or null when the previous run ended normally.
  static String? classify({
    required SessionRecord? previous,
    required AndroidExitInfo? exit,
    required bool hasJavaCrash,
  }) {
    if (hasJavaCrash) return 'CRASH';
    if (exit != null) {
      if (exit.isCrash) return exit.reason;
      if (exit.isDeliberate) return null;
    }
    if (previous?.state == SessionState.foreground) {
      return exit != null && exit.reason == 'LOW_MEMORY'
          ? 'LOW_MEMORY'
          : 'UNCLEAN_EXIT';
    }
    return null;
  }

  static Future<String> buildReport({
    required String kind,
    required SessionRecord? previous,
    required AndroidExitInfo? exit,
    required String? javaCrash,
    required String environment,
    required String previousLogTail,
    required DateTime now,
  }) async {
    final b = StringBuffer()
      ..writeln('Glaze crash report')
      ..writeln('==================')
      ..writeln('Kind:             $kind')
      ..writeln('Detected at:      ${now.toIso8601String()}');
    if (previous != null) {
      b
        ..writeln('Session started:  ${previous.startedAt.toIso8601String()}')
        ..writeln('Last known state: ${previous.state.name}')
        ..writeln('Session log:      ${previous.logFile}');
    }
    b
      ..writeln()
      ..writeln(environment.trimRight());
    if (exit != null) {
      b
        ..writeln()
        ..writeln('--- Android exit info ---')
        ..writeln('Reason:      ${exit.reason}')
        ..writeln('Description: ${exit.description ?? '-'}')
        ..writeln('Time:        ${exit.timestamp.toIso8601String()}')
        ..writeln('Importance:  ${exit.importance}')
        ..writeln('Status:      ${exit.status}')
        ..writeln('Memory:      PSS ${exit.pssKb} KB, RSS ${exit.rssKb} KB');
    }
    if (javaCrash != null) {
      b
        ..writeln()
        ..writeln('--- Uncaught JVM exception ---')
        ..writeln(javaCrash.trimRight());
    }
    final trace = exit?.trace;
    if (trace != null && trace.isNotEmpty) {
      b
        ..writeln()
        ..writeln('--- ANR traces ---')
        ..writeln(trace.trimRight());
    }
    b
      ..writeln()
      ..writeln('--- End of the session log ---')
      ..writeln(previousLogTail.isEmpty ? '(empty)' : previousLogTail);
    return b.toString();
  }
}
