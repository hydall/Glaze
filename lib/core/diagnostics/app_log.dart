import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../constants/app_version.dart';
import '../constants/build_channel.dart';
import 'crash_detector.dart';
import 'diagnostics_store.dart';
import 'log_redactor.dart';
import 'native_diagnostics.dart';
import 'session_tracker.dart';

enum LogLevel {
  info('I'),
  warn('W'),
  error('E');

  final String tag;
  const LogLevel(this.tag);
}

/// The app's on-disk log: one file per launch, in every build channel.
///
/// Nothing in the code base has to call it to be logged. [install] routes the
/// existing `debugPrint` calls, framework errors and uncaught async errors into
/// the session file, so a user who hits a problem has something to send. It
/// also starts the crash detection that [takePendingCrash] reports on.
///
/// Writes are batched and flushed every second, and at once for an error or
/// when the app leaves the screen — synchronous writes, so a line that made it
/// out survives the process dying right after.
abstract final class AppLog {
  /// Past this, a session file keeps only errors.
  static const _maxSessionChars = 4 * 1024 * 1024;

  /// Lines held while the file is not open yet (before [start] resolves the
  /// data folder).
  static const _maxEarlyChars = 512 * 1024;

  static bool _installed = false;
  static final StringBuffer _pending = StringBuffer();
  static RandomAccessFile? _file;
  static String? _sessionPath;
  static int _written = 0;
  static bool _capped = false;
  static bool _forwarding = false;
  static Timer? _flushTimer;
  static SessionTracker? _tracker;
  // Held so the listener stays registered for the life of the process.
  // ignore: unused_field
  static AppLifecycleListener? _lifecycle;
  static DetectedCrash? _pendingCrash;
  static final Completer<void> _ready = Completer<void>();

  /// Completes once the session file is open and crash detection has run.
  static Future<void> get ready => _ready.future;

  /// The log file this run writes to.
  static String? get sessionPath => _sessionPath;

  /// The previous run's crash, once. The startup prompt takes it, so it is
  /// offered a single time even if that prompt is dismissed.
  static DetectedCrash? takePendingCrash() {
    final crash = _pendingCrash;
    _pendingCrash = null;
    return crash;
  }

  /// Hooks `debugPrint`, [FlutterError.onError] and
  /// [PlatformDispatcher.onError]. Call right after
  /// `WidgetsFlutterBinding.ensureInitialized()`, then [start].
  static void install() {
    if (_installed) return;
    _installed = true;

    final originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      originalPrint(message, wrapWidth: wrapWidth);
      if (message != null && !_forwarding) _append(LogLevel.info, message);
    };

    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      _logFlutterError(details);
      // The default presenter prints the same error through debugPrint;
      // it is already in the file.
      _forwarding = true;
      try {
        previousFlutterError?.call(details);
      } finally {
        _forwarding = false;
      }
    };

    final dispatcher = PlatformDispatcher.instance;
    final previousPlatformError = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      AppLog.error(error, stack, context: 'Uncaught async error');
      return previousPlatformError?.call(error, stack) ?? false;
    };
  }

  /// Opens this run's file, records how the last run ended, and starts
  /// tracking the lifecycle. Safe to leave unawaited; see [ready].
  static Future<void> start() async {
    try {
      final root = await DiagnosticsStore.rootDir();
      final sessions = await DiagnosticsStore.sessionsDir();
      final startedAt = DateTime.now();
      final path = await _freePath(sessions.path, startedAt);
      _file = await File(path).open(mode: FileMode.writeOnlyAppend);
      _sessionPath = path;

      final environment = await describeEnvironment();
      _writeNow('$environment\n${'-' * 60}\n');
      flush();
      _flushTimer = Timer.periodic(const Duration(seconds: 1), (_) => flush());

      final (tracker, previous) = SessionTracker.begin(
        logsRoot: root,
        current: SessionRecord(
          logFile: p.relative(path, from: root).replaceAll('\\', '/'),
          startedAt: startedAt,
          state: _stateFor(WidgetsBinding.instance.lifecycleState),
        ),
      );
      _tracker = tracker;
      _lifecycle = AppLifecycleListener(
        onStateChange: _onLifecycle,
        onExitRequested: () async {
          _tracker?.update(SessionState.closed);
          flush();
          return AppExitResponse.exit;
        },
      );

      // A debug session ends whenever `flutter run` is stopped, which looks
      // exactly like a crash from here.
      if (!kDebugMode) {
        _pendingCrash = await CrashDetector.inspect(
          previous: previous,
          logsRoot: root,
          environment: environment,
        );
        if (_pendingCrash case final crash?) {
          _append(
            LogLevel.warn,
            'Previous session crashed (${crash.kind}); report: '
            '${p.basename(crash.reportPath)}',
          );
        }
      }
      unawaited(DiagnosticsStore.prune(keep: path));
    } catch (e, st) {
      // Logging must never be the reason the app fails to start.
      debugPrint('AppLog: could not start — $e\n$st');
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  static void info(String message) => _append(LogLevel.info, message);

  static void warn(String message) => _append(LogLevel.warn, message);

  static void error(Object error, StackTrace? stack, {String? context}) {
    final b = StringBuffer();
    if (context != null) b.write('$context: ');
    b.write(error);
    if (stack != null) b.write('\n${stack.toString().trimRight()}');
    _append(LogLevel.error, b.toString());
    flush();
  }

  /// Writes pending lines out. Synchronous on purpose — see the class doc.
  static void flush() {
    final file = _file;
    if (file == null || _pending.isEmpty) return;
    final text = _pending.toString();
    _pending.clear();
    _writeNow(text);
  }

  /// Environment block shared by the session header and crash reports.
  static Future<String> describeEnvironment() async {
    final device = await NativeDiagnostics.deviceDescription();
    final mode = kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug';
    return [
      'Glaze $appVersion · $buildChannel · $mode',
      if (buildCommit.isNotEmpty) 'Commit: $buildCommit',
      if (buildDate.isNotEmpty || buildBranch.isNotEmpty)
        'Build:  $buildDate $buildBranch'.trimRight(),
      'OS:     ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      if (device != null) 'Device: $device',
      'Locale: ${Platform.localeName}',
      'Dart:   ${Platform.version.split(' ').first}',
    ].join('\n');
  }

  static void _logFlutterError(FlutterErrorDetails details) {
    final b = StringBuffer('FlutterError');
    if (details.library != null) b.write(' (${details.library})');
    b.write(': ${details.exceptionAsString()}');
    final context = details.context?.toDescription();
    if (context != null && context.isNotEmpty) b.write('\nContext: $context');
    final stack = details.stack;
    if (stack != null) b.write('\n${stack.toString().trimRight()}');
    _append(details.silent ? LogLevel.warn : LogLevel.error, b.toString());
    if (!details.silent) flush();
  }

  static void _append(LogLevel level, String message) {
    if (_capped && level != LogLevel.error) return;
    if (_file == null && _pending.length > _maxEarlyChars) return;
    final lines = LogRedactor.redact(message).trimRight().split('\n');
    _pending
      ..write(_time(DateTime.now()))
      ..write(' ${level.tag} ')
      ..writeln(lines.first);
    for (final line in lines.skip(1)) {
      _pending
        ..write('    ')
        ..writeln(line);
    }
  }

  static void _writeNow(String text) {
    final file = _file;
    if (file == null) return;
    try {
      file.writeStringSync(text);
      _written += text.length;
      if (!_capped && _written > _maxSessionChars) {
        _capped = true;
        file.writeStringSync(
          '--- log size limit reached; only errors are kept from here ---\n',
        );
      }
    } catch (_) {
      // Disk full or the file vanished. Stop trying rather than throw from
      // every debugPrint in the app.
      _file = null;
      _flushTimer?.cancel();
    }
  }

  static void _onLifecycle(AppLifecycleState state) {
    _tracker?.update(_stateFor(state));
    _append(LogLevel.info, 'Lifecycle: ${state.name}');
    if (state != AppLifecycleState.resumed) flush();
  }

  static SessionState _stateFor(AppLifecycleState? state) => switch (state) {
    null ||
    AppLifecycleState.resumed ||
    AppLifecycleState.inactive => SessionState.foreground,
    AppLifecycleState.hidden ||
    AppLifecycleState.paused => SessionState.background,
    AppLifecycleState.detached => SessionState.closed,
  };

  /// `<stamp>.log`, or `<stamp>_2.log` when a restart lands in the same second.
  static Future<String> _freePath(String dir, DateTime t) async {
    final base = DiagnosticsStore.stamp(t);
    var path = p.join(dir, '$base.log');
    for (var i = 2; await File(path).exists(); i++) {
      path = p.join(dir, '${base}_$i.log');
    }
    return path;
  }

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }
}
