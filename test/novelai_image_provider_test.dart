import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/novelai_image_provider.dart';

/// Starts a loopback server that answers every request with the raw [bytes].
Future<(HttpServer, List<HttpRequest>, List<String>)> _byteServer(
  List<int> bytes, {
  String contentType = 'application/zip',
  int status = 200,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <HttpRequest>[];
  final bodies = <String>[];
  server.listen((request) async {
    requests.add(request);
    bodies.add(await utf8.decoder.bind(request).join());
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.parse(contentType);
    request.response.add(bytes);
    await request.response.close();
  });
  return (server, requests, bodies);
}

List<int> _zip(String name, List<int> data) {
  final archive = Archive()..addFile(ArchiveFile(name, data.length, data));
  return ZipEncoder().encode(archive);
}

String _endpoint(HttpServer server) =>
    'http://${server.address.address}:${server.port}';

void main() {
  group('NovelAIImageProvider', () {
    test('posts a v4 prompt with bearer auth and unwraps the ZIP', () async {
      final (server, requests, bodies) = await _byteServer(
        Uint8List.fromList(_zip('image.png', utf8.encode('png'))),
      );
      addTearDown(() => server.close(force: true));

      final image = await NovelAIImageProvider().generate(
        settings: NovelAIImageSettings(
          apiKey: 'tok',
          endpoint: _endpoint(server),
          model: 'nai-diffusion-4-5-full',
          negativePrompt: 'bad hands',
          ucPreset: 'light',
          qualityToggle: true,
          steps: 30,
          scale: 6,
          width: 832,
          height: 1216,
        ),
        prompt: '1girl, red hair',
      );

      expect(requests.single.uri.path, '/ai/generate-image');
      expect(
        requests.single.headers.value(HttpHeaders.authorizationHeader),
        'Bearer tok',
      );

      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      expect(body['model'], 'nai-diffusion-4-5-full');
      expect(body['action'], 'generate');
      // The web UI sends the quality-processed prompt as `input`.
      expect(body['input'], contains('1girl, red hair'));
      expect(body['input'], contains('very aesthetic'));
      expect(body['use_new_shared_trial'], isTrue);

      final params = body['parameters'] as Map<String, dynamic>;
      expect(params['params_version'], 3);
      expect(params['width'], 832);
      expect(params['height'], 1216);
      expect(params['steps'], 30);
      expect(params['scale'], 6);
      expect(params['sampler'], 'k_euler_ancestral');
      expect(params['characterPrompts'], isEmpty);
      expect(params.containsKey('prompt'), isFalse);

      final v4Prompt = params['v4_prompt'] as Map<String, dynamic>;
      final caption = v4Prompt['caption'] as Map<String, dynamic>;
      expect(caption['base_caption'], contains('1girl, red hair'));
      expect(caption['base_caption'], contains('very aesthetic'));
      expect(caption['char_captions'], isEmpty);
      expect(v4Prompt['use_coords'], isFalse);
      expect(v4Prompt['use_order'], isTrue);
      expect(params['negative_prompt'], contains('bad hands'));
      expect(params['negative_prompt'], contains('lowres'));

      final v4Negative = params['v4_negative_prompt'] as Map<String, dynamic>;
      expect(
        (v4Negative['caption'] as Map)['base_caption'],
        params['negative_prompt'],
      );
      expect(v4Negative['legacy_uc'], isFalse);
      expect(v4Negative.containsKey('use_coords'), isFalse);

      expect(image, utf8.encode('png'));
    });

    test('V3 keeps a plain prompt and omits v4 captions', () async {
      final (server, _, bodies) = await _byteServer(
        Uint8List.fromList(_zip('image.png', utf8.encode('png'))),
      );
      addTearDown(() => server.close(force: true));

      await NovelAIImageProvider().generate(
        settings: NovelAIImageSettings(
          apiKey: 'tok',
          endpoint: _endpoint(server),
          model: 'nai-diffusion-3',
          qualityToggle: false,
        ),
        prompt: 'a cat',
      );

      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      final params = body['parameters'] as Map<String, dynamic>;
      expect(params['prompt'], 'a cat');
      expect(params.containsKey('v4_prompt'), isFalse);
      expect(params.containsKey('v4_negative_prompt'), isFalse);
    });

    test('V5 bumps params_version to 4', () async {
      final (server, _, bodies) = await _byteServer(
        Uint8List.fromList(_zip('image.png', utf8.encode('png'))),
      );
      addTearDown(() => server.close(force: true));

      await NovelAIImageProvider().generate(
        settings: NovelAIImageSettings(
          apiKey: 'tok',
          endpoint: _endpoint(server),
          model: 'nai-diffusion-5-full',
        ),
        prompt: 'a cat',
      );

      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      final params = body['parameters'] as Map<String, dynamic>;
      expect(params['params_version'], 4);
      expect(params.containsKey('v4_prompt'), isTrue);
    });

    test('attaches director references on V4.5 only', () async {
      final (server, _, bodies) = await _byteServer(
        Uint8List.fromList(_zip('image.png', utf8.encode('png'))),
      );
      addTearDown(() => server.close(force: true));

      await NovelAIImageProvider().generate(
        settings: NovelAIImageSettings(
          apiKey: 'tok',
          endpoint: _endpoint(server),
          model: 'nai-diffusion-4-5-full',
        ),
        prompt: 'Zoe waves',
        references: const [
          {'image': 'aW1n'},
          {'image': 'cG5n'},
        ],
      );

      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      final params = body['parameters'] as Map<String, dynamic>;
      expect(params['director_reference_images'], ['aW1n', 'cG5n']);
      expect(
        (params['director_reference_descriptions'] as List).length,
        2,
      );
      expect(params['director_reference_strength_values'], [1.0, 1.0]);
      expect(params['director_reference_secondary_strength_values'], [0.0, 0.0]);
      expect(params['director_reference_information_extracted'], [1.0, 1.0]);
    });

    test('drops references on models without Director Tools', () async {
      final (server, _, bodies) = await _byteServer(
        Uint8List.fromList(_zip('image.png', utf8.encode('png'))),
      );
      addTearDown(() => server.close(force: true));

      await NovelAIImageProvider().generate(
        settings: NovelAIImageSettings(
          apiKey: 'tok',
          endpoint: _endpoint(server),
          model: 'nai-diffusion-3',
        ),
        prompt: 'Zoe waves',
        references: const [
          {'image': 'aW1n'},
        ],
      );

      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      final params = body['parameters'] as Map<String, dynamic>;
      expect(params.containsKey('director_reference_images'), isFalse);
    });

    test('maps a per-tag aspect ratio onto a preset resolution', () async {
      final (server, _, bodies) = await _byteServer(
        Uint8List.fromList(_zip('image.png', utf8.encode('png'))),
      );
      addTearDown(() => server.close(force: true));

      await NovelAIImageProvider().generate(
        settings: NovelAIImageSettings(
          apiKey: 'tok',
          endpoint: _endpoint(server),
          model: 'nai-diffusion-4-5-full',
          width: 832,
          height: 1216,
        ),
        prompt: 'a cat',
        instructionAspectRatio: '16:9',
      );

      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      final params = body['parameters'] as Map<String, dynamic>;
      expect(params['width'], 1216);
      expect(params['height'], 832);
    });

    test('accepts the official JSON image response', () async {
      final (server, _, _) = await _byteServer(
        utf8.encode(
          jsonEncode({
            'images': [
              {'image': base64Encode(utf8.encode('png')), 'index': 0},
            ],
          }),
        ),
        contentType: 'application/json',
      );
      addTearDown(() => server.close(force: true));

      final image = await NovelAIImageProvider().generate(
        settings: NovelAIImageSettings(
          apiKey: 'tok',
          endpoint: _endpoint(server),
        ),
        prompt: 'a cat',
      );

      expect(image, utf8.encode('png'));
    });

    test('accepts a bare base64 image response from a proxy', () async {
      final (server, _, _) = await _byteServer(
        utf8.encode(jsonEncode({'image': base64Encode(utf8.encode('png'))})),
        contentType: 'application/json',
      );
      addTearDown(() => server.close(force: true));

      final image = await NovelAIImageProvider().generate(
        settings: NovelAIImageSettings(
          apiKey: 'tok',
          endpoint: _endpoint(server),
        ),
        prompt: 'a cat',
      );

      expect(image, utf8.encode('png'));
    });

    test('accepts raw image bytes', () async {
      final png = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2];
      final (server, _, _) = await _byteServer(png, contentType: 'image/png');
      addTearDown(() => server.close(force: true));

      final image = await NovelAIImageProvider().generate(
        settings: NovelAIImageSettings(
          apiKey: 'tok',
          endpoint: _endpoint(server),
        ),
        prompt: 'a cat',
      );

      expect(image, png);
    });

    test('keeps the provider message on a rejected request', () async {
      // The success payload is a ZIP, so the request asks for bytes; a JSON
      // error body must still be decoded or `formatError` cannot show it.
      final (server, _, _) = await _byteServer(
        utf8.encode(
          jsonEncode({
            'statusCode': 400,
            'message': 'model must be a valid enum value',
          }),
        ),
        contentType: 'application/json',
        status: 400,
      );
      addTearDown(() => server.close(force: true));

      try {
        await NovelAIImageProvider().generate(
          settings: NovelAIImageSettings(
            apiKey: 'tok',
            endpoint: _endpoint(server),
          ),
          prompt: 'a cat',
        );
        fail('expected a DioException');
      } on DioException catch (error) {
        expect(error.response?.data, isA<Map<String, dynamic>>());
        expect(
          (error.response!.data as Map<String, dynamic>)['message'],
          'model must be a valid enum value',
        );
      }
    });
  });

  group('NovelAIConstants', () {
    test('classifies model families', () {
      expect(NovelAIConstants.isV4('nai-diffusion-4-5-full'), isTrue);
      expect(NovelAIConstants.isV5('nai-diffusion-5-curated'), isTrue);
      expect(NovelAIConstants.isV4('nai-diffusion-3'), isFalse);
      expect(NovelAIConstants.supportsReferences('nai-diffusion-4-5-full'), isTrue);
      expect(NovelAIConstants.supportsReferences('nai-diffusion-5-full'), isFalse);
      expect(NovelAIConstants.supportsReferences('nai-diffusion-3'), isFalse);
    });

    test('ships the current model ids', () {
      final ids = NovelAIConstants.models.map((model) => model.$1).toList();
      expect(ids, contains('nai-diffusion-5-full'));
      expect(ids, contains('nai-diffusion-4-5-full'));
      expect(ids, contains('nai-diffusion-3'));
      expect(ids, contains('nai-diffusion-furry-3'));
      expect(ids, contains('nai-diffusion-4-curated-preview'));
      expect(ids, isNot(contains('nai-diffusion-3-furry')));
      expect(ids, isNot(contains('nai-diffusion-4-curated')));
    });

    test('maps uc presets to their wire integers', () {
      expect(NovelAIConstants.ucPresetIndex('heavy'), 0);
      expect(NovelAIConstants.ucPresetIndex('light'), 1);
      expect(NovelAIConstants.ucPresetIndex('furry_focus'), 2);
      expect(NovelAIConstants.ucPresetIndex('human_focus'), 3);
      // No wire value for "no preset"; it must stay inside 0-3.
      expect(NovelAIConstants.ucPresetIndex(NovelAIConstants.ucPresetNone), 0);
      expect(NovelAIConstants.ucPresetIndex('nonsense'), 0);
    });

    test('ships the per-model undesired-content presets', () {
      expect(
        NovelAIConstants.ucPresetText('nai-diffusion-4-5-full', 'light'),
        'lowres, artistic error, scan artifacts, worst quality, bad quality, '
        'jpeg artifacts, multiple views, very displeasing, too many watermarks, '
        'negative space, blank page',
      );
      expect(
        NovelAIConstants.ucPresetText('nai-diffusion-5-full', 'light'),
        'lowres, bad hands, bad anatomy, artistic error, sepia, white haze, '
        'worst quality, very displeasing, jpeg artifacts, 0::ai-generated::',
      );
      expect(
        NovelAIConstants.ucPresetText('nai-diffusion-4-5-curated', 'heavy'),
        'blurry, lowres, upscaled, artistic error, film grain, scan artifacts, '
        'worst quality, bad quality, jpeg artifacts, very displeasing, '
        'chromatic aberration, halftone, multiple views, logo, too many '
        'watermarks, negative space, blank page',
      );
      // The curated V4.5 model has no furry-focus preset.
      expect(
        NovelAIConstants.ucPresetText('nai-diffusion-4-5-curated', 'furry_focus'),
        '',
      );
      expect(
        NovelAIConstants.ucPresetText('nai-diffusion-3', 'human_focus'),
        contains('bad anatomy, bad hands'),
      );
      expect(
        NovelAIConstants.ucPresetText('nai-diffusion-furry-3', 'light'),
        '{worst quality}, guide lines, unfinished, bad, url, tall image, '
        'widescreen, compression artifacts, unknown text',
      );
      expect(
        NovelAIConstants.ucPresetText('nai-diffusion-4-5-full', 'none'),
        '',
      );
    });

    test('builds the negative prompt like the web UI', () {
      // Preset first, then the user's own text.
      expect(
        NovelAIConstants.resolveNegativePrompt(
          model: 'nai-diffusion-4-5-full',
          presetId: 'light',
          userNegative: 'my bad',
        ),
        contains('blank page, my bad'),
      );
      // Non-curated models get the nsfw guard.
      expect(
        NovelAIConstants.resolveNegativePrompt(
          model: 'nai-diffusion-4-5-full',
          presetId: 'light',
          userNegative: '',
        ),
        startsWith('nsfw, lowres'),
      );
      // Curated models do not.
      expect(
        NovelAIConstants.resolveNegativePrompt(
          model: 'nai-diffusion-4-5-curated',
          presetId: 'light',
          userNegative: '',
        ),
        startsWith('blurry, lowres'),
      );
      // An existing nsfw tag suppresses the guard.
      expect(
        NovelAIConstants.resolveNegativePrompt(
          model: 'nai-diffusion-4-5-full',
          presetId: 'light',
          userNegative: 'nsfw, extra',
        ),
        isNot(startsWith('nsfw, nsfw')),
      );
      // No preset means only the user's text.
      expect(
        NovelAIConstants.resolveNegativePrompt(
          model: 'nai-diffusion-4-5-full',
          presetId: NovelAIConstants.ucPresetNone,
          userNegative: 'my bad',
        ),
        'my bad',
      );
    });

    test('uses the per-model quality tags from the web app', () {
      expect(
        NovelAIConstants.qualityTagsFor('nai-diffusion-5-full'),
        'very aesthetic, masterpiece, no text',
      );
      expect(
        NovelAIConstants.qualityTagsFor('nai-diffusion-4-5-full'),
        'very aesthetic, masterpiece, no text',
      );
      expect(
        NovelAIConstants.qualityTagsFor('nai-diffusion-4-5-curated'),
        'very aesthetic, masterpiece, no text, -0.8::feet::, rating:general',
      );
      expect(
        NovelAIConstants.qualityTagsFor('nai-diffusion-4-full'),
        'no text, best quality, very aesthetic, absurdres',
      );
      expect(
        NovelAIConstants.qualityTagsFor('nai-diffusion-4-curated-preview'),
        'rating:general, best quality, very aesthetic, absurdres',
      );
      expect(
        NovelAIConstants.qualityTagsFor('nai-diffusion-3'),
        'best quality, amazing quality, very aesthetic, absurdres',
      );
      expect(
        NovelAIConstants.qualityTagsFor('nai-diffusion-furry-3'),
        '{best quality}, {amazing quality}',
      );
      expect(
        NovelAIConstants.qualityTagsFor('some-custom-model'),
        'very aesthetic, masterpiece, no text',
      );
      expect(
        NovelAIConstants.applyQualityTags('a cat', 'nai-diffusion-3'),
        'a cat, best quality, amazing quality, very aesthetic, absurdres',
      );
    });

    test('maps aspect ratios onto resolutions', () {
      expect(NovelAIConstants.sizeForAspect('1:1'), (1024, 1024));
      expect(NovelAIConstants.sizeForAspect('9:16'), (832, 1216));
      expect(NovelAIConstants.sizeForAspect('16:9'), (1216, 832));
      expect(NovelAIConstants.sizeForAspect('21:9'), isNull);
    });
  });
}
