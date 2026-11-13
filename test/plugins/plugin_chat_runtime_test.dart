import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_bridge_controller.dart';
import 'package:glaze_flutter/features/extensions/services/js_bridge_service.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_bridge_service.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_chat_runtime.dart';
import 'package:glaze_flutter/features/plugins/widgets/plugin_layer.dart';

/// A page that records the bodies it runs and answers them from [answer].
class _FakePage implements InAppWebViewController {
  _FakePage(this.answer);

  final Object? Function(String body, Map<String, dynamic> arguments) answer;

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const <String, dynamic>{},
    ContentWorld? contentWorld,
  }) async => CallAsyncJavaScriptResult(
    value: answer(functionBody, arguments),
    error: null,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoJsBridge implements JsBridgeService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoService implements PluginBridgeService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Map<String, Object?> _plugin(String id, {bool onePage = false}) => {
  'pluginId': id,
  'onePage': onePage,
  'panels': [
    {'id': 'p', 'placement': 'chat'},
  ],
};

void main() {
  late List<String> log;
  late PluginChatRuntime runtime;

  /// A page running `intercept` the way the host does: appends its own tag
  /// for each plugin it is asked to run.
  Object? Function(String, Map<String, dynamic>) page(
    String name,
  ) => (body, args) {
    if (body.contains('setup(')) return 1;
    if (body.contains('intercept(')) {
      final only = (args['only'] as List?)?.cast<String>();
      log.add('$name:${only?.join(',')}');
      final payload = args['payload'] as Map;
      return {
        'text':
            '${payload['text']}${only?.map((id) => '[$id]').join() ?? '[all]'}',
        'cancelled': false,
      };
    }
    if (body.contains('runAction(')) {
      log.add('$name:action:${args['pluginId']}');
      return {'ok': true};
    }
    return true;
  };

  Future<void> start({required bool withLayer}) async {
    log = [];
    final chat = ChatBridgeController(_FakePage(page('chat')), _NoJsBridge());
    final layer = withLayer
        ? PluginLayerController(_FakePage(page('layer')))
        : null;
    runtime = PluginChatRuntime(
      bridge: chat,
      layer: layer,
      service: _NoService(),
      chatId: () => 's1',
      onCancelledSend: (_) {},
    );
    await runtime.setup({
      'plugins': [
        _plugin('a'),
        _plugin('t', onePage: true),
        _plugin('u', onePage: true),
        _plugin('b'),
      ],
    });
  }

  test('hooks run in plugin order across the two pages', () async {
    await start(withLayer: true);
    final text = await runtime.prepareGeneration(
      'x',
      source: 'reply',
      generationId: 'g',
    );
    expect(text, 'x[a][t][u][b]');
    expect(log, ['chat:a', 'layer:t,u', 'chat:b']);
  });

  test('actions go to the page running the main script', () async {
    await start(withLayer: true);
    await runtime.runAction('t', 'action:composer:go');
    await runtime.runAction('a', 'action:composer:go');
    expect(log, ['layer:action:t', 'chat:action:a']);
  });

  test('without a plugin layer everything is in the chat page', () async {
    await start(withLayer: false);
    final text = await runtime.prepareGeneration(
      'x',
      source: 'reply',
      generationId: 'g',
    );
    expect(text, 'x[all]');
    await runtime.runAction('t', 'action:composer:go');
    expect(log, ['chat:null', 'chat:action:t']);
  });
}
