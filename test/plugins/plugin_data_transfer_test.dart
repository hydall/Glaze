import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/plugins/models/installed_plugin.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_file_store.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_variable_store.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_data_transfer.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_manifest_parser.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_store.dart';

InstalledPlugin _plugin(String id, {Map<String, Object?> config = const {}}) =>
    InstalledPlugin(
      manifest: parsePluginManifest({
        'format': 1,
        'id': id,
        'name': 'Test',
        'version': '1.2.3',
        'contributes': {
          'settings': [
            {'type': 'toggle', 'key': 'on', 'label': 'On'},
            {'type': 'apiPreset', 'key': 'summary', 'label': 'Summary'},
          ],
        },
      }),
      config: config,
      directory: '/nowhere',
      enabled: true,
      installedAt: 0,
    );

void main() {
  late AppDatabase db;
  late Directory temp;
  late PluginStore store;
  late PluginVariableStore variables;
  late PluginDataTransfer transfer;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    temp = await Directory.systemTemp.createTemp('plugin_data_test');
    final chatRepo = ChatRepo(db);
    for (final id in ['s1', 's2']) {
      await chatRepo.put(
        ChatSession(id: id, characterId: 'char', sessionIndex: 0),
      );
    }
    store = PluginStore(
      root: '${temp.path}/plugins',
      dataRoot: '${temp.path}/data',
    );
    variables = PluginVariableStore(
      chatRepo: chatRepo,
      globalFile: (id) => File('${store.dataDir(id)}/variables.json'),
      sharedFile: File('${temp.path}/data/_shared_variables.json'),
    );
    transfer = PluginDataTransfer(store: store, variables: variables);
  });

  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  Future<void> seed(String id, String tag) async {
    final files = PluginFileStore(dataDir: store.dataDir(id));
    await files.updateStorage((s) => s['notes'] = '[$tag]');
    await variables.update(id, 'global', null, (r) => r['tag'] = tag);
    await variables.update(id, 'chat', 's1', (r) => r['mood'] = tag);
    await variables.update(
      id,
      'message',
      's1',
      (r) => r['seen'] = true,
      messageId: 'm1',
    );
    for (final (scope, name) in [('global', 'a.png'), ('tmp', 'x.bin')]) {
      final f = files.resolve(name, scope: scope, sessionId: null).file;
      await f.parent.create(recursive: true);
      await f.writeAsBytes(utf8.encode('$tag-$name'));
    }
    final c = files.resolve('c.txt', scope: 'chat', sessionId: 's1').file;
    await c.parent.create(recursive: true);
    await c.writeAsString('$tag-chat');
  }

  test(
    'a plugin\'s data goes out as JSON and comes back in its place',
    () async {
      final plugin = _plugin(
        'a.b',
        config: {
          'on': true,
          'summary': {'api': 'cheap'},
        },
      );
      await seed('a.b', 'old');
      final out = await transfer.export(plugin);
      // Through text, as the file goes.
      final file = jsonDecode(jsonEncode(out)) as Map<String, dynamic>;
      expect(file['format'], kPluginDataFormat);
      expect(file['plugin'], {'id': 'a.b', 'version': '1.2.3'});
      expect(file['settings'], {
        'on': true,
        'summary': {'api': 'cheap'},
      });
      expect(file['storage'], {'notes': '[old]'});
      expect(file['variables'], {
        'global': {'tag': 'old'},
        'chats': {
          's1': {
            'chat': {'mood': 'old'},
            'messages': {
              'm1': {'seen': true},
            },
          },
        },
      });
      expect((file['files'] as Map).keys.toSet(), {
        'global/a.png',
        'chat/s1/c.txt',
      });

      // Something else moved in since; the import puts the file's back,
      // drops what the file does not have and skips a chat this device lacks.
      await seed('a.b', 'new');
      await variables.update('a.b', 'chat', 's2', (r) => r['extra'] = 1);
      final f = PluginFileStore(dataDir: store.dataDir('a.b'));
      await f
          .resolve('b.png', scope: 'global', sessionId: null)
          .file
          .writeAsString('stray');
      (file['variables']['chats'] as Map)['gone'] = {
        'chat': {'x': 1},
      };
      (file['settings'] as Map)['undeclared'] = 1;

      final result = await transfer.import(plugin, file);
      expect(result.skippedChats, 1);
      expect(result.config, {
        'on': true,
        'summary': {'api': 'cheap'},
      });
      expect(await f.readStorage(), {'notes': '[old]'});
      expect(await variables.read('a.b', 'global', null), {'tag': 'old'});
      expect(await variables.read('a.b', 'chat', 's1'), {'mood': 'old'});
      expect(await variables.read('a.b', 'chat', 's2'), isEmpty);
      expect(await variables.read('a.b', 'message', 's1', messageId: 'm1'), {
        'seen': true,
      });
      String read(String name, String scope, String? session) => f
          .resolve(name, scope: scope, sessionId: session)
          .file
          .readAsStringSync();
      expect(read('a.png', 'global', null), 'old-a.png');
      expect(read('c.txt', 'chat', 's1'), 'old-chat');
      expect(
        f.resolve('b.png', scope: 'global', sessionId: null).file.existsSync(),
        isFalse,
      );
    },
  );

  test('a file that is not this plugin\'s data changes nothing', () async {
    final plugin = _plugin('a.b');
    await seed('a.b', 'mine');
    await seed('c.d', 'theirs');
    final theirs = await transfer.export(_plugin('c.d'));
    Future<PluginDataError?> fails(Object? json) async {
      try {
        await transfer.import(plugin, json);
        return null;
      } on PluginDataException catch (e) {
        return e.error;
      }
    }

    expect(await fails(theirs), PluginDataError.otherPlugin);
    expect(await fails({'hello': 1}), PluginDataError.notPluginData);
    final mine = await transfer.export(plugin);
    expect(await fails({...mine, 'version': 99}), PluginDataError.newerVersion);
    expect(
      await fails({
        ...mine,
        'files': {
          '../../escape.txt': base64Encode([1]),
        },
      }),
      PluginDataError.notPluginData,
    );
    expect(
      await fails({
        ...mine,
        'storage': {'big': 'x' * (PluginFileStore.maxStorageBytes + 1)},
      }),
      PluginDataError.tooBig,
    );
    expect(await variables.read('a.b', 'global', null), {'tag': 'mine'});
    expect(await PluginFileStore(dataDir: store.dataDir('a.b')).readStorage(), {
      'notes': '[mine]',
    });
  });
}
