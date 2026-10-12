import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/plugins/models/plugin_manifest.dart';
import 'package:glaze_flutter/features/plugins/models/plugin_settings_schema.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_localizer.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_manifest_parser.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_package_reader.dart';

Map<String, dynamic> manifest([Map<String, dynamic> extra = const {}]) => {
  'specVersion': 2,
  'id': 'Com.Example.Note',
  'name': {r'$t': 'plugin.name'},
  'version': '1.0.0',
  'entry': 'entry.js',
  'author': 'Example',
  'description': 'A note plugin.',
  'localization': {
    'defaultLocale': 'en',
    'resources': {'en': 'locales/en.json', 'ru': 'locales/ru.json'},
  },
  'permissions': ['input'],
  'contributes': {
    'inputActions': [
      {'id': 'note', 'label': 'Note'},
    ],
    'htmlFragments': [
      {'id': 'panel', 'src': 'ui/panel.html', 'mount': '/chat/body/end'},
    ],
    'settings': {
      'schema': [
        {'type': 'info', 'text': 'Hello', 'icon': 'warning'},
        {'key': 'on', 'type': 'switch', 'label': 'On', 'default': true},
        {
          'key': 'mode',
          'type': 'select',
          'label': 'Mode',
          'options': [
            'a',
            {'value': 'b', 'label': 'Bee'},
          ],
        },
        {'type': 'break'},
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

Map<String, String> packageFiles([Map<String, dynamic>? m]) => {
  'manifest.json': jsonEncode(m ?? manifest()),
  'entry.js': 'tavo.plugin.onInputAction("note", () => {});',
  'ui/panel.html': '<div>panel</div>',
  'locales/en.json': jsonEncode({'plugin.name': 'Quick Note'}),
  'locales/ru.json': jsonEncode({'plugin.name': 'Заметка'}),
};

void main() {
  group('parsePluginManifest', () {
    test('reads a v2 manifest and normalizes the id', () {
      final m = parsePluginManifest(manifest());
      expect(m.id, 'com.example.note');
      expect(m.name.key, 'plugin.name');
      expect(m.inputActions.single.id, 'note');
      expect(m.fragments.single.mount.surface, PluginMountSurface.chat);
      expect(m.fragments.single.mount.slot, 'end');
      expect(m.settings.map((f) => f.type), [
        PluginSettingType.info,
        PluginSettingType.toggle,
        PluginSettingType.select,
        PluginSettingType.sectionBreak,
        PluginSettingType.slider,
      ]);
      expect(m.settings[2].options.map((o) => o.value), ['a', 'b']);
    });

    test('rejects what Tavo rejects', () {
      Matcher fails(String text) => throwsA(
        isA<PluginManifestException>().having(
          (e) => e.message,
          'message',
          contains(text),
        ),
      );
      expect(
        () => parsePluginManifest(manifest({'id': 'bad id'})),
        fails('id'),
      );
      expect(
        () => parsePluginManifest(manifest({'specVersion': 3})),
        fails('newer'),
      );
      expect(
        () => parsePluginManifest(manifest({'version': '1.0'})),
        fails('SemVer'),
      );
      expect(
        () => parsePluginManifest(manifest({'entry': '../x.js'})),
        fails('safe path'),
      );
      expect(
        () => parsePluginManifest(manifest({'entry': null})),
        fails('entry'),
      );
      expect(
        () => parsePluginManifest(manifest({'localization': null})),
        fails('localization'),
      );
    });

    test('v1 manifests keep their loose rules', () {
      final m = parsePluginManifest({
        'id': 'old.plugin',
        'name': 'Old',
        'version': 'beta',
        'scripts': {'actions': 'actions.js'},
        'contributes': {
          'sidebar': [
            {'id': 'go', 'label': 'Go'},
          ],
        },
      });
      expect(m.specVersion, 1);
      expect(m.entry, 'actions.js');
    });

    test('parses message mounts with filters', () {
      final mount = PluginMount.parse(
        '/messages/end?role=character&position=last',
      );
      expect(mount.surface, PluginMountSurface.messages);
      expect(mount.role, 'character');
      expect(mount.position, 'last');
      expect(
        () => PluginMount.parse('/chat/side/end'),
        throwsA(isA<PluginManifestException>()),
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
      expect(nested.files.keys, contains('entry.js'));
    });

    test('rejects missing files and unsafe paths', () {
      final missing = packageFiles()..remove('entry.js');
      expect(
        () => readPluginPackage(zip(missing)),
        throwsA(isA<PluginManifestException>()),
      );
      expect(
        () => readPluginPackage(zip({...packageFiles(), '../evil.js': 'x'})),
        throwsA(isA<PluginManifestException>()),
      );
      expect(
        () => readPluginPackage(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<PluginManifestException>()),
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
