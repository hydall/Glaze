import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/import/silly_tavern_preset_parser.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/presets/preset_export.dart';

void main() {
  test('regex folders survive an export and a re-import', () {
    final preset = Preset(
      id: 'p',
      name: 'Folders',
      regexFolders: const [PresetRegexFolder(id: 'rf1', name: 'Formatting')],
      regexes: const [
        PresetRegex(id: 'r1', name: 'Loose', regex: 'a'),
        PresetRegex(id: 'r2', name: 'Filed', regex: 'b', folderId: 'rf1'),
      ],
    );

    final json = presetExportJson(preset);
    expect(json['regex_folders'], [
      {'id': 'rf1', 'name': 'Formatting'},
    ]);

    final back = parseSillyTavernPreset(json, 'folders.json');
    expect(back.regexFolders.single.name, 'Formatting');
    expect(back.regexes.map((r) => (r.name, r.folderId)), [
      ('Loose', null),
      ('Filed', 'rf1'),
    ]);
  });

  test('a script naming a folder the file does not declare lands loose', () {
    final back = parseSillyTavernPreset({
      'name': 'Dangling',
      'regexes': [
        {'scriptName': 'Orphan', 'findRegex': 'x', 'folder': 'missing'},
      ],
    }, 'dangling.json');
    expect(back.regexFolders, isEmpty);
    expect(back.regexes.single.folderId, isNull);
  });
}
