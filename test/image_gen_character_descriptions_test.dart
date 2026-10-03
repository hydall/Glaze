import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_capabilities.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_settings_codec.dart';
import 'package:glaze_flutter/features/image_gen/services/image_prompt_builder.dart';
import 'package:glaze_flutter/features/image_gen/services/naistera_image_provider.dart';

/// Ported behaviour from https://github.com/0xl0cal/sillyimages:
/// the Naistera character-description modes, the plain style prefix used for
/// NovelAI models, and the model catalog loaded from `GET /api/models`.
void main() {
  List<Map<String, String>> refs(List<String> sources) => [
    for (final source in sources)
      {
        'name': source,
        'image': 'AQ==',
        'description': 'desc',
        'source': source,
      },
  ];

  group('character description modes', () {
    test('none sends nothing at all', () {
      expect(
        buildCharacterDescriptionPromptBlock(
          mode: CharacterDescriptionsMode.none,
          references: const [],
          charDescription: 'red hair',
          userDescription: 'tall',
        ),
        '',
      );
    });

    test('as-is describes only the characters whose avatar is not sent', () {
      final block = buildCharacterDescriptionPromptBlock(
        mode: CharacterDescriptionsMode.asIs,
        references: refs(['char']),
        charDescription: 'red hair',
        userDescription: 'tall',
      );

      expect(block, 'Character descriptions:\n- {{user}}: tall');
      expect(block, isNot(contains('red hair')));
    });

    test('as-is describes both when no avatar travels', () {
      expect(
        buildCharacterDescriptionPromptBlock(
          mode: CharacterDescriptionsMode.asIs,
          references: refs(['additional', 'context']),
          charDescription: 'red hair',
          userDescription: 'tall',
        ),
        'Character descriptions:\n- {{char}}: red hair\n- {{user}}: tall',
      );
    });

    test('as-is stays empty when there is nothing to describe', () {
      expect(
        buildCharacterDescriptionPromptBlock(
          mode: CharacterDescriptionsMode.asIs,
          references: const [],
        ),
        '',
      );
    });

    test('character-prompt emits NovelAI lines, persona first', () {
      expect(
        buildCharacterDescriptionPromptBlock(
          mode: CharacterDescriptionsMode.characterPrompt,
          // Both avatars are sent and are still described: the image captions
          // are stripped in this mode, so the prompt is the only carrier.
          references: refs(['char', 'user']),
          charDescription: 'red hair',
          userDescription: 'tall',
        ),
        '\\| tall\n\\| red hair',
      );
    });
  });

  group('style wrapping', () {
    const settings = ImageGenSettings();

    test('the default keeps the [STYLE: ...] block', () {
      expect(
        buildFinalGenerationPrompt(
          prompt: 'a cat',
          tagStyle: 'anime',
          settings: settings,
        ),
        '[STYLE: anime]\n\na cat',
      );
    });

    test('NovelAI gets the style as a plain prefix', () {
      expect(
        buildFinalGenerationPrompt(
          prompt: 'a cat',
          tagStyle: 'anime',
          settings: settings,
          wrapStyle: false,
        ),
        'anime\n\na cat',
      );
    });

    test('a style block written by the model is dropped, not wrapped', () {
      expect(
        injectPlainStyle('[STYLE: manga] a cat', 'anime'),
        'anime\n\na cat',
      );
    });

    test('an empty style leaves the prompt alone', () {
      expect(injectPlainStyle('a cat', '  '), 'a cat');
    });

    test('NovelAI ids are recognized, other models are not', () {
      expect(NaisteraConstants.isNovelAIModel('novelai'), isTrue);
      expect(NaisteraConstants.isNovelAIModel('NovelAI-v4'), isTrue);
      expect(NaisteraConstants.isNovelAIModel('grok'), isFalse);
      expect(NaisteraConstants.isNovelAIModel('novelaigrok'), isFalse);
    });
  });

  group('Naistera model catalog', () {
    /// Serves one canned `/api/models` payload.
    Future<String> startServer(
      Map<String, dynamic> payload, {
      List<String>? authHeaders,
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        authHeaders?.add(request.headers.value('authorization') ?? '');
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(payload));
        await request.response.close();
      });
      return 'http://${server.address.host}:${server.port}';
    }

    test('loads visible models and their reference support', () async {
      final headers = <String>[];
      final baseUrl = await startServer({
        'authenticated': true,
        'tier': 'pro',
        'models': [
          {'id': 'grok', 'name': 'Grok', 'references': true},
          {
            'id': 'novelai',
            'name': 'NovelAI',
            'references': false,
            'negative_prompt': true,
          },
          {'id': 'hidden', 'visible': false},
          {'id': 'old', 'deprecated': true},
          {'id': '   '},
          {'id': 'flux-pro'},
        ],
      }, authHeaders: headers);

      final catalog = await NaisteraImageProvider(
        baseUrl: baseUrl,
      ).fetchModels(apiKey: 'token');

      expect(catalog.map((m) => m.id), ['grok', 'novelai', 'flux-pro']);
      expect(catalog[1].references, isFalse);
      expect(catalog[1].negativePrompt, isTrue);
      // No `negative_prompt` flag means the model takes none.
      expect(catalog[0].negativePrompt, isFalse);
      // A model with no `references` field is assumed to accept them.
      expect(catalog[2].references, isTrue);
      // A catalog entry with no name falls back to its id.
      expect(catalog[2].name, 'flux-pro');
      expect(headers.single, 'Bearer token');
    });

    test('a payload without a models list yields nothing', () async {
      final baseUrl = await startServer({'error': 'nope'});
      expect(
        await NaisteraImageProvider(baseUrl: baseUrl).fetchModels(apiKey: ''),
        isEmpty,
      );
    });

    test('the catalog decides reference support, not the deny-list', () {
      const base = ImageGenSettings(
        apiType: ImageGenApiType.naistera,
        naisteraModel: 'novelai',
      );

      // No catalog — the shipped deny-list still applies.
      expect(base.naisteraSupportsReferences, isFalse);
      expect(providerMaxReferences(base), 0);

      final withCatalog = base.copyWith(
        naisteraModels: const [
          NaisteraModelInfo(id: 'novelai', name: 'NovelAI', references: true),
        ],
      );
      expect(withCatalog.naisteraSupportsReferences, isTrue);
      expect(providerMaxReferences(withCatalog), greaterThan(0));
    });

    test('a model the API added later survives normalization', () {
      expect(NaisteraConstants.normalizeModel('flux-pro'), 'flux-pro');
      expect(NaisteraConstants.normalizeModel('Seedream-5'), 'Seedream-5');
      // Retired labels are still mapped onto the current ids.
      expect(NaisteraConstants.normalizeModel('nano banana'), 'nano-banana-2');
      // The deprecated Grok models fold into the current default.
      expect(NaisteraConstants.normalizeModel('grok'), 'nano-banana-2');
      expect(NaisteraConstants.normalizeModel(''), 'nano-banana-2');
    });

    test('catalog names label the picker', () {
      const settings = ImageGenSettings(
        naisteraModels: [NaisteraModelInfo(id: 'flux-pro', name: 'FLUX Pro')],
      );
      expect(settings.naisteraModelLabel('flux-pro'), 'FLUX Pro');
      // Falls back to the shipped shortlist, then to the raw id.
      expect(settings.naisteraModelLabel('novelai-v5'), 'NovelAI V5');
      expect(settings.naisteraModelLabel('mystery'), 'mystery');
    });
  });

  group('settings persistence', () {
    test('xAI settings and the Naistera catalog round-trip', () {
      const settings = ImageGenSettings(
        apiType: ImageGenApiType.xai,
        xai: XaiImageSettings(
          apiKey: 'xai-key',
          endpoint: 'https://proxy.example',
          model: 'grok-imagine-image',
          aspectRatio: '16:9',
          resolution: '2k',
          quality: 'low',
        ),
        naisteraModels: [NaisteraModelInfo(id: 'flux-pro', name: 'FLUX Pro')],
        naisteraCharacterDescriptionsMode:
            CharacterDescriptionsMode.characterPrompt,
      );

      final restored = ImageGenSettingsCodec.fromJson(
        ImageGenSettingsCodec.toJson(settings),
      );

      expect(restored, settings);
      expect(restored.apiType, ImageGenApiType.xai);
    });

    test('the Naistera negative prompt round-trips', () {
      const settings = ImageGenSettings(
        apiType: ImageGenApiType.naistera,
        naisteraModel: 'novelai-v5',
        naisteraNegativePrompt: 'blurry',
        naisteraModels: [
          NaisteraModelInfo(id: 'novelai-v5', negativePrompt: true),
        ],
      );

      final restored = ImageGenSettingsCodec.fromJson(
        ImageGenSettingsCodec.toJson(settings),
      );

      expect(restored, settings);
    });

    test('an old blob gets the new default model', () {
      expect(
        ImageGenSettingsCodec.fromJson({}).naisteraModel,
        NaisteraConstants.defaultModel,
      );
    });
  });

  group('Naistera negative prompt', () {
    test('Naistera negative support: catalog first, NovelAI fallback', () {
      const novel = ImageGenSettings(
        apiType: ImageGenApiType.naistera,
        naisteraModel: 'novelai-v4.5',
      );
      expect(novel.naisteraSupportsNegativePrompt, isTrue);
      expect(
        novel
            .copyWith(naisteraModel: 'nano-banana-2')
            .naisteraSupportsNegativePrompt,
        isFalse,
      );
      expect(
        novel
            .copyWith(
              naisteraModel: 'flux-pro',
              naisteraModels: const [
                NaisteraModelInfo(id: 'flux-pro', negativePrompt: true),
              ],
            )
            .naisteraSupportsNegativePrompt,
        isTrue,
      );
    });
  });

  group('legacy settings', () {
    test('the mode defaults to as-is for a blob written before it existed', () {
      expect(
        ImageGenSettingsCodec.fromJson({}).naisteraCharacterDescriptionsMode,
        CharacterDescriptionsMode.asIs,
      );
    });

    test('the retired on/off switch maps onto the modes', () {
      expect(
        ImageGenSettingsCodec.fromJson({
          'naisteraSendCharacterDescriptions': false,
        }).naisteraCharacterDescriptionsMode,
        CharacterDescriptionsMode.none,
      );
      expect(
        ImageGenSettingsCodec.fromJson({
          'naisteraSendCharacterDescriptions': true,
        }).naisteraCharacterDescriptionsMode,
        CharacterDescriptionsMode.asIs,
      );
    });
  });
}
