import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../chat/bridge/chat_webview_environment.dart';
import 'js_bridge_service.dart';

/// Thrown when the headless engine cannot service a script run. Callers
/// should fall back to the visual chat WebView bridge.
class HeadlessUnavailableError extends Error {
  HeadlessUnavailableError(this.reason);
  final String reason;

  @override
  String toString() => 'HeadlessUnavailableError: $reason';
}

/// Lifecycle of the singleton headless engine.
enum JsEngineStatus { uninitialized, initializing, ready, failed, disposed }

/// Internal controller abstraction. The real implementation wraps
/// [InAppWebViewController] from `flutter_inappwebview`; tests substitute
/// a fake to verify dispatch without spinning up a WebView.
abstract class JsEngineController {
  Future<void> addJavaScriptHandler({
    required String handlerName,
    required Future<dynamic> Function(List<dynamic> args) callback,
  });

  Future<void> evaluateJavascript({required String source});

  Future<JsAsyncJsResult?> callAsyncJavaScript({
    required String functionBody,
    required Map<String, dynamic> arguments,
  });

  Future<void> dispose();
}

class JsAsyncJsResult {
  JsAsyncJsResult(this.value);
  final Object? value;
}

sealed class _RaceResult {
  const _RaceResult();
  static _RaceResult js(JsAsyncJsResult? result) => _RaceResultJs(result);
  static _RaceResult cancelled() => _RaceResultCancelled();
}

class _RaceResultJs extends _RaceResult {
  const _RaceResultJs(this.result);
  final JsAsyncJsResult? result;
}

class _RaceResultCancelled extends _RaceResult {
  const _RaceResultCancelled();
}

/// In-process bus that lets the headless controller forward `glazeBridge`
/// calls into the same [JsBridgeService] used by the visual WebView.
///
/// [currentCharIdProvider] (optional) supplies a fallback `characterId`
/// when the JS request has no `context.characterId`. The visual chat
/// WebView always injects its own id, so this fallback is only used by
/// the headless engine when scripts run without an open chat (e.g. timers
/// or `afterAssistant` post-gen).
class JsEngineBridgeHost {
  JsEngineBridgeHost({required this.bridge, this.currentCharIdProvider});

  final JsBridgeService bridge;
  final String? Function()? currentCharIdProvider;

  Future<Map<String, dynamic>> handle(List<dynamic> args) async {
    if (args.isEmpty) {
      return {
        'ok': false,
        'error': {'code': 'invalid_request'},
      };
    }
    final raw = args.first;
    final request = raw is Map<String, dynamic>
        ? raw
        : raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    final method = request['method'] as String? ?? '';
    if (method == 'triggerGeneration') {
      final context = request['context'];
      final hasCharId =
          context is Map &&
          context['characterId'] is String &&
          (context['characterId'] as String).isNotEmpty;
      if (!hasCharId) {
        final fallback = currentCharIdProvider?.call();
        if (fallback != null && fallback.isNotEmpty) {
          final patched = Map<String, dynamic>.from(
            context is Map ? context : const {},
          );
          patched['characterId'] = fallback;
          request['context'] = patched;
        }
      }
    }
    return bridge.dispatch(request);
  }
}

/// Singleton headless JS engine for JS extension background scripts and
/// offline `jsRunner` block execution.
///
/// Lifetime:
///   - Lives for the duration of the running app (per design — see plan).
///   - [init] is idempotent; concurrent callers observe the same future.
///   - [dispose] tears down the WebView; the service can be re-initialized.
class JsEngineService {
  JsEngineService._({HeadlessInAppWebViewFactory? factory})
    : _factory = factory ?? const _DefaultFactory();

  static JsEngineService? _instance;

  /// Process-wide singleton.
  static JsEngineService get instance => _instance ??= JsEngineService._();

  /// Test seam: replace the singleton with a custom service. Pass `null`
  /// to reset (next [instance] call re-creates the default).
  static void debugSetInstance(JsEngineService? service) {
    _instance?.dispose();
    _instance = service;
  }

  final HeadlessInAppWebViewFactory _factory;

  HeadlessInAppWebView? _webView;
  JsEngineController? _controller;
  JsEngineStatus _status = JsEngineStatus.uninitialized;
  String? _lastError;
  Completer<void>? _initCompleter;
  final Map<String, JsEngineBridgeHost> _runHosts = {};
  final Map<String, Completer<void>> _activeRuns = {};
  int _nextRunId = 0;

  JsEngineStatus get status => _status;
  String? get lastError => _lastError;
  bool get isReady => _status == JsEngineStatus.ready && _controller != null;

  /// Initializes the headless engine. Safe to call from multiple call sites;
  /// only one WebView is created.
  Future<void> init() async {
    if (_status == JsEngineStatus.disposed) {
      throw StateError('JsEngineService was disposed');
    }
    final pending = _initCompleter;
    if (pending != null) return pending.future;
    if (_status == JsEngineStatus.ready) return;

    _status = JsEngineStatus.initializing;
    _lastError = null;
    final completer = Completer<void>();
    _initCompleter = completer;

    try {
      final sdkSource = await rootBundle.loadString(
        'assets/chat_webview/glaze_sdk.js',
      );
      final controllerCompleter = Completer<JsEngineController>();
      final webView = _factory.create(
        initialFile: 'assets/chat_webview/headless.html',
        onWebViewCreated: (controller) {
          if (controllerCompleter.isCompleted) return;
          controllerCompleter.complete(_wrap(controller));
        },
      );
      _webView = webView;
      unawaited(webView.run());
      final controller = await controllerCompleter.future;
      _controller = controller;
      await controller.evaluateJavascript(
        source: 'window.__glazeSdkSource = ${_escapeJsonStr(sdkSource)};',
      );
      await controller.addJavaScriptHandler(
        handlerName: 'glazeBridge',
        callback: _handleBridgeCall,
      );
      _status = JsEngineStatus.ready;
      completer.complete();
    } catch (e, st) {
      _status = JsEngineStatus.failed;
      _lastError = e.toString();
      debugPrint('[JsEngine] init failed: $e\n$st');
      completer.complete();
    } finally {
      _initCompleter = null;
    }
  }

  /// Test seam: initializes the engine with a pre-built [controller] and
  /// bypassing the [HeadlessInAppWebView] creation and the asset bundle load.
  /// Production code must not call this directly.
  @visibleForTesting
  Future<void> debugInitWithController({
    required JsEngineController controller,
  }) async {
    if (_status == JsEngineStatus.disposed) {
      throw StateError('JsEngineService was disposed');
    }
    final pending = _initCompleter;
    if (pending != null) return pending.future;
    if (_status == JsEngineStatus.ready) return;

    _status = JsEngineStatus.initializing;
    _lastError = null;
    final completer = Completer<void>();
    _initCompleter = completer;
    try {
      _controller = controller;
      await controller.evaluateJavascript(
        source: 'window.__glazeSdkSource = "";',
      );
      await controller.addJavaScriptHandler(
        handlerName: 'glazeBridge',
        callback: _handleBridgeCall,
      );
      _status = JsEngineStatus.ready;
      completer.complete();
    } catch (e) {
      _status = JsEngineStatus.failed;
      _lastError = e.toString();
      completer.complete();
    } finally {
      _initCompleter = null;
    }
  }

  Future<Map<String, dynamic>> _handleBridgeCall(List<dynamic> args) {
    final runId = args.length > 1 && args[1] is String
        ? args[1] as String
        : null;
    final host = runId == null ? null : _runHosts[runId];
    if (host == null) {
      return Future.value({
        'ok': false,
        'error': {
          'code': 'bridge_unavailable',
          'message': 'Headless bridge authority is not active',
        },
      });
    }
    return host.handle(args);
  }

  /// Runs [script] inside the headless sandbox and returns its string result.
  /// Throws [HeadlessUnavailableError] if the engine is not ready. Honors
  /// [timeout] and cooperatively cancels via [cancelToken].
  Future<String> runScript({
    required String script,
    required Map<String, dynamic> context,
    required JsEngineBridgeHost? host,
    Duration timeout = const Duration(seconds: 30),
    CancelToken? cancelToken,
  }) async {
    final controller = _controller;
    if (!isReady || controller == null) {
      throw HeadlessUnavailableError(
        _lastError ?? 'Headless engine is not ready (status=$_status)',
      );
    }
    if (cancelToken?.isCancelled == true) {
      throw Exception('Cancelled before JS execution');
    }

    final runId = 'run_${_nextRunId++}';
    final runCompleter = Completer<void>();
    if (host != null) _runHosts[runId] = host;
    _activeRuns[runId] = runCompleter;
    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel.whenComplete(() {
          if (!runCompleter.isCompleted) {
            runCompleter.completeError(
              Exception('Cancelled during JS execution'),
            );
          }
        }),
      );
    }
    try {
      final jsFuture = controller.callAsyncJavaScript(
        functionBody:
            'return window.headlessBridge.runSandboxedScript(script, contextJson, runId);',
        arguments: {
          'script': script,
          'contextJson': jsonEncode(context),
          'runId': runId,
        },
      );
      // Race the JS call against the cancellation sentinel. Whichever
      // completes first wins. The losing future is allowed to stay
      // pending; the timeout above will eventually unblock it.
      final winner =
          await Future.any<dynamic>([
            jsFuture.then((r) => _RaceResult.js(r)),
            runCompleter.future.then(
              (_) => _RaceResult.cancelled(),
              onError: (Object error, StackTrace stackTrace) =>
                  Error.throwWithStackTrace(error, stackTrace),
            ),
          ]).timeout(
            timeout,
            onTimeout: () {
              throw TimeoutException('Headless JS run timed out', timeout);
            },
          );
      if (winner is _RaceResultJs) {
        if (!runCompleter.isCompleted) runCompleter.complete();
        final value = winner.result?.value;
        if (value == null) return '';
        if (value is String) return value;
        return value.toString();
      }
      // Cancellation path: jsFuture is abandoned.
      throw Exception('Cancelled during JS execution');
    } finally {
      _runHosts.remove(runId);
      _activeRuns.remove(runId);
    }
  }

  /// Cancels all in-flight runs started by this service.
  void cancel() {
    final runs = _activeRuns.values.toList(growable: false);
    _activeRuns.clear();
    _runHosts.clear();
    for (final run in runs) {
      if (!run.isCompleted) {
        run.completeError(Exception('Headless engine cancelled by user'));
      }
    }
  }

  Future<void> dispose() async {
    cancel();
    final controller = _controller;
    final webView = _webView;
    _controller = null;
    _webView = null;
    _status = JsEngineStatus.disposed;
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (e) {
        debugPrint('[JsEngine] controller dispose failed: $e');
      }
    }
    if (webView != null) {
      try {
        await webView.dispose();
      } catch (e) {
        debugPrint('[JsEngine] webView dispose failed: $e');
      }
    }
  }

  JsEngineController _wrap(InAppWebViewController controller) {
    return _InAppWebViewEngineController(controller);
  }

  static String _escapeJsonStr(String s) {
    final encoded = jsonEncode(s);
    return '"${encoded.substring(1, encoded.length - 1)}"';
  }
}

abstract class HeadlessInAppWebViewFactory {
  HeadlessInAppWebView create({
    required String initialFile,
    required void Function(InAppWebViewController controller) onWebViewCreated,
  });
}

class _DefaultFactory implements HeadlessInAppWebViewFactory {
  const _DefaultFactory();

  @override
  HeadlessInAppWebView create({
    required String initialFile,
    required void Function(InAppWebViewController controller) onWebViewCreated,
  }) {
    return HeadlessInAppWebView(
      webViewEnvironment: chatWebViewEnvironment,
      initialFile: initialFile,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        transparentBackground: true,
        isInspectable: false,
        useHybridComposition: true,
        cacheEnabled: true,
        // Strict sandbox: headless engine never needs broad file access.
        allowFileAccess: true,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
      ),
      onWebViewCreated: onWebViewCreated,
    );
  }
}

class _InAppWebViewEngineController implements JsEngineController {
  _InAppWebViewEngineController(this._controller);

  final InAppWebViewController _controller;

  @override
  Future<void> addJavaScriptHandler({
    required String handlerName,
    required Future<dynamic> Function(List<dynamic> args) callback,
  }) async {
    _controller.addJavaScriptHandler(
      handlerName: handlerName,
      callback: callback,
    );
  }

  @override
  Future<JsAsyncJsResult?> callAsyncJavaScript({
    required String functionBody,
    required Map<String, dynamic> arguments,
  }) async {
    final result = await _controller.callAsyncJavaScript(
      functionBody: functionBody,
      arguments: arguments,
    );
    if (result == null) return null;
    return JsAsyncJsResult(result.value);
  }

  @override
  Future<void> evaluateJavascript({required String source}) async {
    await _controller.evaluateJavascript(source: source);
  }

  @override
  Future<void> dispose() async {
    // flutter_inappwebview's InAppWebViewController doesn't expose a
    // dispose(); the parent HeadlessInAppWebView does, which the service
    // calls after dropping the controller reference.
  }
}
