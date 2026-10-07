import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_panel_updater.dart';

void main() {
  const character = Character(id: 'char-1', name: 'Alise');

  PresetRegex displayRegex({
    required String regex,
    required String replacement,
    bool markdownOnly = false,
    bool promptOnly = false,
  }) => PresetRegex.fromJson({
    'id': 'r1',
    'scriptName': 'script',
    'findRegex': regex,
    'replaceString': replacement,
    'placement': [1, 2],
    'markdownOnly': markdownOnly,
    'promptOnly': promptOnly,
  });

  test('runs the display pass over ext-block content', () {
    final out = applyExtBlockDisplayRegexes(
      '<fandom_guide_state>Title</fandom_guide_state>',
      character: character,
      persona: null,
      sessionVars: const {},
      globalVars: const {},
      displayRegexes: [
        displayRegex(
          regex: r'/<fandom_guide_state>(?<fandom>[^<]*)<\/fandom_guide_state>/g',
          replacement: r'<div class="card">$<fandom></div>',
          markdownOnly: true,
        ),
      ],
    );

    expect(out, equals('<div class="card">Title</div>'));
  });

  test('a promptOnly script stays out of the display pass', () {
    final promptOnly = displayRegex(
      regex: r'/X/g',
      replacement: 'Y',
      promptOnly: true,
    );
    final out = applyExtBlockDisplayRegexes(
      'aXb',
      character: character,
      persona: null,
      sessionVars: const {},
      globalVars: const {},
      displayRegexes: [promptOnly],
    );
    expect(out, equals('aXb'));
  });

  test('leaves content alone without a character or scripts', () {
    const input = 'aXb';
    expect(
      applyExtBlockDisplayRegexes(
        input,
        character: null,
        persona: null,
        sessionVars: const {},
        globalVars: const {},
        displayRegexes: [displayRegex(regex: r'/X/g', replacement: 'Y')],
      ),
      equals(input),
    );
    expect(
      applyExtBlockDisplayRegexes(
        input,
        character: character,
        persona: null,
        sessionVars: const {},
        globalVars: const {},
        displayRegexes: const [],
      ),
      equals(input),
    );
  });
}
