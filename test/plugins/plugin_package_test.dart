import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/plugins/compat/tavo/tavo_manifest_converter.dart';
import 'package:glaze_flutter/features/plugins/models/plugin_manifest.dart';
import 'package:glaze_flutter/features/plugins/models/plugin_settings_schema.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_file_store.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_compatibility.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_localizer.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_manifest_parser.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_package_reader.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_store.dart';

Map<String, dynamic> manifest([Map<String, dynamic> extra = const {}]) => {
  'format': 1,
  'id': 'Com.Example.Note',
  'name': {'t': 'plugin.name'},
  'version': '1.0.0',
  'main': 'main.js',
  'author': 'Example',
  'description': 'A note plugin.',
  'locales': {
    'default': 'en',
    'files': {'en': 'locales/en.json', 'ru': 'locales/ru.json'},
  },
  'permissions': ['composer'],
  'contributes': {
    'composerActions': [
      {'id': 'note', 'label': 'Note'},
    ],
    'panels': [
      {'id': 'panel', 'src': 'ui/panel.html', 'placement': 'chat'},
    ],
    'settings': [
      {'type': 'note', 'text': 'Hello', 'icon': 'warning'},
      {'key': 'on', 'type': 'toggle', 'label': 'On', 'default': true},
      {
        'key': 'mode',
        'type': 'select',
        'label': 'Mode',
        'options': [
          'a',
          {'value': 'b', 'label': 'Bee'},
        ],
      },
      {'type': 'group'},
      {
        'key': 'strength',
        'type': 'slider',
        'label': 'Strength',
        'min': 0,
        'max': 1,
        'step': 0.1,
      },
    ],
  },
  ...extra,
};

Map<String, dynamic> tavoManifest([Map<String, dynamic> extra = const {}]) => {
  'specVersion': 2,
  'id': 'Com.Example.Note',
  'name': {r'$t': 'plugin.name'},
  'version': '1.0.0',
  'entry': 'main.js',
  'author': 'Example',
  'description': 'A note plugin.',
  'localization': {
    'defaultLocale': 'en',
    'resources': {'en': 'locales/en.json', 'ru': 'locales/ru.json'},
  },
  'permissions': ['input', 'variable', 'tts'],
  'contributes': {
    'inputActions': [
      {'id': 'note', 'label': 'Note'},
    ],
    'sidebar': [
      {'id': 'open', 'label': 'Open'},
    ],
    'htmlFragments': [
      {'id': 'panel', 'src': 'ui/panel.html', 'mount': '/chat/body/end'},
      {
        'id': 'badge',
        'src': 'ui/panel.html',
        'mount': '/messages/start?role=character&position=last',
      },
    ],
    'settings': {
      'schema': [
        {'type': 'info', 'text': 'Hello'},
        {'key': 'on', 'type': 'switch', 'label': 'On', 'default': true},
        {'type': 'break'},
      ],
    },
  },
  ...extra,
};

Uint8List zip(Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile.string(e.key, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, String> packageFiles({
  String manifestFile = 'plugin.json',
  Map<String, dynamic>? m,
  String main = 'glaze.plugin.on("action:composer:note", () => {});',
}) => {
  manifestFile: jsonEncode(
    m ?? (manifestFile == 'plugin.json' ? manifest() : tavoManifest()),
  ),
  'main.js': main,
  'ui/panel.html': '<div>panel</div>',
  'locales/en.json': jsonEncode({'plugin.name': 'Quick Note'}),
  'locales/ru.json': jsonEncode({'plugin.name': 'Заметка'}),
};

Matcher fails(String text) => throwsA(
  isA<PluginManifestException>().having(
    (e) => e.message,
    'message',
    contains(text),
  ),
);

void main() {
  group('parsePluginManifest', () {
    test('reads plugin.json and normalizes the id', () {
      final m = parsePluginManifest(manifest());
      expect(m.id, 'com.example.note');
      expect(m.name.key, 'plugin.name');
      expect(m.composerActions.single.id, 'note');
      expect(m.panels.single.placement, PluginPanelPlacement.chat);
      expect(m.panels.single.slot, 'end');
      expect(m.settings.map((f) => f.type), [
        PluginSettingType.note,
        PluginSettingType.toggle,
        PluginSettingType.select,
        PluginSettingType.group,
        PluginSettingType.slider,
      ]);
      expect(m.settings[2].options.map((o) => o.value), ['a', 'b']);
    });

    test('rejects invalid manifests', () {
      expect(
        () => parsePluginManifest(manifest({'id': 'bad id'})),
        fails('id'),
      );
      expect(
        () => parsePluginManifest(manifest({'format': 2})),
        fails('newer'),
      );
      expect(
        () => parsePluginManifest(manifest({'version': '1.0'})),
        fails('SemVer'),
      );
      expect(
        () => parsePluginManifest(manifest({'main': '../x.js'})),
        fails('safe package path'),
      );
      expect(
        () => parsePluginManifest(manifest({'main': null})),
        fails('main script'),
      );
      expect(
        () => parsePluginManifest(
          manifest({
            'contributes': {
              'panels': [
                {'id': 'p', 'src': 'p.html', 'placement': 'side'},
              ],
            },
          }),
        ),
        fails('placement'),
      );
    });
  });

  group('hosts', () {
    test('are normalized and checked', () {
      final m = parsePluginManifest(
        manifest({
          'hosts': ['API.Example.com', 'https://cdn.io/x', '*.img.net'],
        }),
      );
      expect(m.hosts, ['api.example.com', 'cdn.io', '*.img.net']);
      expect(
        () => parsePluginManifest(
          manifest({
            'hosts': ['not a host'],
          }),
        ),
        fails('hosts'),
      );
      expect(normalizePluginHost('*.*.x.com'), isNull);
    });
  });

  group('convertTavoManifest', () {
    test('maps fields, permissions, mounts and settings', () {
      final out = convertTavoManifest(tavoManifest());
      final m = parsePluginManifest(out);
      expect(m.compat, kTavoCompat);
      expect(m.main, 'main.js');
      expect(m.name.key, 'plugin.name');
      expect(m.defaultLocale, 'en');
      expect(
        m.permissions,
        containsAll(['composer', 'variables', 'tts', 'library', 'images']),
      );
      expect(m.composerActions.single.id, 'note');
      expect(m.toolsActions.single.id, 'open');
      final badge = m.panels.last;
      expect(badge.placement, PluginPanelPlacement.message);
      expect(badge.slot, 'start');
      expect(badge.role, 'character');
      expect(badge.position, 'last');
      expect(m.settings.map((f) => f.type), [
        PluginSettingType.note,
        PluginSettingType.toggle,
        PluginSettingType.group,
      ]);
    });

    test('keeps the loose v1 rules', () {
      final m = parsePluginManifest(
        convertTavoManifest({
          'id': 'old.plugin',
          'name': 'Old',
          'version': 'beta',
          'scripts': {'actions': 'actions.js'},
          'contributes': {
            'sidebar': [
              {'id': 'go', 'label': 'Go'},
            ],
          },
        }),
      );
      expect(m.version, 'beta');
      expect(m.main, 'actions.js');
    });

    test('rejects what Tavo rejects', () {
      expect(
        () => convertTavoManifest(tavoManifest({'specVersion': 3})),
        fails('specVersion'),
      );
      expect(
        () => convertTavoManifest(tavoManifest({'localization': null})),
        fails('localization'),
      );
      expect(
        () => convertTavoManifest(
          tavoManifest({
            'contributes': {
              'htmlFragments': [
                {'id': 'x', 'src': 'ui/panel.html', 'mount': '/side/end'},
              ],
            },
          }),
        ),
        fails('mount'),
      );
    });
  });

  group('readPluginPackage', () {
    test('reads a package and accepts a single wrapping folder', () {
      final flat = readPluginPackage(zip(packageFiles()));
      expect(flat.files.keys, contains('ui/panel.html'));
      final nested = readPluginPackage(
        zip({for (final e in packageFiles().entries) 'note/${e.key}': e.value}),
      );
      expect(nested.manifest.id, 'com.example.note');
      expect(nested.files.keys, contains('main.js'));
    });

    test('converts a Tavo package and stores plugin.json', () {
      final package = readPluginPackage(
        zip(packageFiles(manifestFile: 'manifest.json')),
      );
      expect(package.manifest.compat, kTavoCompat);
      final stored = jsonDecode(utf8.decode(package.files['plugin.json']!));
      expect(stored['format'], kPluginManifestFormat);
      expect(stored['compat'], 'tavo');
    });

    test('rejects missing files and unsafe paths', () {
      final missing = packageFiles()..remove('main.js');
      expect(() => readPluginPackage(zip(missing)), fails('main'));
      expect(
        () => readPluginPackage(zip({...packageFiles(), '../evil.js': 'x'})),
        throwsA(isA<PluginManifestException>()),
      );
      expect(
        () => readPluginPackage(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<PluginManifestException>()),
      );
    });

    test('refuses an archive that declares too much before inflating', () {
      final archive = Archive();
      for (final e in packageFiles().entries) {
        archive.addFile(ArchiveFile.string(e.key, e.value));
      }
      // Highly compressible: small on disk, past the cap once inflated.
      archive.addFile(
        ArchiveFile(
          'big.bin',
          kMaxPluginPackageBytes + 1,
          Uint8List(kMaxPluginPackageBytes + 1),
        ),
      );
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      expect(bytes.length, lessThan(kMaxPluginPackageBytes ~/ 100));
      expect(() => readPluginPackage(bytes), fails('too large'));
    });
  });

  group('PluginStore.install', () {
    late Directory temp;
    late PluginStore store;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('plugin_store_test');
      store = PluginStore(root: '${temp.path}/p', dataRoot: '${temp.path}/d');
    });

    tearDown(() => temp.delete(recursive: true));

    PluginPackage package(List<String> permissions) => readPluginPackage(
      zip(
        packageFiles(
          m: manifest({
            'permissions': permissions,
            'hosts': ['api.example.com'],
          }),
        ),
      ),
    );

    test('a fresh install starts with every permission off', () async {
      final installed = await store.install(
        package(['composer', 'network', 'library']),
      );
      expect(installed.revoked, {'composer', 'network', 'library'});
      expect(installed.networkHosts, isEmpty);
      expect(installed.localNetwork, isFalse);
      expect(installed.allowsHost('api.example.com'), isFalse);
    });

    test('an update switches off only what is new', () async {
      final first = await store.install(package(['composer']));
      await store.save(
        first.copyWith(revoked: const {}, config: const {'on': false}),
      );
      final updated = await store.install(package(['composer', 'network']));
      expect(updated.revoked, {'network'});
      expect(updated.config, {'on': false});
      expect(updated.networkHosts, isEmpty);
    });

    test('chat files go with the chat', () async {
      final installed = await store.install(package(const []));
      final files = PluginFileStore(dataDir: store.dataDir(installed.id));
      final chat = files.resolve('a.txt', sessionId: 'c_1');
      final global = files.resolve('a.txt', scope: 'global', sessionId: null);
      for (final f in [chat.file, global.file]) {
        await f.parent.create(recursive: true);
        await f.writeAsString('x');
      }
      await store.deleteChatFiles('c_1');
      expect(await chat.file.exists(), isFalse);
      expect(await global.file.exists(), isTrue);
    });
  });

  group('unsupportedPluginFeatures', () {
    test('flags TTS by permission or by script use', () {
      final byPermission = readPluginPackage(
        zip(packageFiles(manifestFile: 'manifest.json')),
      );
      expect(unsupportedPluginFeatures(byPermission), {
        UnsupportedPluginFeature.tts,
      });
      final byScript = readPluginPackage(
        zip(packageFiles(main: 'await tavo.tts.speak("hi");')),
      );
      expect(unsupportedPluginFeatures(byScript), {
        UnsupportedPluginFeature.tts,
      });
      expect(
        unsupportedPluginFeatures(readPluginPackage(zip(packageFiles()))),
        isEmpty,
      );
    });
  });

  group('PluginLocalizer', () {
    final catalogs = {
      'en': {'a': 'A', 'only.en': 'E'},
      'zh-CN': {'a': '甲'},
      'ru': {'a': 'А'},
    };

    test('follows requested → same language → en → default → key', () {
      final zh = PluginLocalizer(
        catalogs: catalogs,
        defaultLocale: 'ru',
        requestedLocale: 'zh-TW',
      );
      expect(zh.t('a'), '甲');
      expect(zh.t('only.en'), 'E');
      expect(zh.t('missing'), 'missing');
      final de = PluginLocalizer(
        catalogs: {'ru': catalogs['ru']!},
        defaultLocale: 'ru',
        requestedLocale: 'de',
      );
      expect(de.t('a'), 'А');
    });

    test('runtime snapshot prefers the requested locale', () {
      final ru = PluginLocalizer(
        catalogs: catalogs,
        defaultLocale: 'en',
        requestedLocale: 'ru',
      );
      final snapshot = ru.runtimeSnapshot();
      expect(snapshot['locale'], 'ru');
      expect((snapshot['messages'] as Map)['a'], 'А');
      expect((snapshot['messages'] as Map)['only.en'], 'E');
    });
  });
}
