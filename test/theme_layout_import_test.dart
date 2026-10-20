import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';

/// A theme file's own layout: templates and stylesheets, inline or as files
/// in the theme archive (docs/THEME_LAYOUTS.md).
void main() {
  late ThemePresetStorage storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = ThemePresetStorage(await SharedPreferences.getInstance());
  });

  Future<ThemePreset> importFile(List<int> bytes) async {
    final dir = await Directory.systemTemp.createTemp('glaze-theme-');
    final file = File('${dir.path}/theme.gtheme');
    await file.writeAsBytes(bytes);
    try {
      return await storage.importFromFile(file.path);
    } finally {
      await dir.delete(recursive: true);
    }
  }

  test('reads a layout from theme.json, inline', () async {
    final preset = await storage.importFromJson(
      jsonEncode({
        'name': 'Cards',
        'accentColor': '#C42A4A',
        'layout': {
          'message':
              '<div class="card">{{name}}</div><g-part name="content"></g-part>',
          'css': '.card { color: red }',
          'contentCss': '.glaze-message pre { color: cyan }',
          'chrome': {
            'header': '<div>{{title}}</div>',
            'css': '.gc-hdr { background: none }',
          },
        },
      }),
    );

    expect(preset.layoutMessage, contains('g-part'));
    expect(preset.layoutCss, '.card { color: red }');
    expect(preset.layoutHeader, '<div>{{title}}</div>');
    expect(preset.layoutChromeCss, '.gc-hdr { background: none }');
    expect(preset.messageLayout, {
      'message': preset.layoutMessage,
      'css': preset.layoutCss,
      'contentCss': '.glaze-message pre { color: cyan }',
    });
    expect(preset.chromeLayout, {
      'header': preset.layoutHeader,
      'css': preset.layoutChromeCss,
    });
    expect(preset.hasCustomLayout, isTrue);
  });

  test('reads layout parts from files in the archive', () async {
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'theme.json',
          utf8
              .encode(
                jsonEncode({
                  'name': 'Zipped',
                  'accentColor': '#C42A4A',
                  'layout': {
                    'message': 'layout/message.html',
                    'css': 'layout/chat.css',
                    'chrome': {
                      'header': 'layout/header.html',
                      'composer': 'layout/composer.html',
                      'card': 'layout/card.html',
                      'tab': 'layout/tab.html',
                      'css': 'layout/chrome.css',
                    },
                  },
                }),
              )
              .length,
          utf8.encode(
            jsonEncode({
              'name': 'Zipped',
              'accentColor': '#C42A4A',
              'layout': {
                'message': 'layout/message.html',
                'css': 'layout/chat.css',
                'chrome': {
                  'header': 'layout/header.html',
                  'composer': 'layout/composer.html',
                  'card': 'layout/card.html',
                  'tab': 'layout/tab.html',
                  'css': 'layout/chrome.css',
                },
              },
            }),
          ),
        ),
      );
    void part(String path, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    part('layout/message.html', '<b>{{text}}</b>');
    part('layout/chat.css', '.msg-body { margin: 0 }');
    part('layout/header.html', '<i>{{title}}</i>');
    part('layout/composer.html', '<g-part name="input"></g-part>');
    part('layout/card.html', '<u>{{label}}</u>');
    part('layout/tab.html', '<s>{{label}}</s>');
    part('layout/chrome.css', '.gc-input { font-size: 20px }');

    final preset = await importFile(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );

    expect(preset.layoutMessage, '<b>{{text}}</b>');
    expect(preset.layoutCss, '.msg-body { margin: 0 }');
    expect(preset.layoutContentCss, isEmpty);
    expect(preset.layoutHeader, '<i>{{title}}</i>');
    expect(preset.layoutComposer, '<g-part name="input"></g-part>');
    expect(preset.layoutDrawerCard, '<u>{{label}}</u>');
    expect(preset.layoutDrawerTab, '<s>{{label}}</s>');
    expect(preset.layoutChromeCss, '.gc-input { font-size: 20px }');
  });

  test('a missing layout file leaves the part empty, not the path', () async {
    final preset = await storage.importFromJson(
      jsonEncode({
        'name': 'Broken',
        'accentColor': '#C42A4A',
        'layout': {'message': 'layout/missing.html'},
      }),
    );
    expect(preset.layoutMessage, isEmpty);
    expect(preset.hasCustomLayout, isFalse);
  });

  test('an oversized part is dropped', () async {
    final preset = await storage.importFromJson(
      jsonEncode({
        'name': 'Huge',
        'accentColor': '#C42A4A',
        'layout': {'message': 'x' * (256 * 1024 + 1)},
      }),
    );
    expect(preset.layoutMessage, isEmpty);
  });

  test('export then import keeps the layout', () async {
    const preset = ThemePreset(id: 'x', name: 'X');
    final withLayout = preset.copyWith(
      layoutMessage: '<div>{{text}}</div>',
      layoutCss: '.x{color:red}',
      layoutHeader: '<div>{{title}}</div>',
      layoutChromeCss: '.gc{color:red}',
    );
    final back = await storage.importFromJson(jsonEncode(withLayout.toJson()));
    expect(back.layoutMessage, '<div>{{text}}</div>');
    expect(back.layoutCss, '.x{color:red}');
    expect(back.layoutHeader, '<div>{{title}}</div>');
    expect(back.layoutChromeCss, '.gc{color:red}');
    expect(back.chromeLayout, {
      'header': back.layoutHeader,
      'css': '.gc{color:red}',
    });
  });

  test('a preset without a layout has none, and exports without one', () {
    const preset = ThemePreset(id: 'plain', name: 'Plain');
    expect(preset.messageLayout, isNull);
    expect(preset.chromeLayout, isNull);
    expect(preset.hasCustomLayout, isFalse);

    final withLayout = preset.copyWith(
      layoutMessage: '<div>{{text}}</div>',
      layoutChromeCss: '.gc { color: red }',
    );
    final back = ThemePreset.fromJson(withLayout.toJson());
    expect(back.layoutMessage, '<div>{{text}}</div>');
    expect(back.layoutChromeCss, '.gc { color: red }');
  });
}
