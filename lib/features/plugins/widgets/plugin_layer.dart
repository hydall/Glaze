import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../chat/bridge/chat_webview_environment.dart';
import '../../chat/bridge/chat_webview_settings.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
import 'plugin_holes.dart';

/// Whether this platform can lay the plugin layer over the chat: a second,
/// transparent WebView above the app's own controls (header, message box,
/// buttons) that holds the chat panels of plugins, so they draw over those
/// controls whole instead of having the controls cut away under them.
///
/// It needs the app to decide where each touch goes, so that touches outside
/// what the panels draw reach the controls and the chat page under the
/// layer: Android (hybrid composition hands every touch to the app first),
/// and Windows and Linux, where the WebView is a texture. On iOS and macOS a
/// touch goes to the topmost native view and cannot be passed down to the
/// chat page, so the panels stay in the chat page there ([PluginHolesCutter]).
///
/// [platform] is for tests.
bool pluginLayerSupported([TargetPlatform? platform]) {
  if (kIsWeb) return false;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };
}

/// Whether [plugins] put chat panels in the plugin layer: only when the
/// platform has it and one of them has a chat panel.
bool pluginsUseLayer(
  Iterable<InstalledPlugin> plugins, [
  TargetPlatform? platform,
]) =>
    pluginLayerSupported(platform) &&
    plugins.any(
      (p) => p.manifest.panels.any(
        (x) => x.placement == PluginPanelPlacement.chat,
      ),
    );

/// The plugin layer's page, as the plugin runtime talks to it: the same host
/// script as in the chat page, set up with the chat panels only.
class PluginLayerController {
  PluginLayerController(this._controller);

  final InAppWebViewController _controller;

  /// `glaze.*` calls of the panels, stamped with the plugin's id.
  Future<Map<String, dynamic>> Function(Map<String, dynamic> request)?
  onPluginRequest;

  /// Where the panels draw, in page pixels (`[[x, y, w, h], …]`).
  void Function(List<Object?> rects)? onPluginHoles;

  /// What a panel emitted to the plugin's other frames.
  void Function(Map<String, dynamic> emit)? onPluginEmit;

  void Function(Map<String, dynamic> report)? onPluginNetwork;
  void Function(Map<String, dynamic> report)? onPluginHttpRequest;

  /// Awaits a JS function body with [arguments] bound as parameters. Null
  /// when the page is gone or the body threw.
  Future<Object?> callAsyncJs(
    String functionBody, {
    Map<String, dynamic> arguments = const {},
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      final result = await _controller
          .callAsyncJavaScript(functionBody: functionBody, arguments: arguments)
          .timeout(timeout);
      if (result == null || result.error != null) return null;
      return result.value;
    } on MissingPluginException {
      return null;
    }
  }

  void setupHandlers() {
    Map<String, dynamic>? first(JavaScriptHandlerFunctionData data) {
      final raw = data.args.isNotEmpty ? data.args.first : null;
      return raw is Map ? Map<String, dynamic>.from(raw) : null;
    }

    _controller.addJavaScriptHandler(
      handlerName: 'pluginBridge',
      callback: (JavaScriptHandlerFunctionData data) async {
        final request = first(data);
        final handler = onPluginRequest;
        if (handler == null || request == null) {
          return const {
            'ok': false,
            'error': {
              'code': 'runtime_unavailable',
              'message': 'Plugins are not running in this chat',
            },
          };
        }
        return handler(request);
      },
    );
    _controller.addJavaScriptHandler(
      handlerName: 'pluginHoles',
      callback: (JavaScriptHandlerFunctionData data) {
        final raw = data.args.isNotEmpty ? data.args.first : null;
        onPluginHoles?.call(raw is List ? raw : const []);
        return null;
      },
    );
    _controller.addJavaScriptHandler(
      handlerName: 'pluginEmit',
      callback: (JavaScriptHandlerFunctionData data) {
        final emit = first(data);
        if (emit != null) onPluginEmit?.call(emit);
        return null;
      },
    );
    _controller.addJavaScriptHandler(
      handlerName: 'pluginNetwork',
      callback: (JavaScriptHandlerFunctionData data) {
        final report = first(data);
        if (report != null) onPluginNetwork?.call(report);
        return null;
      },
    );
    _controller.addJavaScriptHandler(
      handlerName: 'pluginHttp',
      callback: (JavaScriptHandlerFunctionData data) {
        final report = first(data);
        if (report != null) onPluginHttpRequest?.call(report);
        return null;
      },
    );
  }
}

/// The plugin layer of a chat, by character id, once its page has loaded.
final pluginLayerRegistryProvider =
    StateProvider.family<PluginLayerController?, String>((ref, charId) => null);

/// The plugin layer: laid over the whole chat screen, above the app's own
/// controls. It is transparent and takes touches only where the panels draw
/// ([PluginHolesHitArea]).
class PluginLayer extends ConsumerStatefulWidget {
  const PluginLayer({super.key, required this.charId});

  final String charId;

  @override
  ConsumerState<PluginLayer> createState() => _PluginLayerState();
}

class _PluginLayerState extends ConsumerState<PluginLayer> {
  final _pageKey = GlobalKey();
  late final InAppWebViewSettings _settings = chatWebViewInAppSettings();
  late final PluginHoles _holes;
  late final StateController<PluginLayerController?> _registry;
  PluginLayerController? _layer;

  /// Bumped to build a new WebView after its page process died.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _holes = ref.read(pluginHolesProvider(widget.charId));
    _holes.page = () => _pageKey.currentContext;
    _registry = ref.read(pluginLayerRegistryProvider(widget.charId).notifier);
  }

  @override
  void dispose() {
    _unpublish();
    super.dispose();
  }

  void _unpublish() {
    final layer = _layer;
    _layer = null;
    _holes.clear();
    if (layer == null) return;
    final registry = _registry;
    // Deferred: providers may not be modified while the tree is unmounting.
    Future(() {
      if (identical(registry.state, layer)) registry.state = null;
    });
  }

  void _onPageGone() {
    if (!mounted) return;
    _unpublish();
    setState(() => _generation++);
  }

  @override
  Widget build(BuildContext context) {
    return PluginHolesHitArea(
      holes: _holes,
      child: KeyedSubtree(
        key: _pageKey,
        child: InAppWebView(
          key: ValueKey<int>(_generation),
          webViewEnvironment: chatWebViewEnvironment,
          initialFile: chatWebViewInitialFile(kPluginLayerPage),
          initialUrlRequest: chatWebViewInitialUrlRequest(kPluginLayerPage),
          initialSettings: _settings,
          initialUserScripts: chatWebViewUserScripts(),
          onWebViewCreated: (controller) {
            _layer = PluginLayerController(controller)..setupHandlers();
          },
          onLoadStop: (controller, url) {
            final layer = _layer;
            if (!mounted || layer == null) return;
            _registry.state = layer;
          },
          onRenderProcessGone: (controller, detail) => _onPageGone(),
          onWebContentProcessDidTerminate: (controller) => _onPageGone(),
          shouldOverrideUrlLoading: (controller, request) async =>
              chatWebViewNavigationPolicy(
                request.request.url,
                mainFrame: request.isForMainFrame,
                page: kPluginLayerPage,
              ),
        ),
      ),
    );
  }
}
