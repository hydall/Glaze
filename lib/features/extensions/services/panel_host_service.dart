import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/bridge/chat_bridge_controller.dart';
import '../../chat/bridge/chat_bridge_registry.dart';

/// Result of an openPanel call.
class PanelOpenResult {
  const PanelOpenResult({required this.panelId, required this.messageId});

  final String panelId;
  final String messageId;
}

class PanelEvent {
  const PanelEvent({
    required this.panelId,
    required this.messageId,
    required this.event,
    required this.payload,
  });

  final String panelId;
  final String messageId;
  final String event;
  final Map<String, dynamic> payload;
}

/// Singleton owner of interactive panels. Tracks which panels are open for
/// which message and forwards resize / event notifications.
///
/// One [PanelHostService] lives at app lifetime. It does not own a WebView
/// itself — instead it talks to whichever chat WebView is currently active
/// via [chatBridgeRegistryProvider]. When a panel is requested but no
/// bridge exists yet, the call returns `null` rather than throwing.
class PanelHostService {
  PanelHostService();

  static final PanelHostService instance = PanelHostService();

  final Map<String, _PanelState> _panels = {};
  int _nextLocalId = 1;

  /// Stream of resize events. Use this in widgets that need to react to
  /// panel height changes (e.g. virtual list cache invalidation).
  final StreamController<PanelResizeEvent> _resizeController =
      StreamController<PanelResizeEvent>.broadcast();

  /// Stream of arbitrary panel events (button clicks, form submits, etc.).
  final StreamController<PanelEvent> _eventController =
      StreamController<PanelEvent>.broadcast();

  Stream<PanelResizeEvent> get resizeStream => _resizeController.stream;
  Stream<PanelEvent> get eventStream => _eventController.stream;

  int get openCount => _panels.length;
  bool get isEmpty => _panels.isEmpty;

  /// Open a new panel under [messageId]. The [html] is passed through to
  /// the WebView and rendered inside a sandboxed iframe. The returned
  /// panelId is generated locally; it is not the same string the WebView
  /// uses internally — see [_PanelState.localId] vs `_PanelState.remoteId`.
  Future<PanelOpenResult?> openPanel({
    required String charId,
    required String messageId,
    required String html,
    Map<String, dynamic> options = const {},
  }) async {
    if (messageId.isEmpty) return null;
    final bridge = _resolveBridge(charId);
    if (bridge == null) {
      debugPrint('[PanelHost] openPanel: no chat bridge for charId=$charId');
      return null;
    }

    final localId = 'p${_nextLocalId++}';
    final remoteId = await bridge.openInteractivePanel(
      messageId: messageId,
      html: html,
      options: options,
    );
    if (remoteId == null || remoteId.isEmpty) {
      debugPrint(
        '[PanelHost] openPanel: WebView returned no panelId (message=$messageId not mounted?)',
      );
      return null;
    }

    final state = _PanelState(
      localId: localId,
      remoteId: remoteId,
      messageId: messageId,
      charId: charId,
      lastHeight: (options['minHeight'] as num?)?.toDouble() ?? 0.0,
    );
    _panels[remoteId] = state;
    _bindBridgeHandlers(bridge, charId);
    return PanelOpenResult(panelId: remoteId, messageId: messageId);
  }

  Future<void> closePanel({
    required String charId,
    required String panelId,
  }) async {
    final state = _panels.remove(panelId);
    if (state == null) return;
    final bridge = _resolveBridge(charId);
    await bridge?.closeInteractivePanel(panelId);
  }

  Future<void> closeAllForChar(String charId) async {
    final toClose = _panels.entries
        .where((e) => e.value.charId == charId)
        .map((e) => e.key)
        .toList();
    final bridge = _resolveBridge(charId);
    for (final id in toClose) {
      _panels.remove(id);
      await bridge?.closeInteractivePanel(id);
    }
  }

  /// Drops all panel state. Used by chat WebView teardown / session reset.
  Future<void> disposeAll({String? charId}) async {
    final targets = charId == null
        ? _panels.values.toList()
        : _panels.values.where((p) => p.charId == charId).toList();
    for (final p in targets) {
      final bridge = _resolveBridge(p.charId);
      await bridge?.closeInteractivePanel(p.remoteId);
    }
    if (charId == null) {
      _panels.clear();
      // Drop the per-char handler bindings so the next openPanel() call
      // rebinds onto a (potentially fresh) bridge. Without this, swapping
      // the underlying chat widget would leave stale handler references.
      _boundChars.clear();
    } else {
      _panels.removeWhere((_, p) => p.charId == charId);
    }
  }

  /// Test-only: clear the singleton registry between tests without
  /// invoking the bridge (which may already be torn down).
  @visibleForTesting
  void resetForTest() {
    _panels.clear();
    _boundChars.clear();
  }

  void dispose() {
    _resizeController.close();
    _eventController.close();
  }

  // ── Internal ───────────────────────────────────────────────────────────

  ChatBridgeController? _resolveBridge(String charId) {
    if (charId.isEmpty) return null;
    if (_bridgeResolver != null) return _bridgeResolver!(charId);
    // Container is injected lazily via the registry; if no widget is mounted
    // for this char yet the lookup returns null and the caller skips.
    try {
      return _container?.read(chatBridgeRegistryProvider(charId));
    } catch (_) {
      return null;
    }
  }

  /// Set by [panelHostServiceProvider] so [openPanel] can resolve the
  /// Riverpod container without taking a hard dependency.
  ProviderContainer? _container;
  final Set<String> _boundChars = {};

  /// Test seam: bypass the Riverpod container and resolve the bridge
  /// through a custom function. Used by [panelHostService_test.dart].
  ChatBridgeController? Function(String charId)? _bridgeResolver;

  void attachContainer(ProviderContainer container) {
    _container = container;
  }

  /// Test-only: install a bridge resolver. Replaces the Riverpod lookup
  /// for the duration of the test. Pass `null` to restore the default.
  @visibleForTesting
  void attachContainerForTest({
    ChatBridgeController? Function(String)? resolveBridge,
  }) {
    _bridgeResolver = resolveBridge;
  }

  void _bindBridgeHandlers(ChatBridgeController bridge, String charId) {
    if (_boundChars.contains(charId)) return;
    _boundChars.add(charId);
    bridge.onPanelResize = (panelId, msgId, height) {
      final state = _panels[panelId];
      if (state == null) return;
      state.lastHeight = height;
      _resizeController.add(
        PanelResizeEvent(
          panelId: panelId,
          messageId: state.messageId,
          heightPx: height,
        ),
      );
    };
    bridge.onPanelEvent = (panelId, msgId, event, payload) {
      final state = _panels[panelId];
      if (state == null) return;
      _eventController.add(
        PanelEvent(
          panelId: panelId,
          messageId: state.messageId,
          event: event,
          payload: payload,
        ),
      );
    };
  }
}

class _PanelState {
  _PanelState({
    required this.localId,
    required this.remoteId,
    required this.messageId,
    required this.charId,
    required this.lastHeight,
  });

  final String localId;
  final String remoteId;
  final String messageId;
  final String charId;
  double lastHeight;
}

class PanelResizeEvent {
  const PanelResizeEvent({
    required this.panelId,
    required this.messageId,
    required this.heightPx,
  });

  final String panelId;
  final String messageId;
  final double heightPx;

  @override
  String toString() =>
      'PanelResizeEvent(panel=$panelId, msg=$messageId, h=$heightPx)';
}

final panelHostServiceProvider = Provider<PanelHostService>((ref) {
  final service = PanelHostService.instance;
  // Stash the container so openPanel() can resolve chatBridgeRegistry
  // lazily without prop-drilling the Ref.
  service.attachContainer(ref.container);
  ref.onDispose(service.dispose);
  return service;
});

/// Helper: JSON-encode an options map for [PanelHostService.openPanel].
String encodePanelOptions(Map<String, dynamic> options) => jsonEncode(options);
