import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_capabilities.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/reference_matcher.dart';

void main() {
  group('Gemini capabilities', () {
    test('classifies official ids and proxy aliases', () {
      expect(
        classifyGeminiImageModel('gemini-3.1-flash-image-preview'),
        'gemini-3.1-flash-image',
      );
      expect(
        classifyGeminiImageModel('nano-banana-2'),
        'gemini-3.1-flash-image',
      );
      expect(classifyGeminiImageModel('nano-banana-pro'), 'gemini-3-pro-image');
      expect(classifyGeminiImageModel('nano-banana'), 'gemini-2.5-flash-image');
      expect(classifyGeminiImageModel('some-proxy-model'), 'unknown');
    });

    test('2.5 Flash Image takes no image size', () {
      expect(geminiCapabilities('gemini-2.5-flash-image').imageSizes, isNull);
      expect(geminiCapabilities('gemini-2.5-flash-image').maxReferences, 3);
    });

    test('3.1 Flash Image allows the widest ratios', () {
      final caps = geminiCapabilities('gemini-3.1-flash-image');
      expect(caps.maxReferences, 14);
      expect(caps.aspectRatios, contains('21:9'));
      expect(caps.imageSizes, contains('512'));
    });
  });

  group('OpenAI capabilities', () {
    test('classifies the model families', () {
      expect(classifyOpenAiImageModel('gpt-image-1.5'), 'gpt-image-1.5');
      expect(classifyOpenAiImageModel('gpt-image-1-mini'), 'gpt-image-1-mini');
      expect(classifyOpenAiImageModel('flux-1-kontext-pro'), 'flux-kontext');
      expect(classifyOpenAiImageModel('dall-e-3'), 'dall-e-3');
    });

    test('only the gpt-image family takes multiple references', () {
      expect(openAiMaxReferences('gpt-image-1'), greaterThan(1));
      expect(openAiMaxReferences('flux-kontext'), 1);
      expect(openAiMaxReferences('dall-e-3'), 0);
    });

    test('maps aspect ratios per family', () {
      expect(openAiAspectRatioToSize('16:9', 'gpt-image-1'), '1536x1024');
      expect(openAiAspectRatioToSize('16:9', 'dall-e-3'), '1792x1024');
      expect(openAiAspectRatioToSize('21:9', 'dall-e-3'), isNull);
    });

    test('normalizes quality per family', () {
      expect(normalizeOpenAiQuality('hd', 'gpt-image-1'), 'high');
      expect(normalizeOpenAiQuality('standard', 'gpt-image-1'), 'medium');
      expect(normalizeOpenAiQuality('weird', 'dall-e-3'), 'standard');
    });
  });

  group('OpenRouter capabilities', () {
    test('delegates google/* to the Gemini table', () {
      expect(
        openRouterCapabilities('google/gemini-2.5-flash-image').imageSizes,
        isNull,
      );
      expect(isGeminiOpenRouterModel('google/gemini-3-pro-image'), isTrue);
    });

    test('generic models get no image size', () {
      final caps = openRouterCapabilities('black-forest-labs/flux-1.1-pro');
      expect(caps.imageSizes, isNull);
      expect(caps.aspectRatios, contains('16:9'));
      expect(
        isGeminiOpenRouterModel('black-forest-labs/flux-1.1-pro'),
        isFalse,
      );
    });
  });

  group('providerMaxReferences', () {
    test('AUTOMATIC1111 accepts none', () {
      expect(
        providerMaxReferences(
          const ImageGenSettings(apiType: ImageGenApiType.a1111),
        ),
        0,
      );
    });

    test('ComfyUI accepts none', () {
      expect(
        providerMaxReferences(
          const ImageGenSettings(apiType: ImageGenApiType.comfyui),
        ),
        0,
      );
    });

    test('Naistera models without reference support accept none', () {
      expect(
        providerMaxReferences(
          const ImageGenSettings(
            apiType: ImageGenApiType.naistera,
            naisteraModel: 'novelai',
          ),
        ),
        0,
      );
      expect(
        providerMaxReferences(
          const ImageGenSettings(
            apiType: ImageGenApiType.naistera,
            naisteraModel: 'grok',
          ),
        ),
        greaterThan(0),
      );
    });

    test('NovelAI accepts references only on V4.5', () {
      expect(
        providerMaxReferences(
          const ImageGenSettings(
            apiType: ImageGenApiType.novelai,
            novelai: NovelAIImageSettings(model: 'nai-diffusion-4-5-full'),
          ),
        ),
        greaterThan(0),
      );
      expect(
        providerMaxReferences(
          const ImageGenSettings(
            apiType: ImageGenApiType.novelai,
            novelai: NovelAIImageSettings(model: 'nai-diffusion-3'),
          ),
        ),
        0,
      );
    });

    test('dall-e-3 on the OpenAI path accepts none', () {
      expect(
        providerMaxReferences(const ImageGenSettings(customModel: 'dall-e-3')),
        0,
      );
    });
  });

  group('reference matching', () {
    const library = [
      ReferenceImage(name: 'Zoe, Зои', imageData: 'zoe'),
      ReferenceImage(name: 'Ann', imageData: 'ann'),
      ReferenceImage(name: 'logo', imageData: 'logo', matchMode: 'always'),
      ReferenceImage(name: 'Bob', imageData: 'bob', enabled: false),
      ReferenceImage(name: 'NoImage', imageData: ''),
    ];

    test('matches any alias of a name', () {
      expect(
        matchReferences('Зои smiles', library).map((r) => r.imageData),
        containsAll(<String>['zoe', 'logo']),
      );
    });

    test('matches whole words only', () {
      final matched = matchReferences('the announcement', library);
      expect(matched.map((r) => r.imageData), isNot(contains('ann')));
    });

    test('always-mode entries match without a trigger', () {
      expect(
        matchReferences('an empty street', library).map((r) => r.imageData),
        ['logo'],
      );
    });

    test('skips disabled and image-less entries', () {
      final matched = matchReferences('Bob and NoImage', library);
      expect(matched.map((r) => r.name), isNot(contains('Bob')));
      expect(matched.map((r) => r.name), isNot(contains('NoImage')));
    });
  });
}
