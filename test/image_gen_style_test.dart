import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/image_prompt_builder.dart';
import 'package:glaze_flutter/features/image_gen/services/image_style_io.dart';

void main() {
  const anime = ImageStyle(id: 's1', name: 'Anime', value: 'anime, cel shaded');
  const animeNeg = ImageStyle(
    id: 's2',
    name: 'Anime',
    value: 'anime',
    negativePrompt: 'lowres, bad hands',
  );

  group('negative prompt resolution', () {
    test('appends the active style negative to the provider one', () {
      const settings = ImageGenSettings(styles: [animeNeg], activeStyleId: 's2');
      expect(
        resolveEffectiveNegativePrompt('watermark', settings),
        'watermark, lowres, bad hands',
      );
    });

    test('uses the style negative alone when the provider has none', () {
      const settings = ImageGenSettings(styles: [animeNeg], activeStyleId: 's2');
      expect(
        resolveEffectiveNegativePrompt('', settings),
        'lowres, bad hands',
      );
    });

    test('leaves the provider negative alone without an active style', () {
      const settings = ImageGenSettings(styles: [animeNeg]);
      expect(resolveEffectiveNegativePrompt('watermark', settings), 'watermark');
    });
  });

  group('style resolution', () {
    test('"no style" keeps the style written into the image tag', () {
      const settings = ImageGenSettings(styles: [anime]);
      expect(
        resolveEffectiveStyle('cinematic manga', settings),
        'cinematic manga',
      );
    });

    test('an active style overrides the tag style', () {
      const settings = ImageGenSettings(styles: [anime], activeStyleId: 's1');
      expect(
        resolveEffectiveStyle('cinematic manga', settings),
        'anime, cel shaded',
      );
    });

    test('a missing active style id falls back to the tag style', () {
      const settings = ImageGenSettings(styles: [anime], activeStyleId: 'gone');
      expect(
        resolveEffectiveStyle('cinematic manga', settings),
        'cinematic manga',
      );
    });
  });

  group('injectStyleBlock', () {
    test('prepends a style block', () {
      expect(injectStyleBlock('a cat', 'anime'), '[STYLE: anime]\n\na cat');
    });

    test('replaces a style block the model wrote itself', () {
      expect(
        injectStyleBlock('[STYLE: photo] a cat', 'anime'),
        '[STYLE: anime] a cat',
      );
    });

    test('drops extra style blocks', () {
      expect(
        injectStyleBlock('[STYLE: photo] a cat [style: oil]', 'anime'),
        '[STYLE: anime] a cat',
      );
    });

    test('an empty style leaves the prompt untouched', () {
      expect(injectStyleBlock('a cat', ''), 'a cat');
    });
  });

  group('buildFinalGenerationPrompt', () {
    test('adds matched reference descriptions', () {
      const settings = ImageGenSettings();
      final prompt = buildFinalGenerationPrompt(
        prompt: 'Zoe waves',
        tagStyle: 'anime',
        settings: settings,
        references: const [
          {
            'name': 'Zoe',
            'description': 'red-haired mage',
            'source': 'additional',
          },
        ],
      );
      expect(prompt, startsWith('[STYLE: anime]'));
      expect(prompt, contains('- Zoe: red-haired mage'));
    });

    test('descriptions are omitted when the toggle is off', () {
      const settings = ImageGenSettings(sendRefDescriptions: false);
      final prompt = buildFinalGenerationPrompt(
        prompt: 'Zoe waves',
        tagStyle: '',
        settings: settings,
        references: const [
          {'name': 'Zoe', 'description': 'mage', 'source': 'additional'},
        ],
      );
      expect(prompt, 'Zoe waves');
    });
  });

  group('reference instruction', () {
    test('is prefixed only when references are attached', () {
      const settings = ImageGenSettings();
      expect(
        withReferenceInstruction('a cat', settings, hasReferences: false),
        'a cat',
      );
      expect(
        withReferenceInstruction('a cat', settings, hasReferences: true),
        startsWith(defaultReferenceInstruction),
      );
    });

    test('can be switched off', () {
      const settings = ImageGenSettings(refInstructionEnabled: false);
      expect(
        withReferenceInstruction('a cat', settings, hasReferences: true),
        'a cat',
      );
    });

    test('a custom instruction replaces the default', () {
      const settings = ImageGenSettings(refInstruction: 'keep the faces');
      expect(
        withReferenceInstruction('a cat', settings, hasReferences: true),
        'keep the faces\n\na cat',
      );
    });
  });

  group('style export / import', () {
    test('round-trips through JSON', () {
      final decoded = ImageStyleIo.decode(
        ImageStyleIo.encode(const [animeNeg]),
      );
      expect(decoded.length, 1);
      expect(decoded.single.name, 'Anime');
      expect(decoded.single.value, 'anime');
      expect(decoded.single.negativePrompt, 'lowres, bad hands');
    });

    test('accepts a hand-written "negative" alias', () {
      final decoded = ImageStyleIo.decode(
        '[{"name":"Ink","value":"ink wash","negative":"blurry"}]',
      );
      expect(decoded.single.negativePrompt, 'blurry');
    });

    test('regenerates ids so imported styles never collide', () {
      final decoded = ImageStyleIo.decode(ImageStyleIo.encode(const [anime]));
      expect(decoded.single.id, isNot('s1'));
    });

    test('accepts a bare array of styles', () {
      final decoded = ImageStyleIo.decode(
        '[{"name":"Ink","value":"ink wash"}]',
      );
      expect(decoded.single.value, 'ink wash');
    });

    test('rejects a file of another kind', () {
      expect(
        () => ImageStyleIo.decode('{"kind":"iig-lorebook","styles":[]}'),
        throwsFormatException,
      );
    });

    test('rejects malformed JSON', () {
      expect(() => ImageStyleIo.decode('not json'), throwsFormatException);
    });
  });
}
