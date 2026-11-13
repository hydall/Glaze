import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/backup_exporter.dart';
import 'package:glaze_flutter/core/services/backup/flutter_backup_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';
import 'package:glaze_flutter/features/plugins/models/installed_plugin.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_manifest_parser.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_package_reader.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_snapshot.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

PluginPackage _package(
  String id, {
  String version = '1.0.0',
  String author = 'Example',
  List<String> permissions = const ['network'],
  String script = 'console.log(1)',
}) {
  final json = {
    'format': 1,
    'id': id,
    'name': id,
    'version': version,
    'main': 'main.js',
    'author': author,
    'permissions': permissions,
  };
  return PluginPackage(
    manifest: parsePluginManifest(json),
    files: {
      'plugin.json': utf8.encode(jsonEncode(json)),
      'main.js': utf8.encode(script),
    },
  );
}

Future<void> _write(String path, String content) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

/// Allows everything [plugin] asks for, with internet to any host.
Future<void> _allowAll(PluginStore store, InstalledPlugin plugin) => store.save(
  plugin.copyWith(
    grants: plugin.manifest.permissions.toSet(),
    revoked: const {},
    networkHosts: () => null,
  ),
);

Future<Map<String, dynamic>> _record(PluginStore store, String id) async =>
    (await store.readRecords()).firstWhere((r) => r['id'] == id);

void main() {
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('plugin_snapshot_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  PluginStore storeAt(String name) =>
      PluginStore.inAppData(p.join(temp.path, name));

  group('backup', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('carries packages and data, and restores them', () async {
      final base = p.join(temp.path, 'device');
      final store = PluginStore.inAppData(base);
      final installed = await store.install(_package('com.example.a'));
      await _allowAll(store, installed);
      await store.save(
        (await store.loadAll()).single.copyWith(config: {'mode': 'b'}),
      );
      final data = store.dataDir('com.example.a');
      await _write(p.join(data, 'storage.json'), '{"k":"v"}');
      await _write(p.join(data, 'variables.json'), '{"g":1}');
      await _write(p.join(data, 'files', 'global', 'notes.txt'), 'hello');
      await _write(p.join(data, 'files', 'chat', 's1', 'c.txt'), 'chat');
      await _write(p.join(data, 'files', 'tmp', 'scratch.txt'), 'gone');
      await _write(p.join(data, 'history.json'), '{}');
      await _write(p.join(store.dataRoot, '_shared_variables.json'), '{"s":2}');
      await Directory(p.join(store.root, '.staging-x')).create();
      await _write(p.join(store.root, '.staging-x', 'half.js'), 'x');

      final imageStorage = ImageStorageService(base);
      final archiveFile = await BackupExporter(
        db,
        imageStorage,
      ).buildArchive(temp);
      final names = ZipDecoder()
          .decodeStream(InputFileStream(archiveFile.path))
          .files
          .map((f) => f.name)
          .toSet();
      expect(
        names,
        containsAll([
          'plugins/registry.json',
          'plugins/com.example.a/plugin.json',
          'plugins/com.example.a/main.js',
          'plugin_data/com.example.a/storage.json',
          'plugin_data/com.example.a/variables.json',
          'plugin_data/com.example.a/files/global/notes.txt',
          'plugin_data/com.example.a/files/chat/s1/c.txt',
          'plugin_data/com.example.a/history.json',
          'plugin_data/_shared_variables.json',
        ]),
      );
      expect(names.where((n) => n.contains('tmp/')), isEmpty);
      expect(names.where((n) => n.contains('.staging-')), isEmpty);

      // Restore onto another device that has a plugin of its own.
      final otherBase = p.join(temp.path, 'other');
      final other = PluginStore.inAppData(otherBase);
      await other.install(_package('com.example.local'));
      await FlutterBackupImporter(
        db,
        ImageStorageService(otherBase),
      ).importFromZipFile(archiveFile.path);

      final plugins = await other.loadAll();
      expect(plugins.map((x) => x.id), ['com.example.a']);
      final restored = plugins.single;
      expect(restored.config, {'mode': 'b'});
      // New on this device: nothing allowed, as after a fresh install.
      expect(restored.grants, isEmpty);
      expect(restored.revoked, contains('network'));
      expect(restored.networkHosts, isEmpty);
      final otherData = other.dataDir('com.example.a');
      expect(
        await File(
          p.join(otherData, 'files', 'global', 'notes.txt'),
        ).readAsString(),
        'hello',
      );
      expect(
        await File(p.join(otherData, 'storage.json')).readAsString(),
        '{"k":"v"}',
      );
      expect(
        await File(
          p.join(other.dataRoot, '_shared_variables.json'),
        ).readAsString(),
        '{"s":2}',
      );
    });

    test('a plugin the device had keeps its permissions', () async {
      final base = p.join(temp.path, 'device');
      final store = PluginStore.inAppData(base);
      await store.install(_package('com.example.a'));
      final archiveFile = await BackupExporter(
        db,
        ImageStorageService(base),
      ).buildArchive(temp);

      // Allowed after the backup was made.
      await _allowAll(store, (await store.loadAll()).single);
      await FlutterBackupImporter(
        db,
        ImageStorageService(base),
      ).importFromZipFile(archiveFile.path);

      final restored = (await store.loadAll()).single;
      expect(restored.grants, contains('network'));
      expect(restored.revoked, isEmpty);
      expect(restored.networkHosts, isNull);
    });

    test('an archive without plugins leaves them alone', () async {
      final base = p.join(temp.path, 'device');
      final store = PluginStore.inAppData(base);
      await store.install(_package('com.example.a'));
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(jsonEncode({'schemaVersion': 14})),
          ),
        );
      final path = p.join(temp.path, 'old.glz');
      await File(path).writeAsBytes(ZipEncoder().encode(archive));
      await FlutterBackupImporter(
        db,
        ImageStorageService(base),
      ).importFromZipFile(path);
      expect((await store.loadAll()).map((x) => x.id), ['com.example.a']);
    });

    test('ignores entries that point outside the plugin folders', () {
      final snapshot = PluginSnapshot(storeAt('device'));
      expect(snapshot.backupTarget('plugins/../evil.js'), isNull);
      expect(snapshot.backupTarget('plugin_data/a/../../x'), isNull);
      expect(snapshot.backupTarget('avatars/x.png'), isNull);
      expect(
        snapshot.backupTarget('plugins/a/main.js'),
        p.join(temp.path, 'device', 'plugins', 'a', 'main.js'),
      );
    });
  });

  group('sync', () {
    late PluginStore a;
    late PluginStore b;
    late PluginSnapshot snapA;
    late PluginSnapshot snapB;

    setUp(() {
      a = storeAt('a');
      b = storeAt('b');
      snapA = PluginSnapshot(a);
      snapB = PluginSnapshot(b);
    });

    Future<void> pushAToB() async {
      final payload = jsonDecode(jsonEncode(await snapA.syncPayload()));
      await snapB.applySync(payload as Map<String, dynamic>, snapA.pack);
    }

    test('payload leaves permissions out', () async {
      await _allowAll(a, await a.install(_package('com.example.a')));
      final payload = await snapA.syncPayload();
      final record =
          ((payload['items'] as List).single as Map)['record'] as Map;
      expect(record['id'], 'com.example.a');
      for (final key in [
        'grants',
        'revoked',
        'networkHosts',
        'blockedHosts',
        'localNetwork',
      ]) {
        expect(record.containsKey(key), isFalse, reason: key);
      }
    });

    test('installs, updates and removes plugins on the other device', () async {
      await _allowAll(a, await a.install(_package('com.example.a')));
      await a.install(_package('com.example.b'));
      await _write(p.join(a.dataDir('com.example.a'), 'storage.json'), '{}');
      await _write(p.join(a.dataDir('com.example.a'), 'network.json'), 'A');
      await _write(p.join(a.dataRoot, '_shared_variables.json'), '{"s":1}');
      await b.install(_package('com.example.only_b'));

      await pushAToB();
      var onB = await b.loadAll();
      expect(onB.map((x) => x.id), ['com.example.a', 'com.example.b']);
      // Arrived from another device: nothing allowed yet.
      expect(onB.first.grants, isEmpty);
      expect(onB.first.revoked, contains('network'));
      // The other device's logs stay there.
      expect(
        await File(p.join(b.dataDir('com.example.a'), 'network.json')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(b.dataRoot, '_shared_variables.json')).readAsString(),
        '{"s":1}',
      );
      // Both devices now describe the plugins the same way.
      expect(
        jsonEncode(await snapB.syncPayload()),
        jsonEncode(await snapA.syncPayload()),
      );

      // Allowed on B; then A updates the plugin's data and removes one.
      await _allowAll(b, onB.first);
      await _write(p.join(b.dataDir('com.example.a'), 'history.json'), 'B');
      await _write(
        p.join(a.dataDir('com.example.a'), 'files', 'global', 'n.txt'),
        'new',
      );
      await a.uninstall('com.example.b');
      await pushAToB();

      onB = await b.loadAll();
      expect(onB.map((x) => x.id), ['com.example.a']);
      expect(onB.single.grants, contains('network'));
      expect(onB.single.networkHosts, isNull);
      final dataB = b.dataDir('com.example.a');
      expect(
        await File(p.join(dataB, 'files', 'global', 'n.txt')).readAsString(),
        'new',
      );
      expect(await File(p.join(dataB, 'history.json')).readAsString(), 'B');
      expect(await Directory(b.packageDir('com.example.b')).exists(), isFalse);
    });

    test('does not download a plugin whose files match', () async {
      await a.install(_package('com.example.a'));
      await pushAToB();
      final payload = jsonDecode(jsonEncode(await snapA.syncPayload()));
      await snapB.applySync(
        payload as Map<String, dynamic>,
        (_) => throw StateError('downloaded'),
      );
      expect((await b.loadAll()).map((x) => x.id), ['com.example.a']);
    });

    test('a failed download changes nothing', () async {
      await a.install(_package('com.example.a'));
      await b.install(_package('com.example.only_b'));
      final payload = jsonDecode(jsonEncode(await snapA.syncPayload()));
      await expectLater(
        snapB.applySync(
          payload as Map<String, dynamic>,
          (_) => throw StateError('offline'),
        ),
        throwsStateError,
      );
      expect((await b.loadAll()).map((x) => x.id), ['com.example.only_b']);
    });

    test('a newly asked permission arrives switched off', () async {
      await _allowAll(b, await b.install(_package('com.example.a')));
      await a.install(
        _package(
          'com.example.a',
          version: '1.1.0',
          permissions: ['network', 'composer'],
        ),
      );
      await pushAToB();
      final onB = (await b.loadAll()).single;
      expect(onB.grants, contains('network'));
      expect(onB.revoked, contains('composer'));
      expect(onB.revoked, isNot(contains('network')));
      expect((await _record(b, 'com.example.a'))['networkHosts'], isNull);
    });
  });
}
