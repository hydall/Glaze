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
import 'package:glaze_flutter/features/plugins/models/plugin_manifest.dart';
import 'package:glaze_flutter/features/plugins/providers/plugin_library_provider.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_api.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_bridge_service.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_file_store.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_network.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_html_inliner.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_message_diff.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_variable_store.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_manifest_parser.dart';

class _FakeUi implements PluginUi {
  final toasts = <String>[];
  final consents = <String>[];
  PluginConsentAnswer? answer = PluginConsentAnswer.deny;

  @override
  void toast(String pluginName, String text) => toasts.add(text);
  @override
  Future<void> openUrl(String url) async {}
  @override
  Future<String?> select(
    String pluginName,
    List<PluginOption> options, {
    String? title,
    String? defaultValue,
  }) async => options.first.value;
  @override
  Future<Map<String, Object?>> ask({
    required String pluginName,
    required String question,
    required List<PluginOption> options,
    required bool allowOther,
    String? placeholder,
    String? defaultValue,
  }) async => {'status': 'cancelled'};
  @override
  Future<PluginConsentAnswer?> consent({
    required String pluginName,
    required String permission,
    required String summary,
  }) async {
    consents.add('$pluginName:$permission:$summary');
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
  void variablesChanged(
    String pluginId,
    String scope,
    Map<String, dynamic> root,
  ) => varPushes.add('$pluginId/$scope:${jsonEncode(root)}');
  final network = <String>[];
  @override
  void networkUsed(String pluginId, String host, {required bool blocked}) =>
      network.add('$host:${blocked ? 'blocked' : 'ok'}');
  final grants = <String>[];
  @override
  void allowed(String pluginId, String actionKey) => grants.add(actionKey);
  final denials = <String>[];
  @override
  void denied(
    String pluginId,
    String pluginName,
    String actionKey, {
    bool shown = true,
  }) => denials.add('$actionKey${shown ? '' : ':silent'}');
}

InstalledPlugin _plugin(
  List<String> permissions, {
  Set<String> grants = const {},
  Set<String> revoked = const {},
  Set<String>? networkHosts,
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
  revoked: revoked,
  networkHosts: networkHosts,
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
        globalFile: (id) => File('${temp.path}/$id/variables.json'),
        sharedFile: File('${temp.path}/shared.json'),
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
    Set<String> revoked = const {},
  }) {
    var plugin = _plugin(permissions, grants: grants, revoked: revoked);
    return PluginBridgeService(
      host: host,
      pluginById: (id) => id == plugin.id ? plugin : null,
      pluginName: (p) => 'Test',
      text: (key) => key,
      onAlwaysAllow: (id, permission) async {
        alwaysAllowed.add('$id:$permission');
        plugin = plugin.copyWith(grants: {...plugin.grants, permission});
      },
      onDeny: (id, permission) async =>
          plugin = plugin.copyWith(revoked: {...plugin.revoked, permission}),
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

  test('permissions the user took away are denied with a notice', () async {
    final s = service(
      const ['composer', 'library.delete'],
      revoked: const {'composer', 'library.delete'},
    );
    final composer = await call(s, 'composer.get');
    expect((composer['error'] as Map)['code'], 'permission_denied');
    final library = await call(s, 'characters.remove', ['nope']);
    expect((library['error'] as Map)['code'], 'permission_denied');
    expect(host.ui.consents, isEmpty);
    expect(host.denials, [
      'plugins_permission_name_composer',
      'plugins_consent_character_remove',
    ]);
    final plugin = _plugin(const ['composer'], revoked: const {'composer'});
    expect(plugin.allows('composer'), isFalse);
    // Still visible, so the call reaches the app and is refused there.
    expect(pluginMethodsFor(plugin), contains('composer.get'));
  });

  test('library and chats need their own permissions', () async {
    final none = service(const []);
    for (final m in ['characters.list', 'personas.get', 'chats.find']) {
      final out = await call(none, m, ['x']);
      expect((out['error'] as Map)['code'], 'permission_denied', reason: m);
    }
    // The open chat is part of `messages`, other chats of `chats.read`.
    final messages = service(const ['messages']);
    expect((await call(messages, 'chats.get', ['s1']))['ok'], true);
    final other = await call(messages, 'chats.get', ['elsewhere']);
    expect((other['error'] as Map)['code'], 'permission_denied');
    final context = await call(none, 'generate', [
      'hi',
      {'context': true},
    ]);
    expect((context['error'] as Map)['code'], 'permission_denied');
  });

  test('legacy "library" stands for every library and chat permission', () {
    final plugin = _plugin(const ['library']);
    for (final p in [
      'library.read.characters',
      'library.read.themes',
      'library.delete',
      'chats.update',
    ]) {
      expect(plugin.allows(p), isTrue, reason: p);
    }
  });

  test('legacy "library.read" stands for reading every kind', () {
    final plugin = _plugin(const ['library.read']);
    expect(plugin.manifest.permissions, PluginPermission.libraryReads);
    expect(plugin.allows('library.read'), isFalse);
  });

  test('library reading is allowed kind by kind', () async {
    final s = service(const ['library.read.personas']);
    final personas = await call(s, 'personas.list', []);
    expect(personas['ok'], isTrue, reason: '$personas');
    final characters = await call(s, 'characters.list', []);
    expect((characters['error'] as Map)['code'], 'permission_denied');
    expect(
      pluginMethodsFor(_plugin(const ['library.read.personas'])),
      allOf(contains('personas.list'), isNot(contains('characters.list'))),
    );
  });

  test('own and shared variables are separate permissions', () async {
    final own = service(const ['variables']);
    expect(
      (await call(own, 'variables.set', ['a', 1, 'global']))['ok'],
      isTrue,
    );
    final shared = await call(own, 'variables.set', ['a', 1, 'shared']);
    expect((shared['error'] as Map)['code'], 'permission_denied');

    final onlyShared = service(const ['variables.shared']);
    expect(
      (await call(onlyShared, 'variables.set', ['a', 1, 'shared']))['ok'],
      isTrue,
    );
    final chat = await call(onlyShared, 'variables.get', ['a']);
    expect((chat['error'] as Map)['code'], 'permission_denied');
    expect(
      pluginMethodsFor(_plugin(const ['variables.shared'])),
      contains('variables.get'),
    );
    expect(
      pluginMethodsFor(_plugin(const [])),
      isNot(contains('variables.get')),
    );
  });

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
      expect(host.varPushes.last, 'test.plugin/chat:{"status":{"hp":70}}');
      // Stored in the session row, separate from block variables.
      final stored = await ChatRepo(db).getById('s1');
      expect(
        stored!.sessionVars[PluginVariableStore.chatKeyFor('test.plugin')],
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

  test('each plugin has its own variables; shared is common', () async {
    final a = service(const ['variables', 'variables.shared']);
    await call(a, 'variables.set', ['token', 'secret']);
    await call(a, 'variables.set', ['token', 'secret', 'global']);
    await call(a, 'variables.set', ['hello', 'all', 'shared']);
    final other = await host.variables.read('other.plugin', 'chat', 's1');
    final otherGlobal = await host.variables.read(
      'other.plugin',
      'global',
      null,
    );
    final shared = await host.variables.read('other.plugin', 'shared', null);
    expect(other, isEmpty);
    expect(otherGlobal, isEmpty);
    expect(shared, {'hello': 'all'});
  });

  test("a plugin's chat variables can be forgotten", () async {
    final s = service(const ['variables']);
    await call(s, 'variables.set', ['token', 'secret']);
    await host.variables.update('keep.plugin', 'chat', 's1', (r) => r['a'] = 1);
    await host.variables.forgetPlugin('test.plugin');
    expect(await host.variables.read('test.plugin', 'chat', 's1'), isEmpty);
    expect(await host.variables.read('keep.plugin', 'chat', 's1'), {'a': 1});
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
    final s = service(const ['library.delete']);
    host.ui.answer = PluginConsentAnswer.always;
    await call(s, 'characters.remove', ['nope']);
    await call(s, 'characters.remove', ['nope']);
    expect(host.ui.consents, [
      'Test:library.delete:plugins_consent_character_remove',
    ]);
    expect(alwaysAllowed, ['test.plugin:library.delete']);

    final granted = service(
      const ['library.delete'],
      grants: const {'library.delete'},
    );
    host.ui.consents.clear();
    await call(granted, 'characters.remove', ['nope']);
    expect(host.ui.consents, isEmpty);
  });

  test('a denied plugin is not asked again', () async {
    final s = service(const ['library.delete']);
    host.ui.answer = PluginConsentAnswer.deny;
    final first = await call(s, 'characters.remove', ['nope']);
    expect((first['error'] as Map)['code'], 'permission_denied');
    expect(host.denials, ['plugins_consent_character_remove:silent']);
    final again = await call(s, 'characters.remove', ['nope']);
    expect((again['error'] as Map)['code'], 'permission_denied');
    expect(host.ui.consents, hasLength(1));
    expect(host.denials.last, 'plugins_consent_character_remove');

    // A dismissed sheet only refuses this call.
    final dismissed = service(const ['library.update']);
    host.ui.answer = null;
    final out = await call(dismissed, 'personas.update', [
      {'id': 'x'},
    ]);
    expect((out['error'] as Map)['code'], 'user_denied');
    // Noted, without telling the user what they just did.
    expect(host.denials.last, endsWith(':silent'));
  });

  test('the history notes what was let through and what was not', () async {
    final s = service(const ['variables']);
    await call(s, 'variables.get', ['a']);
    await call(s, 'variables.get', ['a', 'shared']);
    expect(host.grants, ['plugins_permission_name_variables']);
    expect(host.denials, ['plugins_permission_name_variables_shared']);

    host.ui.answer = PluginConsentAnswer.once;
    await call(service(const ['library.update']), 'personas.update', [
      {'id': 'x'},
    ]);
    expect(host.grants.last, startsWith('plugins_consent_'));
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

  test('files.list takes only the known scopes', () async {
    final s = service(const ['files']);
    for (final scope in [temp.path, '../..', 'chat/..']) {
      final out = await call(s, 'files.list', [
        {'scope': scope},
      ]);
      expect((out['error'] as Map)['code'], 'invalid_arguments', reason: scope);
    }
  });

  test('downloads stay off the local network unless allowed', () async {
    final s = service(const ['files', 'network']);
    for (final url in [
      'http://127.0.0.1:9/x',
      'http://localhost/x',
      'http://192.168.1.1/x',
      'http://[::1]/x',
      'http://printer.local/x',
    ]) {
      final out = await call(s, 'files.save', ['a.txt', url]);
      expect((out['error'] as Map)['code'], 'permission_denied', reason: url);
    }
    expect(host.network.every((e) => e.endsWith(':blocked')), isTrue);
  });

  test('local addresses are told apart from public ones', () {
    for (final a in [
      '127.0.0.1',
      '10.1.2.3',
      '172.16.0.1',
      '192.168.0.1',
      '169.254.1.1',
      '100.64.0.1',
      '0.0.0.0',
      '::1',
      'fd00::1',
      'fe80::1',
      '::ffff:192.168.0.1',
    ]) {
      expect(isLocalNetworkAddress(InternetAddress(a)), isTrue, reason: a);
    }
    for (final a in ['8.8.8.8', '172.32.0.1', '2001:4860:4860::8888']) {
      expect(isLocalNetworkAddress(InternetAddress(a)), isFalse, reason: a);
    }
  });

  test('storage shim persists per plugin', () async {
    final s = service(const []);
    await call(s, 'storage.set', {'key': 'a', 'value': '1'});
    await call(s, 'storage.set', {'key': 'b', 'value': '2'});
    await call(s, 'storage.remove', {'key': 'a'});
    expect(await host.files('test.plugin').readStorage(), {'b': '2'});
  });

  test('downloads through the app follow the internet setting', () async {
    final s = service(const ['files']);
    final out = await call(s, 'files.save', [
      'a.txt',
      'https://example.com/a.txt',
    ]);
    expect((out['error'] as Map)['code'], 'permission_denied');
    expect(host.network, ['example.com:blocked']);

    final listed = _plugin(
      const ['network'],
      networkHosts: const {'*.cdn.net', 'api.io'},
    );
    expect(listed.allowsHost('img.cdn.net'), isTrue);
    expect(listed.allowsHost('cdn.net'), isFalse);
    expect(listed.allowsHost('api.io'), isTrue);
    expect(listed.allowsHost('evil.io'), isFalse);
    expect(_plugin(const ['network']).allowsHost('anything.org'), isTrue);
    expect(
      _plugin(const ['network'], revoked: const {'network'}).allowsHost('a.io'),
      isFalse,
    );
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
