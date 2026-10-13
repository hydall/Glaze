import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/composer_text_bridge.dart';
import 'package:glaze_flutter/features/plugins/models/installed_plugin.dart';
import 'package:glaze_flutter/features/plugins/providers/plugin_library_provider.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_api.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_bridge_service.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_file_store.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_html_inliner.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_message_diff.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_variable_store.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_manifest_parser.dart';

class _FakeUi implements PluginUi {
  final toasts = <String>[];
  final consents = <String>[];
  PluginConsentAnswer answer = PluginConsentAnswer.deny;

  @override
  void toast(String text) => toasts.add(text);
  @override
  Future<void> openUrl(String url) async {}
  @override
  Future<String?> select(
    List<PluginOption> options, {
    String? title,
    String? defaultValue,
  }) async => options.first.value;
  @override
  Future<Map<String, Object?>> ask({
    required String question,
    required List<PluginOption> options,
    required bool allowOther,
    String? placeholder,
    String? defaultValue,
  }) async => {'status': 'cancelled'};
  @override
  Future<PluginConsentAnswer> consent({
    required String pluginName,
    required PluginConsent kind,
    required String summary,
  }) async {
    consents.add('$pluginName:${kind.name}:$summary');
    return answer;
  }

  @override
  Future<void> previewImage(Uint8List bytes) async {}
  @override
  Future<void> share(Uint8List bytes, String filename) async {}
  @override
  Future<List<PickedPluginFile>> pickFiles({
    required bool multiple,
    List<String>? extensions,
  }) async => const [];
  @override
  Future<void> openChat(String characterId, int sessionIndex) async {}
}

class _FakeHost implements PluginApiHost {
  _FakeHost(this.ref, this.variables, this.dataRoot);

  @override
  final Ref ref;
  @override
  final PluginVariableStore variables;
  final String dataRoot;
  @override
  final _FakeUi ui = _FakeUi();
  String composerText = '';
  final varPushes = <String>[];

  @override
  String get charId => 'char';
  @override
  String? get sessionId => 's1';
  @override
  ComposerTextAccess? composer() => ComposerTextAccess(
    read: () => composerText,
    write: (t) => composerText = t,
    send: () async => true,
  );
  @override
  PluginFileStore files(String pluginId) =>
      PluginFileStore(dataDir: '$dataRoot/$pluginId');
  @override
  void variablesChanged(String scope, Map<String, dynamic> root) =>
      varPushes.add('$scope:${jsonEncode(root)}');
}

InstalledPlugin _plugin(
  List<String> permissions, {
  Set<String> grants = const {},
}) => InstalledPlugin(
  manifest: parsePluginManifest({
    'format': 1,
    'id': 'test.plugin',
    'name': 'Test',
    'version': '1.0.0',
    'permissions': permissions,
  }),
  directory: '/nowhere',
  enabled: true,
  installedAt: 0,
  grants: grants,
);

void main() {
  late AppDatabase db;
  late Directory temp;
  late ProviderContainer container;
  late _FakeHost host;
  late List<String> alwaysAllowed;

  const session = ChatSession(
    id: 's1',
    characterId: 'char',
    sessionIndex: 0,
    messages: [
      ChatMessage(id: 'm1', role: 'assistant', content: 'Hi'),
      ChatMessage(id: 'm2', role: 'user', content: 'Hello', isHidden: true),
      ChatMessage(id: 'm3', role: 'assistant', content: 'How are you?'),
    ],
  );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    temp = await Directory.systemTemp.createTemp('plugin_bridge_test');
    container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    final chatRepo = ChatRepo(db);
    await chatRepo.put(session);
    host = _FakeHost(
      container.read(pluginRefProvider),
      PluginVariableStore(
        chatRepo: chatRepo,
        globalFile: File('${temp.path}/globals.json'),
      ),
      temp.path,
    );
    alwaysAllowed = [];
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });

  PluginBridgeService service(
    List<String> permissions, {
    Set<String> grants = const {},
  }) {
    final plugin = _plugin(permissions, grants: grants);
    return PluginBridgeService(
      host: host,
      pluginById: (id) => id == plugin.id ? plugin : null,
      pluginName: (p) => 'Test',
      consentText: (key) => key,
      onAlwaysAllow: (id, kind) async => alwaysAllowed.add('$id:${kind.name}'),
    );
  }

  Future<Map<String, dynamic>> call(
    PluginBridgeService s,
    String method, [
    Object? params,
    String pluginId = 'test.plugin',
  ]) => s.dispatch({'pluginId': pluginId, 'method': method, 'params': params});

  test(
    'denies methods the manifest does not grant, and unknown plugins',
    () async {
      final s = service(const []);
      final denied = await call(s, 'variables.get', ['x']);
      expect(denied['ok'], false);
      expect((denied['error'] as Map)['code'], 'permission_denied');
      final unknown = await call(s, 'ui.toast', ['hi'], 'other.plugin');
      expect((unknown['error'] as Map)['code'], 'permission_denied');
      final ok = await call(s, 'ui.toast', ['hi']);
      expect(ok['ok'], true);
      expect(host.ui.toasts, ['hi']);
      expect(
        pluginMethodsFor(_plugin(const [])),
        isNot(contains('composer.get')),
      );
      expect(
        pluginMethodsFor(_plugin(const ['composer'])),
        contains('composer.get'),
      );
    },
  );

  test(
    'chat variables: dotted paths, update merges, delete, sync push',
    () async {
      final s = service(const ['variables']);
      await call(s, 'variables.set', [
        'status',
        {'hp': 100, 'mp': 32},
        'chat',
      ]);
      await call(s, 'variables.update', [
        'status',
        {'hp': 70},
      ]);
      final hp = await call(s, 'variables.get', ['status.hp']);
      expect(hp['result'], 70);
      final all = await call(s, 'variables.list', ['chat']);
      expect(all['result'], {
        'status': {'hp': 70, 'mp': 32},
      });
      final removed = await call(s, 'variables.delete', ['status.mp']);
      expect(removed['ok'], true);
      expect(host.varPushes.last, 'chat:{"status":{"hp":70}}');
      // Stored in the session row, separate from block variables.
      final stored = await ChatRepo(db).getById('s1');
      expect(
        stored!.sessionVars[PluginVariableStore.chatKey],
        contains('"hp":70'),
      );
    },
  );

  test('global variables live outside the chat', () async {
    final s = service(const ['variables']);
    await call(s, 'variables.set', ['best', 3, 'global']);
    final chat = await call(s, 'variables.get', ['best']);
    final global = await call(s, 'variables.get', ['best', 'global']);
    expect(chat['result'], isNull);
    expect(global['result'], 3);
  });

  test('message variables are keyed by message and forgotten', () async {
    final s = service(const ['variables']);
    await s.dispatch({
      'pluginId': 'test.plugin',
      'method': 'variables.set',
      'params': ['seen', true, 'message'],
      'messageId': 'm3',
    });
    final read = await call(s, 'variables.get', [
      'seen',
      {'scope': 'message', 'id': 'm3'},
    ]);
    expect(read['result'], true);
    await host.variables.forgetMessages('s1', {'m3'});
    final after = await call(s, 'variables.get', [
      'seen',
      {'scope': 'message', 'id': 'm3'},
    ]);
    expect(after['result'], isNull);
  });

  test('composer goes through the host', () async {
    final s = service(const ['composer']);
    await call(s, 'composer.set', ['draft']);
    await call(s, 'composer.append', [' more']);
    expect((await call(s, 'composer.get'))['result'], 'draft more');
    final sent = await call(s, 'composer.send');
    expect(sent['result'], {'ok': true, 'text': 'draft more'});
  });

  test('commands pipe their output and check permissions', () async {
    final s = service(const ['variables']);
    final out = await call(s, 'commands.run', [
      '/setvar key=mood calm | /getvar mood | /echo now {{pipe}}',
    ]);
    expect(out['result'], 'now calm');
    expect(host.ui.toasts, ['now calm']);
    final denied = await call(s, 'commands.run', ['/send hi']);
    expect((denied['error'] as Map)['code'], 'permission_denied');
  });

  test('library writes ask first; "always" is remembered', () async {
    final s = service(const ['library']);
    host.ui.answer = PluginConsentAnswer.deny;
    final denied = await call(s, 'characters.remove', ['nope']);
    expect((denied['error'] as Map)['code'], 'user_denied');
    expect(host.ui.consents, ['Test:library:plugins_consent_character_remove']);

    host.ui.answer = PluginConsentAnswer.always;
    await call(s, 'characters.remove', ['nope']);
    await call(s, 'characters.remove', ['nope']);
    expect(host.ui.consents, hasLength(2));
    expect(alwaysAllowed, ['test.plugin:library']);

    final granted = service(const ['library'], grants: const {'library'});
    host.ui.consents.clear();
    await call(granted, 'characters.remove', ['nope']);
    expect(host.ui.consents, isEmpty);
  });

  test('files stay inside the plugin folder', () async {
    final s = service(const ['files']);
    final saved = await call(s, 'files.save', ['note.txt', 'hello']);
    expect(saved['result'], 'files/chat/note.txt');
    final loaded = await call(s, 'files.load', ['files/chat/note.txt']);
    expect(loaded['result'], 'hello');
    final escape = await call(s, 'files.save', ['../x.txt', 'bad']);
    expect((escape['error'] as Map)['code'], 'invalid_arguments');
    final listed = await call(s, 'files.list', [
      {'scope': 'chat'},
    ]);
    expect(
      ((listed['result'] as Map)['files'] as List).single['name'],
      'note.txt',
    );
  });

  test('storage shim persists per plugin', () async {
    final s = service(const []);
    await call(s, 'storage.set', {'key': 'a', 'value': '1'});
    await call(s, 'storage.set', {'key': 'b', 'value': '2'});
    await call(s, 'storage.remove', {'key': 'a'});
    expect(await host.files('test.plugin').readStorage(), {'b': '2'});
  });

  test('message diff reports added, updated and deleted', () {
    final before = pluginMessageSignatures(session.messages);
    final after = [
      session.messages[0].copyWith(content: 'Hi!'),
      session.messages[2],
      const ChatMessage(id: 'm4', role: 'user', content: 'New'),
    ];
    final changes = diffPluginMessages(before, after);
    expect(changes.map((c) => '${c.change}:${c.id}'), [
      'deleted:m2',
      'updated:m1',
      'added:m4',
    ]);
  });

  test('package scripts, stylesheets and assets are inlined', () async {
    final files = {
      'js/a.js': 'window.x = "</script>";',
      'ui/s.css': 'body{background:url(/plugins/p.one/img/bg.png)}',
      'img/bg.png': 'PNG',
    };
    final html = await inlinePluginAssets(
      '<link rel="stylesheet" href="/plugins/p.one/ui/s.css">'
      '<script defer src="/plugins/p.one/js/a.js"></script>'
      '<img src="/plugins/p.one/img/bg.png">',
      (id, path) async => id == 'p.one' && files.containsKey(path)
          ? Uint8List.fromList(utf8.encode(files[path]!))
          : null,
    );
    expect(html, contains(r'window.x = "<\/script>";'));
    expect(html, isNot(contains('src="/plugins')));
    expect(html, contains('<style>body{background:url(data:image/png;base64,'));
    expect(html, contains('<img src="data:image/png;base64,UE5H">'));
  });
}
