import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/theme/default_chat_settings.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_settings_schema.dart';

/// A theme's own settings for the editor's Chat screen
/// (docs/THEME_LAYOUTS.md § Settings).
void main() {
  group('declaration', () {
    test('the built-in Chat screen is a declaration like any theme\'s', () {
      final schema = kDefaultChatSettingsSchema;
      expect(schema.errors, isEmpty);
      expect([for (final t in schema.tabs) t.id], ['font', 'colors', 'general']);
      final general = schema.tabs.last;
      final fields = [
        for (final g in general.groups)
          for (final i in g.items) i.field,
      ];
      // Background and layout live under General.
      expect(fields, containsAll(['chatLayout', 'chatBgMode', 'chatBgColor']));
      // Every row of the built-in screen edits a preset field.
      expect(
        schema.items.every((i) => i.kind == ThemeSettingKind.field),
        isTrue,
      );
    });

    test('the theme template starts from the built-in declaration', () {
      final file = File('docs/theme_template/settings.json');
      final template = jsonDecode(file.readAsStringSync()) as Map;
      final builtIn = jsonDecode(jsonEncode(kDefaultChatSettings)) as Map;
      final tabs = template['tabs'] as List;
      expect(tabs.take(3).toList(), builtIn['tabs']);
      final schema = ThemeSettingsSchema.parse(template)!;
      expect(schema.errors, isEmpty);
      expect(schema.tabs.length, 4);
      expect(
        {for (final i in schema.ownItems) i.key},
        {'card-edge', 'edge', 'card-pad', 'compact'},
      );
    });

    test('what cannot be used is dropped and named, the rest stays', () {
      final schema = ThemeSettingsSchema.parse({
        'tabs': [
          {
            'id': 'mine',
            'label': {'en': 'Mine', 'ru': 'Моё'},
            'icon': 'not-an-icon',
            'groups': [
              {
                'items': [
                  {'field': 'apiKey'},
                  {'type': 'color', 'key': 'bad key', 'label': 'x'},
                  {'type': 'color', 'key': 'ok', 'label': 'Ok', 'default': 'red'},
                  {'type': 'switch', 'key': 'ok', 'label': 'Twice'},
                  {
                    'type': 'slider',
                    'key': 'size',
                    'label': 'Size',
                    'min': 4,
                    'max': 2,
                  },
                  {
                    'type': 'slider',
                    'key': 'gap',
                    'label': 'Gap',
                    'min': 0,
                    'max': 10,
                    'unit': 'vw',
                  },
                  {'type': 'select', 'key': 'none', 'label': 'None'},
                  {'type': 'wat', 'key': 'w', 'label': 'W'},
                  'chatFontSize',
                ],
              },
            ],
          },
          {'id': 'empty', 'label': 'Empty', 'groups': <Object>[]},
        ],
      })!;
      expect(schema.tabs.single.id, 'mine');
      expect(schema.tabs.single.icon, isNull);
      final items = schema.items.toList();
      expect(items.length, 2);
      expect(items[0].key, 'ok');
      // A default that is not a colour falls back to none.
      expect(items[0].defaultValue, isNull);
      expect(items[1].field, 'chatFontSize');
      expect(schema.errors.length, 8);
    });

    test('text resolves by language, and @ names the app\'s own', () {
      final text = ThemeText.parse({'en': 'Size', 'ru': 'Размер'})!;
      String tr(String key) => 'tr:$key';
      expect(text.resolve('ru', tr), 'Размер');
      expect(text.resolve('de', tr), 'Size');
      expect(ThemeText.parse('@tab_font')!.resolve('en', tr), 'tr:tab_font');
      expect(ThemeText.parse('Plain')!.resolve('ru', tr), 'Plain');
    });

    test('a theme without tabs has no declaration', () {
      expect(ThemeSettingsSchema.parse(''), isNull);
      expect(ThemeSettingsSchema.parse({'nope': 1}), isNull);
      expect(ThemeSettingsSchema.parse('{broken')!.isEmpty, isTrue);
    });
  });

  group('values', () {
    final schema = ThemeSettingsSchema.parse({
      'tabs': [
        {
          'label': 'T',
          'groups': [
            {
              'items': [
                {
                  'type': 'color',
                  'key': 'edge',
                  'label': 'Edge',
                  'default': '#112233',
                },
                {
                  'type': 'slider',
                  'key': 'pad',
                  'label': 'Pad',
                  'min': 0,
                  'max': 20,
                  'unit': 'px',
                  'default': 8,
                },
                {'type': 'switch', 'key': 'dense', 'label': 'Dense'},
                {
                  'type': 'select',
                  'key': 'side',
                  'label': 'Side',
                  'options': [
                    {'value': 'left', 'label': 'Left'},
                    {'value': 'top', 'label': 'Top'},
                  ],
                },
                {'field': 'userBubbleColor'},
              ],
            },
          ],
        },
      ],
    });

    test('defaults reach the page as variables, flags and values', () {
      final v = themeSettingValues(schema, const {});
      expect(v.vars, {
        'edge': '#112233',
        'pad': '8px',
        'dense': '0',
        'side': 'left',
      });
      expect(v.flags, ['side-left']);
      expect(v.values['dense'], false);
    });

    test('stored values win while they fit the declaration', () {
      final v = themeSettingValues(schema, {
        'edge': 'url(https://example.com/x.png)',
        'pad': 99,
        'dense': true,
        'side': 'top',
        'userBubbleColor': '#FFFFFF',
      });
      expect(v.vars['edge'], '#112233');
      expect(v.vars['pad'], '20px');
      expect(v.flags, containsAll(['dense', 'side-top']));
      // A preset field is never a theme value.
      expect(v.values.containsKey('userBubbleColor'), isFalse);
    });

    test('the page payloads carry the values next to the layout', () {
      final preset = ThemePreset(
        id: 't',
        name: 'T',
        layoutSettings: jsonEncode({
          'tabs': [
            {
              'label': 'T',
              'groups': [
                {
                  'items': [
                    {'type': 'switch', 'key': 'dense', 'label': 'Dense'},
                  ],
                },
              ],
            },
          ],
        }),
        themeValues: const {'dense': true},
      );
      expect(preset.messageLayout, isNull);
      expect(preset.messageLayoutPayload, {
        'vars': {'dense': '1'},
        'flags': ['dense'],
        'values': {'dense': true},
      });
      expect(preset.chromeLayoutPayload, {
        'vars': {'dense': '1'},
        'flags': ['dense'],
      });
      expect(const ThemePreset(id: 'p', name: 'P').messageLayoutPayload, isNull);
    });
  });

  group('conditions', () {
    Object? lookup(String name) => switch (name) {
      'chatLayout' => 'bubble',
      'desktop' => false,
      'theme.pad' => 8,
      'pad' => 8,
      _ => null,
    };

    test('evaluate the small language', () {
      expect(evaluateThemeCondition("chatLayout == 'bubble'", lookup), isTrue);
      expect(evaluateThemeCondition("chatLayout != 'bubble'", lookup), isFalse);
      expect(
        evaluateThemeCondition("desktop && chatLayout != 'bubble'", lookup),
        isFalse,
      );
      expect(evaluateThemeCondition('!desktop || missing', lookup), isTrue);
      expect(evaluateThemeCondition('pad >= 8 && pad < 9', lookup), isTrue);
      expect(evaluateThemeCondition('theme.pad > 10', lookup), isFalse);
      expect(evaluateThemeCondition('(missing)', lookup), isFalse);
    });

    test('a condition that does not parse shows the row', () {
      expect(evaluateThemeCondition("chatLayout == 'bubble", lookup), isTrue);
      expect(evaluateThemeCondition('a ==', lookup), isTrue);
      expect(evaluateThemeCondition(null, lookup), isTrue);
    });
  });

  group('import', () {
    late ThemePresetStorage storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      storage = ThemePresetStorage(await SharedPreferences.getInstance());
    });

    test('the theme template imports as a zip, settings and all', () async {
      final archive = Archive();
      final root = Directory('docs/theme_template');
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File) continue;
        final name = entity.path
            .substring(root.path.length + 1)
            .replaceAll('\\', '/');
        final bytes = entity.readAsBytesSync();
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }
      final dir = await Directory.systemTemp.createTemp('glaze-template-');
      final file = File('${dir.path}/template.gtheme');
      await file.writeAsBytes(ZipEncoder().encode(archive));
      final ThemePreset preset;
      try {
        preset = await storage.importFromFile(file.path);
      } finally {
        await dir.delete(recursive: true);
      }

      expect(preset.hasCustomLayout, isTrue);
      expect(preset.settingsSchema!.tabs.length, 4);
      final payload = preset.messageLayoutPayload!;
      expect(payload['message'], contains('theme.compact'));
      expect((payload['vars'] as Map)['card-edge'], '#C42A4A');
      expect(payload['flags'], contains('edge-left'));

      // Exported and imported again, the declaration and the values stay.
      final edited = preset.copyWith(themeValues: {'compact': true});
      final back = await storage.importFromJson(jsonEncode(edited.toJson()));
      expect(back.layoutSettings, preset.layoutSettings);
      expect(back.themeValues, {'compact': true});
    });

    test('an unusable declaration is not imported', () async {
      final preset = await storage.importFromJson(
        jsonEncode({
          'name': 'Broken',
          'accentColor': '#C42A4A',
          'layout': {
            'settings': {'tabs': 'nope'},
          },
        }),
      );
      expect(preset.layoutSettings, '');
      expect(preset.settingsSchema, isNull);
    });
  });
}
