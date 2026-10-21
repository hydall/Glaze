import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../core/platform/haptics.dart';
import '../bridge/chat_bridge_controller.dart';

/// Called with the data of one chrome intent.
typedef ChromeIntentHandler = void Function(Map<String, dynamic> data);

/// Where the chrome's parts are on screen, in page pixels — which are the chat
/// body's logical pixels: the WebView fills the body and the page is not
/// scaled. Reported by the page whenever any of it moves.
@immutable
class ChromeLayoutReport {
  const ChromeLayoutReport({
    this.composerHeight = 0,
    this.header,
    this.headerBlock,
    this.searchButton,
    this.composer,
    this.send,
    this.row,
    this.drawer,
    this.pins = const [],
  });

  static const empty = ChromeLayoutReport();

  /// The composer's whole box: attachments, pill, button row and the bottom
  /// gap — what the message list keeps clear above the keyboard.
  final double composerHeight;
  final Rect? header;
  final Rect? headerBlock;
  final Rect? searchButton;
  final Rect? composer;
  final Rect? send;
  final Rect? row;
  final Rect? drawer;

  /// The pinned buttons under the composer, by pin key, in row order.
  final List<({String key, Rect rect})> pins;

  static Rect? _rect(Object? raw) {
    if (raw is! List || raw.length != 4) return null;
    final v = [for (final x in raw) x is num ? x.toDouble() : double.nan];
    if (v.any((x) => !x.isFinite) || v[2] <= 0 || v[3] <= 0) return null;
    return Rect.fromLTWH(v[0], v[1], v[2], v[3]);
  }

  factory ChromeLayoutReport.fromJson(Map<String, dynamic> json) {
    final pins = <({String key, Rect rect})>[];
    final rawPins = json['pins'];
    if (rawPins is List) {
      for (final p in rawPins) {
        if (p is! Map) continue;
        final key = p['key'];
        final rect = _rect(p['r']);
        if (key is String && rect != null) pins.add((key: key, rect: rect));
      }
    }
    final height = json['composerHeight'];
    return ChromeLayoutReport(
      composerHeight: height is num ? height.toDouble() : 0,
      header: _rect(json['header']),
      headerBlock: _rect(json['headerBlock']),
      searchButton: _rect(json['searchButton']),
      composer: _rect(json['composer']),
      send: _rect(json['send']),
      row: _rect(json['row']),
      drawer: _rect(json['drawer']),
      pins: pins,
    );
  }
}

/// The Dart end of the chat chrome — the header, composer and drawer drawn in
/// the chat WebView (`assets/chat_webview/chrome/`).
///
/// Hosts set *sections* of state ([set]): each is sent when it changes, and
/// all of them again when the chrome is attached to a new page. One-off
/// *events* ([push]) — text written into the composer, focus moves — are sent
/// once. Everything set within one microtask goes over as one call.
///
/// The page answers with intents (a tap, typed text, a drop), which reach the
/// handlers registered with [on].
class ChatChromeChannel {
  ChatBridgeController? _bridge;
  final Map<String, Object?> _latest = {};
  final Map<String, String> _sent = {};
  final Set<String> _dirty = {};
  final Map<String, Object?> _events = {};
  final Map<String, List<ChromeIntentHandler>> _handlers = {};
  bool _flushQueued = false;
  bool _disposed = false;

  /// Where the chrome is on screen — see [ChromeLayoutReport].
  final ValueNotifier<ChromeLayoutReport> layout = ValueNotifier(
    ChromeLayoutReport.empty,
  );

  bool get isAttached => _bridge != null;

  /// The latest value of every section, as the page would get it.
  @visibleForTesting
  Map<String, Object?> get debugSections => Map.unmodifiable(_latest);

  /// Feeds an intent in as if the page had sent it.
  @visibleForTesting
  void debugIntent(String type, Map<String, dynamic> data) =>
      _onIntent(type, data);

  /// Takes over [bridge]'s page: claims its chrome keys and sends every
  /// section. Returns false where the page has no chrome to drive.
  Future<bool> attach(ChatBridgeController bridge) async {
    if (_disposed) return false;
    final ok = await bridge.chromeHandshake();
    if (!ok || _disposed) return false;
    _bridge = bridge;
    bridge.onChromeIntent = _onIntent;
    _sent.clear();
    _dirty.addAll(_latest.keys);
    await _flush();
    return true;
  }

  /// Sets one section of the chrome's state. Sent only when it differs from
  /// what the page already has.
  void set(String section, Object? value) {
    _latest[section] = value;
    _dirty.add(section);
    _schedule();
  }

  /// Records [value] as what the page already holds in [section] — it came
  /// from the page — so it is sent only to the next page attached.
  void remember(String section, Object? value) {
    _latest[section] = value;
    _sent[section] = jsonEncode(value);
    _dirty.remove(section);
  }

  /// Sends one event; merged with the others of the same microtask.
  void push(String key, Object? value) {
    final current = _events[key];
    if (current is Map && value is Map) {
      _events[key] = {...current, ...value};
    } else {
      _events[key] = value;
    }
    _schedule();
  }

  /// Registers [handler] for intents of [type]; the returned callback removes
  /// it again.
  VoidCallback on(String type, ChromeIntentHandler handler) {
    (_handlers[type] ??= []).add(handler);
    return () => _handlers[type]?.remove(handler);
  }

  /// Registers several handlers at once; the returned callback removes them.
  VoidCallback onAll(Map<String, ChromeIntentHandler> handlers) {
    final removers = [
      for (final entry in handlers.entries) on(entry.key, entry.value),
    ];
    return () {
      for (final remove in removers) {
        remove();
      }
    };
  }

  void _schedule() {
    if (_flushQueued || _disposed) return;
    _flushQueued = true;
    scheduleMicrotask(() {
      _flushQueued = false;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    final bridge = _bridge;
    if (bridge == null || _disposed) return;
    final msg = <String, Object?>{};
    for (final section in _dirty) {
      final value = _latest[section];
      final encoded = jsonEncode(value);
      if (_sent[section] == encoded) continue;
      _sent[section] = encoded;
      msg[section] = value;
    }
    _dirty.clear();
    msg.addAll(_events);
    _events.clear();
    if (msg.isEmpty) return;
    try {
      await bridge.applyChrome(jsonEncode(msg));
    } catch (e) {
      debugPrint('[ChatChrome] apply failed: $e');
    }
  }

  void _onIntent(String type, Map<String, dynamic> data) {
    if (_disposed) return;
    switch (type) {
      case 'layout':
        layout.value = ChromeLayoutReport.fromJson(data);
        return;
      case 'haptic':
        Haptics.mediumImpact();
        return;
    }
    final handlers = _handlers[type];
    if (handlers == null) return;
    for (final handler in List.of(handlers)) {
      handler(data);
    }
  }

  /// Takes the chrome off the page — the WebView stays alive for the next
  /// chat, which must not open on this one's header.
  void dispose() {
    final bridge = _bridge;
    _disposed = true;
    _bridge = null;
    if (bridge != null) {
      if (bridge.onChromeIntent == _onIntent) bridge.onChromeIntent = null;
      unawaited(
        bridge.applyChrome(
          jsonEncode({
            'header': {'show': false},
            'composer': {'show': false},
            'drawer': {'show': false},
            'layout': {'fades': false},
            'cmd': {'blur': true, 'cancelDrag': true},
          }),
        ),
      );
    }
    layout.dispose();
    _handlers.clear();
  }
}
