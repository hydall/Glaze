import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/regex_service.dart';
import 'package:glaze_flutter/core/models/preset.dart';

/// Where a script runs is one answer, whichever way the script says it: an
/// imported script's SillyTavern flags, else Glaze's own ephemerality list.
void main() {
  const ctx = RegexApplyContext();

  // The pair that did not work together: every space goes out to the model as
  // a figure space, and every figure space the model sends back is shown as
  // a plain one. Stored as an older import left them — list `[2]` on both,
  // whatever the flags said — which kept the first one out of the display.
  const returnNormal = PresetRegex(
    id: 'return',
    name: 'Return Normal Spaces',
    regex: '/ /g',
    replacement: ' ',
    placement: [1, 2],
    ephemerality: [2],
    markdownOnly: true,
    promptOnly: true,
    runOnEdit: true,
  );
  const useFigure = PresetRegex(
    id: 'figure',
    name: 'Use Figure Spaces',
    regex: '/ /g',
    replacement: ' ',
    placement: [1, 2],
    ephemerality: [2],
    promptOnly: true,
    runOnEdit: true,
  );

  group('RegexPasses', () {
    test('a SillyTavern-flagged script follows its flags, not the list', () {
      expect(returnNormal.altersDisplay, isTrue);
      expect(returnNormal.altersPrompt, isTrue);
      expect(useFigure.altersDisplay, isFalse);
      expect(useFigure.altersPrompt, isTrue);
    });

    test(
      'a script without flags follows the list; an empty list is every pass',
      () {
        const displayOnly = PresetRegex(
          id: 'd',
          name: 'd',
          regex: '/x/g',
          ephemerality: [1],
        );
        const everywhere = PresetRegex(
          id: 'e',
          name: 'e',
          regex: '/x/g',
          ephemerality: [],
        );
        expect(displayOnly.altersDisplay, isTrue);
        expect(displayOnly.altersPrompt, isFalse);
        expect(everywhere.altersDisplay, isTrue);
        expect(everywhere.altersPrompt, isTrue);
      },
    );

    test('withPasses writes both ways of saying it', () {
      final edited = returnNormal.withPasses(display: false, prompt: true);
      expect(edited.ephemerality, [2]);
      expect(edited.markdownOnly, isFalse);
      expect(edited.promptOnly, isTrue);
      expect(edited.altersDisplay, isFalse);
      final both = useFigure.withPasses(display: true, prompt: true);
      expect(both.ephemerality, [1, 2]);
      expect(both.altersDisplay, isTrue);
    });
  });

  group('applyRegexes with the figure-space pair', () {
    const scripts = [returnNormal, useFigure];

    test('the prompt goes out with figure spaces', () {
      final out = applyRegexes(
        'one two three',
        2,
        2,
        scripts,
        ctx,
        isPrompt: true,
      );
      expect(out, 'one two three');
    });

    test('the display shows plain spaces', () {
      final out = applyRegexes(
        'one two three',
        2,
        1,
        scripts,
        ctx,
        isMarkdown: true,
      );
      expect(out, 'one two three');
    });

    test('the storage pass on edit leaves both alone', () {
      final out = applyRegexes('one two three', 2, 1, scripts, ctx);
      expect(out, 'one two three');
    });
  });

  group('applyRegexes with Glaze-native scripts', () {
    const displayOnly = PresetRegex(
      id: 'd',
      name: 'display',
      regex: '/x/g',
      replacement: 'D',
      ephemerality: [1],
    );
    const promptOnlyList = PresetRegex(
      id: 'p',
      name: 'prompt',
      regex: '/x/g',
      replacement: 'P',
      ephemerality: [2],
    );

    test('the list still decides for a script without flags', () {
      expect(
        applyRegexes(
          'x',
          2,
          1,
          const [displayOnly, promptOnlyList],
          ctx,
          isMarkdown: true,
        ),
        'D',
      );
      expect(
        applyRegexes(
          'x',
          2,
          2,
          const [displayOnly, promptOnlyList],
          ctx,
          isPrompt: true,
        ),
        'P',
      );
      // The storage pass keeps to the list as well.
      expect(applyRegexes('x', 2, 1, const [promptOnlyList], ctx), 'x');
      expect(applyRegexes('x', 2, 1, const [displayOnly], ctx), 'D');
    });
  });
}
