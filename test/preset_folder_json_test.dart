import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/import/silly_tavern_preset_parser.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/presets/preset_export.dart';

Map<String, dynamic> _prompt(String name, {String? folder}) => {
  'name': name,
  'role': 'system',
  'content': 'content of $name',
  'enabled': true,
  'insertion_mode': 'relative',
  'folder': ?folder,
};

void main() {
  group('import', () {
    test('reads only the folders the file declares', () {
      final preset = parseSillyTavernPreset({
        'name': 'Folders',
        'prompts': [
          _prompt('Intro'),
          _prompt('Roleplay', folder: 'f_styles'),
          _prompt('AO3', folder: 'f_styles'),
        ],
        'block_folders': [
          {'id': 'f_styles', 'name': 'Narrative Styles', 'enabled': false},
        ],
      }, 'folders.json');

      expect(preset.blockFolders, hasLength(1));
      expect(preset.blockFolders.single.name, 'Narrative Styles');
      expect(preset.blockFolders.single.enabled, isFalse);
      expect(
        preset.blocks.where((b) => b.folderId == 'f_styles').map((b) => b.name),
        ['Roleplay', 'AO3'],
      );
      expect(
        preset.blocks.firstWhere((b) => b.name == 'Intro').folderId,
        isNull,
      );
    });

    test('never invents a folder from a divider-looking block', () {
      final preset = parseSillyTavernPreset({
        'name': 'Dividers',
        'prompts': [_prompt('━✏️ Narrative Styles'), _prompt('Roleplay')],
      }, 'dividers.json');

      expect(preset.blockFolders, isEmpty);
      expect(preset.blocks.every((b) => b.folderId == null), isTrue);
    });

    test('drops a reference to a folder that is not declared', () {
      final preset = parseSillyTavernPreset({
        'name': 'Dangling',
        'prompts': [_prompt('Roleplay', folder: 'gone')],
      }, 'dangling.json');

      expect(preset.blockFolders, isEmpty);
      expect(
        preset.blocks.firstWhere((b) => b.name == 'Roleplay').folderId,
        isNull,
      );
    });

    test('a SillyTavern-native file imports with no folders', () {
      final preset = parseSillyTavernPreset({
        'name': 'Native',
        'prompts': [
          {
            'identifier': 'main',
            'name': 'Main Prompt',
            'role': 'system',
            'content': 'text',
          },
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'main', 'enabled': true},
            ],
          },
        ],
      }, 'native.json');

      expect(preset.blockFolders, isEmpty);
      expect(preset.blocks.every((b) => b.folderId == null), isTrue);
    });
  });

  group('export', () {
    test('writes folders as a separate list plus a per-prompt reference', () {
      const preset = Preset(
        id: 'p',
        name: 'Folders',
        blocks: [
          PresetBlock(
            id: 'intro',
            name: 'Intro',
            role: 'system',
            content: 'intro',
          ),
          PresetBlock(
            id: 'roleplay',
            name: 'Roleplay',
            role: 'system',
            content: 'rp',
            folderId: 'f_styles',
          ),
        ],
        blockFolders: [
          PresetBlockFolder(id: 'f_styles', name: 'Narrative Styles'),
        ],
      );

      final json = presetExportJson(preset);
      final prompts = (json['prompts'] as List).cast<Map<String, dynamic>>();

      expect(json['block_folders'], [
        {
          'id': 'f_styles',
          'name': 'Narrative Styles',
          'enabled': true,
          'exclusive': false,
        },
      ]);
      expect(prompts.first.containsKey('folder'), isFalse);
      expect(prompts.last['folder'], 'f_styles');
    });

    test('a preset without folders writes no folder keys at all', () {
      const preset = Preset(
        id: 'p',
        name: 'Plain',
        blocks: [
          PresetBlock(
            id: 'intro',
            name: 'Intro',
            role: 'system',
            content: 'intro',
          ),
        ],
      );

      final json = presetExportJson(preset);
      expect(json.containsKey('block_folders'), isFalse);
      expect(
        (json['prompts'] as List).cast<Map<String, dynamic>>().every(
          (p) => !p.containsKey('folder'),
        ),
        isTrue,
      );
    });

    test('export and re-import keep folder membership', () {
      const preset = Preset(
        id: 'p',
        name: 'Round trip',
        blocks: [
          PresetBlock(
            id: 'roleplay',
            name: 'Roleplay',
            role: 'system',
            content: 'rp',
            folderId: 'f_styles',
          ),
        ],
        blockFolders: [
          PresetBlockFolder(
            id: 'f_styles',
            name: 'Narrative Styles',
            enabled: false,
            exclusive: true,
          ),
        ],
      );

      final reimported = parseSillyTavernPreset(
        presetExportJson(preset),
        'round.json',
      );

      expect(reimported.blockFolders.single.name, 'Narrative Styles');
      expect(reimported.blockFolders.single.enabled, isFalse);
      expect(reimported.blockFolders.single.exclusive, isTrue);
      expect(
        reimported.blocks.firstWhere((b) => b.name == 'Roleplay').folderId,
        'f_styles',
      );
    });
  });
}
