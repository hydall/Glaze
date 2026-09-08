import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/extensions/services/js_engine_service.dart';
import 'helpers/js_bridge_test_support.dart';

class _FakeEngineController implements JsEngineController {
  _FakeEngineController();

  Object? scriptResult;
  final List<Map<String, dynamic>> calls = [];
  Completer<void>? pendingCall;
  Completer<Object>? pendingResult;
  final Map<String, Future<dynamic> Function(List<dynamic>)> handlers = {};

  @override
  Future<void> addJavaScriptHandler({
    required String handlerName,
    required Future<dynamic> Function(List<dynamic> args) callback,
  }) async {
    handlers[handlerName] = callback;
  }

  @override
  Future<JsAsyncJsResult?> callAsyncJavaScript({
    required String functionBody,
    required Map<String, dynamic> arguments,
  }) async {
    calls.add({'functionBody': functionBody, 'arguments': arguments});
    if (pendingResult != null) {
      final result = await pendingResult!.future;
      return JsAsyncJsResult(result);
    }
    return JsAsyncJsResult(scriptResult);
  }

  @override
  Future<void> evaluateJavascript({required String source}) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  group('JsEngineService', () {
    tearDown(() {
      JsEngineService.debugSetInstance(null);
    });

    test('singleton returns the same instance across calls', () {
      final a = JsEngineService.instance;
      final b = JsEngineService.instance;
      expect(identical(a, b), isTrue);
    });

    test('debugInitWithController marks service ready', () async {
      final fake = _FakeEngineController();
      final service = JsEngineService.instance;
      expect(service.isReady, isFalse);
      expect(service.status, JsEngineStatus.uninitialized);

      await service.debugInitWithController(controller: fake);
      // Re-init is a no-op once ready.
      await service.debugInitWithController(controller: fake);

      expect(service.status, JsEngineStatus.ready);
      expect(service.isReady, isTrue);
    });

    test('runScript returns the controller value as a string', () async {
      final fake = _FakeEngineController()
        ..scriptResult = 'hello from headless';
      final host = JsEngineBridgeHost(bridge: TestJsBridge.create());
      final service = JsEngineService.instance;
      await service.debugInitWithController(controller: fake);

      final result = await service.runScript(
        script: 'return "hi";',
        context: const {'foo': 'bar'},
        host: host,
      );

      expect(result, 'hello from headless');
      expect(fake.calls, hasLength(1));
      final args = fake.calls.first['arguments'] as Map<String, dynamic>;
      expect(args['script'], 'return "hi";');
      expect(args['contextJson'], contains('foo'));
    });

    test('concurrent runs keep bridge authority isolated by run id', () async {
      final fake = _FakeEngineController()..pendingResult = Completer<Object>();
      var firstCalls = 0;
      var secondCalls = 0;
      final firstHost = JsEngineBridgeHost(
        bridge: TestJsBridge.create(
          permissionCheck: (_) => true,
          showToast: (_, _) => firstCalls++,
        ),
      );
      final secondHost = JsEngineBridgeHost(
        bridge: TestJsBridge.create(
          permissionCheck: (_) => true,
          showToast: (_, _) => secondCalls++,
        ),
      );
      final service = JsEngineService.instance;
      await service.debugInitWithController(controller: fake);

      final firstRun = service.runScript(
        script: 'return glaze.showToast("first");',
        context: const {'characterId': 'first'},
        host: firstHost,
      );
      final secondRun = service.runScript(
        script: 'return glaze.showToast("second");',
        context: const {'characterId': 'second'},
        host: secondHost,
      );
      await Future<void>.delayed(Duration.zero);
      final firstRunId =
          (fake.calls[0]['arguments'] as Map<String, dynamic>)['runId'];
      final secondRunId =
          (fake.calls[1]['arguments'] as Map<String, dynamic>)['runId'];

      final firstResponse = await fake.handlers['glazeBridge']!([
        {
          'method': 'showToast',
          'params': {'message': 'first'},
        },
        firstRunId,
      ]);
      final secondResponse = await fake.handlers['glazeBridge']!([
        {
          'method': 'showToast',
          'params': {'message': 'second'},
        },
        secondRunId,
      ]);

      expect(firstResponse['ok'], isTrue);
      expect(secondResponse['ok'], isTrue);
      expect(firstCalls, 1);
      expect(secondCalls, 1);

      fake.pendingResult!.complete('done');
      await Future.wait([firstRun, secondRun]);
    });

    test('completed run authority cannot be reused by a later chat', () async {
      final fake = _FakeEngineController()..scriptResult = 'done';
      var firstCalls = 0;
      var secondCalls = 0;
      final service = JsEngineService.instance;
      await service.debugInitWithController(controller: fake);

      await service.runScript(
        script: 'return 1;',
        context: const {},
        host: JsEngineBridgeHost(
          bridge: TestJsBridge.create(
            permissionCheck: (_) => true,
            showToast: (_, _) => firstCalls++,
          ),
        ),
      );
      final expiredRunId =
          (fake.calls.single['arguments'] as Map<String, dynamic>)['runId'];
      final expired = await fake.handlers['glazeBridge']!([
        {
          'method': 'showToast',
          'params': {'message': 'stale'},
        },
        expiredRunId,
      ]);

      final secondHost = JsEngineBridgeHost(
        bridge: TestJsBridge.create(
          permissionCheck: (_) => true,
          showToast: (_, _) => secondCalls++,
        ),
      );
      final pending = Completer<Object>();
      fake.pendingResult = pending;
      final secondRun = service.runScript(
        script: 'return 2;',
        context: const {},
        host: secondHost,
      );
      await Future<void>.delayed(Duration.zero);
      final secondRunId =
          (fake.calls.last['arguments'] as Map<String, dynamic>)['runId'];
      final current = await fake.handlers['glazeBridge']!([
        {
          'method': 'showToast',
          'params': {'message': 'current'},
        },
        secondRunId,
      ]);

      expect(expired['ok'], isFalse);
      expect(expired['error']['code'], 'bridge_unavailable');
      expect(current['ok'], isTrue);
      expect(firstCalls, 0);
      expect(secondCalls, 1);
      pending.complete('done');
      await secondRun;
    });

    test('runScript throws HeadlessUnavailableError when not ready', () async {
      final service = JsEngineService.instance;
      expect(
        () => service.runScript(
          script: 'return 1;',
          context: const {},
          host: JsEngineBridgeHost(bridge: TestJsBridge.create()),
        ),
        throwsA(isA<HeadlessUnavailableError>()),
      );
    });

    test('cancel rejects an in-flight run', () async {
      final fake = _FakeEngineController()..pendingResult = Completer<Object>();
      final host = JsEngineBridgeHost(bridge: TestJsBridge.create());
      final service = JsEngineService.instance;
      await service.debugInitWithController(controller: fake);

      final pending = service.runScript(
        script: 'return 1;',
        context: const {},
        host: host,
        timeout: const Duration(seconds: 5),
        cancelToken: CancelToken(),
      );
      service.cancel();

      await expectLater(
        pending,
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('cancelled'),
          ),
        ),
      );
    });

    test('dispose clears the controller and marks service disposed', () async {
      final fake = _FakeEngineController();
      final service = JsEngineService.instance;
      await service.debugInitWithController(controller: fake);
      expect(service.isReady, isTrue);

      await service.dispose();
      expect(service.status, JsEngineStatus.disposed);
      expect(service.isReady, isFalse);
    });
  });
}
