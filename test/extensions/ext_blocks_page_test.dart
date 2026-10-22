import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_bridge_controller.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_modes.dart';
import 'package:glaze_flutter/features/extensions/models/preset_permissions.dart';
import 'package:glaze_flutter/features/extensions/services/js_bridge_service.dart';
import 'package:glaze_flutter/features/extensions/services/page/ext_blocks_page.dart';
import 'package:glaze_flutter/features/plugins/models/installed_plugin.dart';
import 'package:glaze_flutter/features/plugins/models/plugin_manifest.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_bridge_service.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_chat_runtime.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_file_store.dart';
import 'package:glaze_flutter/features/plugins/widgets/plugin_layer.dart';

/// A page that records what it runs and answers from [answer].
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
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async => null;

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

ChatState _state(List<ChatMessage> messages, {String id = 's1'}) => ChatState(
  session: ChatSession(
    id: id,
    characterId: 'c1',
    sessionIndex: 0,
    sessionVars: const {},
    messages: messages,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<(String, Map<String, dynamic>)> chatCalls;
  late List<(String, Map<String, dynamic>)> layerCalls;
  late Object? Function(Map<String, dynamic> args) actionAnswer;
  late ChatState state;
  late ChatBridgeController bridge;
  late PluginChatRuntime runtime;
  late ExtBlocksPage page;

  T read<T>(ProviderListenable<T> provider) {
    if ((provider as Object) == chatProvider('c1')) {
      return AsyncData(state) as T;
    }
    throw UnsupportedError('$provider');
  }

  setUp(() async {
    chatCalls = [];
    layerCalls = [];
    actionAnswer = (_) => {'ok': true, 'value': 'done'};
    state = _state(const []);
    bridge = ChatBridgeController(
      _FakePage((body, args) {
        chatCalls.add((body, args));
        if (body.contains('setup(')) return 1;
        if (body.contains('runSandboxedScript')) return 'sandbox';
        return true;
      }),
      _NoJsBridge(),
    );
    runtime = PluginChatRuntime(
      bridge: bridge,
      layer: PluginLayerController(
        _FakePage((body, args) {
          layerCalls.add((body, args));
          if (body.contains('setup(')) return 1;
          if (body.contains('runAction(')) return actionAnswer(args);
          return true;
        }),
      ),
      service: _NoService(),
      chatId: () => 's1',
      onCancelledSend: (_) {},
    );
    await runtime.setup({
      'plugins': [
        await extBlocksPageEntry(
          files: PluginFileStore(
            dataDir: Directory.systemTemp.createTempSync('xb').path,
          ),
          allowExternalMedia: false,
        ),
      ],
    });
    page = ExtBlocksPage(
      runtime: runtime,
      bridge: bridge,
      charId: 'c1',
      read: read,
    );
    bridge.extBlocksPageRun = page.run;
  });

  tearDown(() => page.dispose());

  test(
    'a script of the original runs on the page, in the plugin layer',
    () async {
      final result = await bridge.runJsBlock(
        script: 'return 1',
        messages: const [ChatMessage(id: 'm1', role: 'user', content: 'hi')],
        character: null,
        sessionId: 's1',
        previousOutput: null,
        extBlocks: const {'messageId': 0},
      );
      expect(result, 'done');
      final action = layerCalls.singleWhere((c) => c.$1.contains('runAction('));
      expect(action.$2['pluginId'], kExtBlocksPagePluginId);
      expect(action.$2['event'], 'action:extblocks:run');
      final args = action.$2['args'] as Map;
      expect(args['script'], 'return 1');
      expect(args['restore'], false);
      expect((args['context'] as Map)['extBlocks'], {'messageId': 0});
      expect((args['context'] as Map)['messages'], [
        {'role': 'user', 'text': 'hi'},
      ]);
      expect(
        chatCalls.where((c) => c.$1.contains('runSandboxedScript')),
        isEmpty,
      );
    },
  );

  test('a script the model wrote stays in the sandbox', () async {
    final result = await bridge.runJsBlock(
      script: 'return 1',
      messages: const [],
      character: null,
      sessionId: 's1',
      previousOutput: null,
    );
    expect(result, 'sandbox');
    expect(layerCalls.where((c) => c.$1.contains('runAction(')), isEmpty);
  });

  test('a failing script fails the run with its message', () async {
    actionAnswer = (_) => {
      'ok': false,
      'reason': 'handler-error',
      'message': 'boom',
    };
    await expectLater(
      page.run('throw 1', const {}, null),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'boom')),
    );
  });

  test('the mirror sends what changed, in chat order', () async {
    List<Map<Object?, Object?>> mirrors() => [
      for (final c in layerCalls)
        if (c.$1.contains('relayEmit(') && c.$2['event'] == 'extblocks:mirror')
          c.$2['detail'] as Map<Object?, Object?>,
    ];
    state = _state(const [
      ChatMessage(id: 'm1', role: 'user', content: 'hi'),
      ChatMessage(
        id: 'm2',
        role: 'assistant',
        content:
            '<img data-iig-instruction=\'{"prompt":"cat"}\' '
            'src="generated/a.jpg" style="width:100%">',
      ),
    ]);
    page.flush();
    page.flush();
    expect(mirrors(), hasLength(1));
    final first = mirrors().single;
    expect(first['reset'], true);
    expect(first['order'], ['m1', 'm2']);
    final upsert = (first['upsert'] as List).cast<Map<Object?, Object?>>();
    expect(upsert.map((m) => m['id']), ['m1', 'm2']);
    expect(upsert.map((m) => m['isUser']), [true, false]);
    // The author's markup is there for the script to read.
    expect(upsert[1]['html'], contains('data-iig-instruction'));

    state = _state(const [
      ChatMessage(id: 'm1', role: 'user', content: 'hi'),
      ChatMessage(id: 'm2', role: 'assistant', content: 'edited'),
      ChatMessage(id: 'm3', role: 'user', content: 'next'),
    ]);
    page.flush();
    final second = mirrors().last;
    expect(second['reset'], false);
    expect(second['order'], ['m1', 'm2', 'm3']);
    expect(
      (second['upsert'] as List).map((m) => (m as Map<Object?, Object?>)['id']),
      ['m2', 'm3'],
    );

    // Another chat starts the mirror over.
    state = _state(const [
      ChatMessage(id: 'x1', role: 'user', content: 'hi'),
    ], id: 's2');
    page.flush();
    expect(mirrors().last['reset'], true);
  });

  test('the page reaches the internet only with external media', () async {
    final dir = Directory.systemTemp.createTempSync('xb').path;
    final off = await extBlocksPageEntry(
      files: PluginFileStore(dataDir: dir),
      allowExternalMedia: false,
    );
    final on = await extBlocksPageEntry(
      files: PluginFileStore(dataDir: dir),
      allowExternalMedia: true,
    );
    expect(off['network'], false);
    expect(on['network'], true);
    expect(on['localNetwork'], false);
    expect(on['onePage'], true);
    expect(on['methods'], ['extblocks.bridge']);
  });

  test('only the page sees its bridge method', () {
    expect(pluginMethodsFor(extBlocksPagePlugin), contains('extblocks.bridge'));
    final other = InstalledPlugin(
      manifest: const PluginManifest(
        format: 1,
        id: 'other',
        name: PluginText.literal('Other'),
        version: '1.0.0',
        raw: {},
      ),
      directory: '',
      enabled: true,
      installedAt: 0,
    );
    expect(pluginMethodsFor(other), isNot(contains('extblocks.bridge')));
  });

  test('only carried JavaScript runs on the page', () {
    const carried = BlockConfig(
      id: 'a',
      name: 'a',
      type: BlockType.script,
      source: BlockSource.carried,
      scriptType: ScriptType.js,
    );
    expect(runsOnExtBlocksPage(carried), true);
    expect(
      runsOnExtBlocksPage(carried.copyWith(source: BlockSource.model)),
      false,
    );
    expect(
      runsOnExtBlocksPage(carried.copyWith(scriptType: ScriptType.stScript)),
      false,
    );
  });

  test('the page is its own capability, off by default', () {
    const none = PresetPermissions();
    expect(none.chatPage, false);
    expect(none.isGrantedById('chat_page'), false);
    expect(
      none
          .copyWithField(GlazeCapability.chatPage, true)
          .isGrantedById('chat_page'),
      true,
    );
  });
}
