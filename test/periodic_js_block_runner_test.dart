import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/periodic_js_block_runner.dart';
import 'package:glaze_flutter/features/extensions/services/js_engine_service.dart';

class _FakeJsEngineController implements JsEngineController {
  int runCalls = 0;

  @override
  Future<void> addJavaScriptHandler({
    required String handlerName,
    required Future<dynamic> Function(List<dynamic> args) callback,
  }) async {}

  @override
  Future<JsAsyncJsResult?> callAsyncJavaScript({
    required String functionBody,
    required Map<String, dynamic> arguments,
  }) async {
    runCalls++;
    return JsAsyncJsResult('headless result');
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<void> evaluateJavascript({required String source}) async {}
}

void main() {
  test('periodic block skips when no active chat bridge is mounted', () async {
    JsEngineService.debugSetInstance(null);
    final engine = JsEngineService.instance;
    final controller = _FakeJsEngineController();
    await engine.debugInitWithController(controller: controller);
    addTearDown(() => JsEngineService.debugSetInstance(null));

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final runner = container.read(
      Provider((ref) => PeriodicJsBlockRunner(ref: ref)),
    );

    final result = await runner.run(
      charId: 'character-1',
      sessionId: 'session-1',
      block: BlockConfig(
        id: 'periodic-1',
        name: 'Periodic',
        type: BlockType.jsRunner,
        prompt: 'return "result";',
      ),
      contextMessages: const <ChatMessage>[],
    );

    expect(result, isNull);
    expect(
      controller.runCalls,
      0,
      reason: 'periodic blocks must not execute through the headless engine',
    );
  });
}
