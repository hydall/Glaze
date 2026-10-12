import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/features/chat/composer_text_bridge.dart';
import 'package:glaze_flutter/features/plugins/models/installed_plugin.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_html_inliner.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_message_diff.dart';
import 'package:glaze_flutter/features/plugins/runtime/tavo_bridge_service.dart';
import 'package:glaze_flutter/features/plugins/runtime/tavo_file_store.dart';
import 'package:glaze_flutter/features/plugins/runtime/tavo_host.dart';
import 'package:glaze_flutter/features/plugins/runtime/tavo_variable_store.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_manifest_parser.dart';

class _FakeHost implements TavoHost {
  _FakeHost(this.variables, this.dataRoot, this.session);

  @override
  final TavoVariableStore variables;
  final String dataRoot;
  ChatSession session;
  String composerText = '';
  final toasts = <String>[];
  final varPushes = <String>[];

  @override
  String get charId => 'char';
  @override
  String? get sessionId => session.id;
  @override
  ChatSession? currentSession() => session;
  @override
  Character? currentCharacter() => const Character(id: 'char', name: 'Alice');
  @override
  Future<List<Character>> characters() async => [currentCharacter()!];
  @override
  Persona? currentPersona() => const Persona(id: 'p', name: 'Bob');
  @override
  Future<List<Persona>> personas() async => [currentPersona()!];
  @override
  ComposerTextAccess? composer() => ComposerTextAccess(
    read: () => composerText,
    write: (t) => composerText = t,
    send: () async => true,
  );
  @override
  void toast(String text) => toasts.add(text);
  @override
  Future<void> openUrl(String url) async {}
  @override
  Future<String?> select(
    List<TavoOption> options, {
    String? title,
    String? defaultValue,
  }) async => options.first.value;
  @override
  Future<Map<String, Object?>> ask({
    required String question,
    required List<TavoOption> options,
    required bool allowOther,
    String? placeholder,
    String? defaultValue,
  }) async => {'status': 'cancelled'};
  @override
  Future<String> generate(String prompt, Map<String, dynamic> options) async =>
      'generated:$prompt';
  @override
  TavoFileStore files(String pluginId) =>
      TavoFileStore(dataDir: '$dataRoot/$pluginId');
  @override
  void variablesChanged(String scope, Map<String, dynamic> root) =>
      varPushes.add('$scope:${jsonEncode(root)}');
}

InstalledPlugin _plugin(List<String> permissions) => InstalledPlugin(
  manifest: parsePluginManifest({
    'id': 'test.plugin',
    'name': 'Test',
    'version': '1',
    'permissions': permissions,
  }),
  directory: '/nowhere',
  enabled: true,
  installedAt: 0,
);

void main() {
  late AppDatabase db;
  late Directory temp;
  late _FakeHost host;

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
    temp = await Directory.systemTemp.createTemp('tavo_bridge_test');
    final chatRepo = ChatRepo(db);
    await chatRepo.put(session);
    host = _FakeHost(
      TavoVariableStore(
        chatRepo: chatRepo,
        globalFile: File('${temp.path}/globals.json'),
      ),
      temp.path,
      session,
    );
  });

  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  TavoBridgeService service(List<String> permissions) {
    final plugin = _plugin(permissions);
    return TavoBridgeService(
      host: host,
      pluginById: (id) => id == plugin.id ? plugin : null,
    );
  }

  Future<Map<String, dynamic>> call(
    TavoBridgeService s,
    String method, [
    Object? params,
    String pluginId = 'test.plugin',
  ]) => s.dispatch({'pluginId': pluginId, 'method': method, 'params': params});

  test(
    'denies methods the manifest does not grant, and unknown plugins',
    () async {
      final s = service(const []);
      final denied = await call(s, 'variable.get', {'name': 'x'});
      expect(denied['ok'], false);
      expect((denied['error'] as Map)['code'], 'permission_denied');
      final unknown = await call(s, 'utils.toast', ['hi'], 'other.plugin');
      expect((unknown['error'] as Map)['code'], 'permission_denied');
      final ok = await call(s, 'utils.toast', ['hi']);
      expect(ok['ok'], true);
      expect(host.toasts, ['hi']);
      expect(tavoMethodsFor(_plugin(const [])), isNot(contains('input.get')));
    },
  );

  test(
    'chat variables: dotted paths, update merges, unset, sync push',
    () async {
      final s = service(const ['variable']);
      await call(s, 'variable.set', {
        'name': 'status',
        'value': {'hp': 100, 'mp': 32},
        'scope': 'chat',
      });
      await call(s, 'variable.update', {
        'name': 'status',
        'value': {'hp': 70},
      });
      final hp = await call(s, 'variable.get', {'name': 'status.hp'});
      expect(hp['result'], 70);
      final all = await call(s, 'variable.list', {'scope': 'chat'});
      expect(all['result'], {
        'status': {'hp': 70, 'mp': 32},
      });
      final removed = await call(s, 'variable.unset', {'name': 'status.mp'});
      expect(removed['result'], true);
      expect(host.varPushes.last, 'chat:{"status":{"hp":70}}');
      // Stored in the session row, separate from glaze.* variables.
      final stored = await ChatRepo(db).getById('s1');
      expect(
        stored!.sessionVars[TavoVariableStore.chatKey],
        contains('"hp":70'),
      );
    },
  );

  test('global variables live outside the chat', () async {
    final s = service(const ['variable']);
    await call(s, 'variable.set', {
      'name': 'best',
      'value': 3,
      'scope': 'global',
    });
    final chat = await call(s, 'variable.get', {'name': 'best'});
    final global = await call(s, 'variable.get', {
      'name': 'best',
      'scope': 'global',
    });
    expect(chat['result'], isNull);
    expect(global['result'], 3);
  });

  test('message reads: ranges, negative indices, filters', () async {
    final s = service(const ['message']);
    expect((await call(s, 'message.count'))['result'], 3);
    final last = await call(s, 'message.find', [-1]);
    expect((last['result'] as List).single['id'], 'm3');
    final visibleAssistant = await call(s, 'message.find', [
      [0, -1],
      {'role': 'assistant', 'hidden': false},
    ]);
    expect((visibleAssistant['result'] as List).map((m) => m['id']), [
      'm1',
      'm3',
    ]);
    final byIndex = await call(s, 'message.get', [
      {'index': -2},
    ]);
    expect((byIndex['result'] as Map)['content'], 'Hello');
    expect((await call(s, 'message.get', ['nope']))['result'], isNull);
  });

  test('input and generation go through the host', () async {
    final s = service(const ['input', 'generate']);
    await call(s, 'input.set', ['draft']);
    await call(s, 'input.append', [' more']);
    expect((await call(s, 'input.get'))['result'], 'draft more');
    final sent = await call(s, 'input.send');
    expect(sent['result'], {'ok': true, 'text': 'draft more'});
    final gen = await call(s, 'generate', ['hi', {}]);
    expect(gen['result'], 'generated:hi');
  });

  test('files stay inside the plugin folder', () async {
    final s = service(const ['file']);
    final path = await call(s, 'file.save', ['note.txt', 'hello']);
    expect(path['result'], 'files/chat/note.txt');
    final loaded = await call(s, 'file.load', ['files/chat/note.txt']);
    expect(loaded['result'], 'hello');
    final escape = await call(s, 'file.save', ['../x.txt', 'bad']);
    expect((escape['error'] as Map)['code'], 'invalid_arguments');
    final listed = await call(s, 'file.list', [
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
