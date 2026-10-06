import 'dart:io';

import 'package:flutter/services.dart';

/// How Android says the previous process of this app ended
/// (`ApplicationExitInfo`, Android 11+).
class AndroidExitInfo {
  final String reason;
  final String? description;
  final DateTime timestamp;
  final int importance;
  final int status;
  final int pssKb;
  final int rssKb;

  /// ANR traces; empty for every other reason.
  final String? trace;

  const AndroidExitInfo({
    required this.reason,
    required this.description,
    required this.timestamp,
    required this.importance,
    required this.status,
    required this.pssKb,
    required this.rssKb,
    required this.trace,
  });

  /// The process died on its own: an exception, a native fault, an ANR.
  bool get isCrash => const {
    'CRASH',
    'CRASH_NATIVE',
    'ANR',
    'INITIALIZATION_FAILURE',
  }.contains(reason);

  /// Ended by the user or the system on purpose — an update, a force stop, a
  /// permission change. Never a crash, whatever state the app was in.
  bool get isDeliberate => const {
    'EXIT_SELF',
    'USER_REQUESTED',
    'USER_STOPPED',
    'PACKAGE_UPDATED',
    'PACKAGE_STATE_CHANGE',
    'PERMISSION_CHANGE',
    'DEPENDENCY_DIED',
  }.contains(reason);

  static AndroidExitInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final reason = raw['reason'];
    final timestamp = raw['timestamp'];
    if (reason is! String || timestamp is! int) return null;
    return AndroidExitInfo(
      reason: reason,
      description: raw['description'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
      importance: (raw['importance'] as int?) ?? 0,
      status: (raw['status'] as int?) ?? 0,
      pssKb: (raw['pss'] as int?) ?? 0,
      rssKb: (raw['rss'] as int?) ?? 0,
      trace: raw['trace'] as String?,
    );
  }
}

/// Platform-side crash evidence the Dart VM cannot see for itself: it is gone
/// by the time anything is worth reporting. Android only; every call is a
/// harmless null elsewhere.
abstract final class NativeDiagnostics {
  static const _channel = MethodChannel('app.glaze.flutter/diagnostics');

  /// The previous process's exit record, or null below Android 11.
  static Future<AndroidExitInfo?> lastExit() async {
    if (!Platform.isAndroid) return null;
    try {
      return AndroidExitInfo.fromMap(
        await _channel.invokeMethod<Object?>('lastExit'),
      );
    } catch (_) {
      return null;
    }
  }

  /// The uncaught Java/Kotlin exception that killed the previous process, as
  /// written by the handler in `MainActivity`. Removed once read.
  static Future<String?> takeJavaCrash() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('takeJavaCrash');
    } catch (_) {
      return null;
    }
  }

  /// Manufacturer, model and Android version — the first thing anyone asks
  /// about a crash, and nothing `dart:io` can tell.
  static Future<String?> deviceDescription() async {
    if (!Platform.isAndroid) return null;
    try {
      final info = await _channel.invokeMapMethod<String, Object?>(
        'deviceInfo',
      );
      if (info == null) return null;
      return '${info['manufacturer']} ${info['model']} · Android '
          '${info['release']} (SDK ${info['sdk']}) · ${info['abis']}';
    } catch (_) {
      return null;
    }
  }
}
