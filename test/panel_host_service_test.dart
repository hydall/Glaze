import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/bridge/chat_bridge_controller.dart';
import 'package:glaze_flutter/features/extensions/services/panel_host_service.dart';

class _FakeBridge implements ChatBridgeController {
  final List<Map<String, String>> openCalls = [];
  final List<String> closeCalls = [];
  String? nextPanelId;
  bool _nextPanelIdPinned = false;
  int _counter = 0;
  String? openThrows;

  @override
  void Function(String panelId, String messageId, double height)?
      onPanelResize;
  @override
  void Function(String panelId, String messageId, String event,
          Map<String, dynamic> payload)?
      onPanelEvent;

  /// Returns a fresh remote id for every call. Tests that expect
  /// `null` should set [nextPanelId] explicitly to null before calling.
  String _allocateId() {
    _counter++;
    return 'remote_${_counter}_${DateTime.now().microsecondsSinceEpoch}';
  }

  void pinPanelId(String? id) {
    nextPanelId = id;
    _nextPanelIdPinned = true;
  }

  @override
  Future<String?> openInteractivePanel({
    required String messageId,
    required String html,
    Map<String, dynamic> options = const {},
  }) async {
    openCalls.add({'messageId': messageId, 'html': html});
    if (openThrows != null) throw StateError(openThrows!);
    if (_nextPanelIdPinned) return nextPanelId;
    return _allocateId();
  }

  @override
  Future<void> closeInteractivePanel(String panelId) async {
    closeCalls.add(panelId);
  }

  @override
  Future<void> closeAllInteractivePanels() async {}

  @override
  Future<bool> postToInteractivePanel({
    required String panelId,
    required String method,
    Map<String, dynamic> params = const {},
  }) async =>
      true;

  // ── Unused members — throw to surface accidental calls during tests.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeBridge.${invocation.memberName}');
}

void main() {
  group('PanelHostService', () {
    setUp(() {
      // Reset singleton state between tests so bridge handler bindings
      // are reinstalled and per-char panels don't leak across tests.
      PanelHostService.instance.resetForTest();
    });

    test('openPanel returns null when no bridge is registered', () async {
      // No container attached → resolveBridge returns null.
      final result = await PanelHostService.instance.openPanel(
        charId: 'charA',
        messageId: 'msg1',
        html: '<p>hi</p>',
      );
      expect(result, isNull);
      expect(PanelHostService.instance.isEmpty, isTrue);
    });

    test('openPanel registers panel when bridge returns an id', () async {
      final bridge = _FakeBridge()..pinPanelId('remote_1');
      PanelHostService.instance.attachContainerForTest(
        resolveBridge: (_) => bridge,
      );

      final result = await PanelHostService.instance.openPanel(
        charId: 'charA',
        messageId: 'msg1',
        html: '<p>hi</p>',
        options: {'title': 'demo', 'minHeight': 200},
      );

      expect(result, isNotNull);
      expect(result!.panelId, 'remote_1');
      expect(result.messageId, 'msg1');
      expect(PanelHostService.instance.openCount, 1);
      expect(bridge.openCalls, hasLength(1));
      expect(bridge.openCalls.single['messageId'], 'msg1');
      expect(bridge.openCalls.single['html'], '<p>hi</p>');
    });

    test('openPanel drops the entry when the WebView returns null', () async {
      final bridge = _FakeBridge()..pinPanelId(null);
      PanelHostService.instance.attachContainerForTest(
        resolveBridge: (_) => bridge,
      );

      final result = await PanelHostService.instance.openPanel(
        charId: 'charA',
        messageId: 'msg1',
        html: '<p>hi</p>',
      );

      expect(result, isNull);
      expect(PanelHostService.instance.isEmpty, isTrue);
    });

    test('closePanel forwards to bridge and removes entry', () async {
      final bridge = _FakeBridge()..pinPanelId('remote_2');
      PanelHostService.instance.attachContainerForTest(
        resolveBridge: (_) => bridge,
      );
      final opened = await PanelHostService.instance.openPanel(
        charId: 'charA',
        messageId: 'msg1',
        html: '<p>hi</p>',
      );

      await PanelHostService.instance.closePanel(
        charId: 'charA',
        panelId: opened!.panelId,
      );

      expect(bridge.closeCalls, [opened.panelId]);
      expect(PanelHostService.instance.isEmpty, isTrue);
    });

    test('closePanel is a no-op for unknown ids', () async {
      final bridge = _FakeBridge();
      PanelHostService.instance.attachContainerForTest(
        resolveBridge: (_) => bridge,
      );
      await PanelHostService.instance.closePanel(
        charId: 'charA',
        panelId: 'does_not_exist',
      );
      expect(bridge.closeCalls, isEmpty);
    });

    test('disposeAll drops every panel for the given char', () async {
      final bridge = _FakeBridge();
      PanelHostService.instance.attachContainerForTest(
        resolveBridge: (_) => bridge,
      );
      await PanelHostService.instance.openPanel(
        charId: 'charA',
        messageId: 'm1',
        html: '<p>1</p>',
      );
      await PanelHostService.instance.openPanel(
        charId: 'charA',
        messageId: 'm2',
        html: '<p>2</p>',
      );

      await PanelHostService.instance.disposeAll(charId: 'charA');

      expect(bridge.closeCalls, hasLength(2));
      expect(PanelHostService.instance.isEmpty, isTrue);
    });

    test('disposeAll() without arg clears every char', () async {
      final bridge = _FakeBridge();
      PanelHostService.instance.attachContainerForTest(
        resolveBridge: (_) => bridge,
      );
      await PanelHostService.instance.openPanel(
        charId: 'charA',
        messageId: 'm1',
        html: '<p>1</p>',
      );
      await PanelHostService.instance.openPanel(
        charId: 'charB',
        messageId: 'm2',
        html: '<p>2</p>',
      );

      await PanelHostService.instance.disposeAll();

      expect(PanelHostService.instance.isEmpty, isTrue);
    });

    test('resize callback fires the broadcast stream', () async {
      final bridge = _FakeBridge()..pinPanelId('remote_5');
      PanelHostService.instance.attachContainerForTest(
        resolveBridge: (_) => bridge,
      );
      await PanelHostService.instance.openPanel(
        charId: 'charA',
        messageId: 'msg1',
        html: '<p>hi</p>',
      );
      // Trigger handler binding (openPanel does it on first call).
      expect(bridge.onPanelResize, isNotNull);

      final events = <PanelResizeEvent>[];
      final sub = PanelHostService.instance.resizeStream.listen(events.add);

      bridge.onPanelResize!.call('remote_5', 'msg1', 222.0);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, hasLength(1));
      expect(events.single.heightPx, 222.0);
      expect(events.single.messageId, 'msg1');
    });

    test('event callback for unknown panel is ignored', () async {
      final bridge = _FakeBridge()..pinPanelId('remote_6');
      PanelHostService.instance.attachContainerForTest(
        resolveBridge: (_) => bridge,
      );
      await PanelHostService.instance.openPanel(
        charId: 'charA',
        messageId: 'msg1',
        html: '<p>hi</p>',
      );
      final events = <PanelEvent>[];
      final sub = PanelHostService.instance.eventStream.listen(events.add);
      bridge.onPanelEvent!.call('unknown', 'msg?', 'click', {'k': 'v'});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events, isEmpty);
    });
  });
}
