import 'package:flutter/widgets.dart';

/// Compile-time diagnostic switches for on-device performance profiling.
///
/// Every switch is OFF by default and only activates through a
/// `--dart-define` flag, so shipping builds carry none of this (the dead
/// branches are tree-shaken). Example profiling run:
///
/// ```
/// flutter run --profile --dart-define=PERF_LOG_FRAMES=true
/// flutter run --profile --dart-define=NO_GLASS_BLUR=true
/// flutter run --profile --dart-define=PERF_LOG_CHAT_WEBVIEW=true
/// ```
abstract final class PerfDebug {
  /// Print every frame that misses the 60fps budget, split by thread
  /// (build = UI thread / widget rebuilds, raster = GPU thread / blur & co).
  static const bool logSlowFrames = bool.fromEnvironment('PERF_LOG_FRAMES');

  /// Disable the BackdropFilter blur of every GlassSurface.
  static const bool noGlassBlur = bool.fromEnvironment('NO_GLASS_BLUR');

  /// Disable the TopEdgeBlur header blur (sheets, drawer panels).
  static const bool noEdgeBlur = bool.fromEnvironment('NO_EDGE_BLUR');

  /// Disable the film-grain NoiseOverlay on glass surfaces and backgrounds.
  static const bool noNoise = bool.fromEnvironment('NO_NOISE');

  /// Collect process-local Chat WebView lifecycle totals. This does not write
  /// to storage or send data anywhere. With this define off, each recorder is
  /// a single no-op branch.
  static const bool logChatWebView = bool.fromEnvironment(
    'PERF_LOG_CHAT_WEBVIEW',
  );

  static int _chatScreenBuilds = 0;
  static int _chatWebViewWidgetInits = 0;
  static int _chatWebViewWidgetDisposes = 0;
  static int _chatWebViewInitAttempts = 0;
  static int _chatWebViewInitCompletions = 0;
  static int _chatWebViewBridgeReadies = 0;
  static int _chatWebViewJsBridgeReadies = 0;
  static int _chatWebViewSyncUpdates = 0;
  static int _chatWebViewMessageSyncs = 0;
  static int _chatWebViewSessionSwitches = 0;
  static int _chatWebViewSurfaceCreated = 0;
  static int _chatWebViewLoadStops = 0;

  static void chatScreenBuilt() {
    if (!logChatWebView) return;
    _chatScreenBuilds++;
  }

  static void chatWebViewWidgetInitialized() {
    if (!logChatWebView) return;
    _chatWebViewWidgetInits++;
  }

  /// Records Dart widget-state disposal only; it does not assert native WebView
  /// disposal, because the platform view can be kept alive independently.
  static void chatWebViewWidgetDisposed() {
    if (!logChatWebView) return;
    _chatWebViewWidgetDisposes++;
  }

  static void chatWebViewInitAttempted() {
    if (!logChatWebView) return;
    _chatWebViewInitAttempts++;
  }

  static void chatWebViewInitCompleted() {
    if (!logChatWebView) return;
    _chatWebViewInitCompletions++;
  }

  static void chatWebViewBridgeReady() {
    if (!logChatWebView) return;
    _chatWebViewBridgeReadies++;
  }

  static void chatWebViewJsBridgeReady() {
    if (!logChatWebView) return;
    _chatWebViewJsBridgeReadies++;
  }

  static void chatWebViewSyncResult({
    required bool runMessageSync,
    required bool sessionSwitched,
  }) {
    if (!logChatWebView) return;
    _chatWebViewSyncUpdates++;
    if (runMessageSync) _chatWebViewMessageSyncs++;
    if (sessionSwitched) _chatWebViewSessionSwitches++;
  }

  static void chatWebViewSurfaceCreated() {
    if (!logChatWebView) return;
    _chatWebViewSurfaceCreated++;
  }

  static void chatWebViewLoadStopped() {
    if (!logChatWebView) return;
    _chatWebViewLoadStops++;
  }

  /// Returns concise process-local totals for an enabled profiling run.
  static PerfDebugSnapshot chatWebViewSnapshot() => PerfDebugSnapshot(
    chatScreenBuilds: _chatScreenBuilds,
    widgetInits: _chatWebViewWidgetInits,
    widgetDisposes: _chatWebViewWidgetDisposes,
    initAttempts: _chatWebViewInitAttempts,
    initCompletions: _chatWebViewInitCompletions,
    bridgeReadies: _chatWebViewBridgeReadies,
    jsBridgeReadies: _chatWebViewJsBridgeReadies,
    syncUpdates: _chatWebViewSyncUpdates,
    messageSyncs: _chatWebViewMessageSyncs,
    sessionSwitches: _chatWebViewSessionSwitches,
    surfaceCreated: _chatWebViewSurfaceCreated,
    loadStops: _chatWebViewLoadStops,
  );

  /// Clears Chat WebView profiling totals for the current process.
  static void resetChatWebViewSnapshot() {
    if (!logChatWebView) return;
    _chatScreenBuilds = 0;
    _chatWebViewWidgetInits = 0;
    _chatWebViewWidgetDisposes = 0;
    _chatWebViewInitAttempts = 0;
    _chatWebViewInitCompletions = 0;
    _chatWebViewBridgeReadies = 0;
    _chatWebViewJsBridgeReadies = 0;
    _chatWebViewSyncUpdates = 0;
    _chatWebViewMessageSyncs = 0;
    _chatWebViewSessionSwitches = 0;
    _chatWebViewSurfaceCreated = 0;
    _chatWebViewLoadStops = 0;
  }

  /// Installs the slow-frame logger; no-op unless [logSlowFrames] is set.
  static void installFrameLoggerIfEnabled() {
    if (!logSlowFrames) return;
    WidgetsBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        final buildMs = t.buildDuration.inMicroseconds / 1000.0;
        final rasterMs = t.rasterDuration.inMicroseconds / 1000.0;
        if (buildMs > 17 || rasterMs > 17) {
          // ignore: avoid_print
          print(
            '[frame] build=${buildMs.toStringAsFixed(1)}ms '
            'raster=${rasterMs.toStringAsFixed(1)}ms '
            'total=${(t.totalSpan.inMicroseconds / 1000.0).toStringAsFixed(1)}ms',
          );
        }
      }
    });
  }
}

/// Immutable aggregate returned by [PerfDebug.chatWebViewSnapshot].
class PerfDebugSnapshot {
  const PerfDebugSnapshot({
    required this.chatScreenBuilds,
    required this.widgetInits,
    required this.widgetDisposes,
    required this.initAttempts,
    required this.initCompletions,
    required this.bridgeReadies,
    required this.jsBridgeReadies,
    required this.syncUpdates,
    required this.messageSyncs,
    required this.sessionSwitches,
    required this.surfaceCreated,
    required this.loadStops,
  });

  final int chatScreenBuilds;
  final int widgetInits;
  final int widgetDisposes;
  final int initAttempts;
  final int initCompletions;
  final int bridgeReadies;
  final int jsBridgeReadies;
  final int syncUpdates;
  final int messageSyncs;
  final int sessionSwitches;
  final int surfaceCreated;
  final int loadStops;

  @override
  String toString() =>
      'ChatWebViewPerf('
      'screen=$chatScreenBuilds, widget=$widgetInits/$widgetDisposes, '
      'init=$initAttempts/$initCompletions, '
      'bridge=$bridgeReadies/$jsBridgeReadies, '
      'sync=$syncUpdates/$messageSyncs/$sessionSwitches, '
      'surface=$surfaceCreated/$loadStops)';
}
