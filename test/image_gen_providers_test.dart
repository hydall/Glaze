import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/a1111_image_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/comfyui_image_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/openai_image_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/openrouter_image_provider.dart';

/// Starts a loopback server that answers every request with [response] and
/// records what it received.
Future<(HttpServer, List<HttpRequest>, List<String>)> _server(
  Map<String, dynamic> response,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <HttpRequest>[];
  final bodies = <String>[];
  server.listen((request) async {
    requests.add(request);
    bodies.add(await utf8.decoder.bind(request).join());
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(response));
    await request.response.close();
  });
  return (server, requests, bodies);
}

void main() {
  group('OpenRouterImageProvider', () {
    test(
      'sends labelled references and image_config over chat completions',
      () async {
        final (server, requests, bodies) = await _server({
          'choices': [
            {
              'message': {
                'images': [
                  {
                    'image_url': {'url': 'data:image/png;base64,cG5n'},
                  },
                ],
              },
            },
          ],
        });
        addTearDown(() => server.close(force: true));

        final image = await OpenRouterImageProvider().generate(
          apiKey: 'key',
          endpoint: 'http://${server.address.address}:${server.port}',
          model: 'google/gemini-3-pro-image',
          prompt: 'Zoe waves',
          aspectRatio: '16:9',
          imageSize: '2K',
          references: const [
            {
              'image': 'aW1n',
              'mime': 'image/jpeg',
              'description': 'red-haired mage',
            },
          ],
        );

        expect(requests.single.uri.path, '/chat/completions');
        expect(
          requests.single.headers.value(HttpHeaders.authorizationHeader),
          'Bearer key',
        );
        final body = jsonDecode(bodies.single) as Map<String, dynamic>;
        expect(body['modalities'], ['image', 'text']);
        expect(body['image_config'], {
          'aspect_ratio': '16:9',
          'image_size': '2K',
        });
        final parts =
            ((body['messages'] as List).single as Map)['content'] as List;
        expect(parts[0], {
          'type': 'text',
          'text': 'Reference 1: red-haired mage',
        });
        expect(parts[1], {
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,aW1n'},
        });
        expect(parts[2], {'type': 'text', 'text': 'Zoe waves'});
        expect(image, utf8.encode('png'));
      },
    );

    test('omits image_size for models that do not take one', () async {
      final (server, _, bodies) = await _server({
        'choices': [
          {
            'message': {
              'images': [
                {'b64_json': 'cG5n'},
              ],
            },
          },
        ],
      });
      addTearDown(() => server.close(force: true));

      await OpenRouterImageProvider().generate(
        apiKey: 'key',
        endpoint: 'http://${server.address.address}:${server.port}',
        model: 'black-forest-labs/flux-1.1-pro',
        prompt: 'a cat',
        aspectRatio: '1:1',
        imageSize: '2K',
      );

      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      expect(body['image_config'], {'aspect_ratio': '1:1'});
      expect(body['modalities'], ['image']);
      expect(((body['messages'] as List).single as Map)['content'], 'a cat');
    });
  });

  group('OpenaiImageProvider', () {
    test('routes to /v1/images/generations without references', () async {
      final (server, requests, bodies) = await _server({
        'data': [
          {'b64_json': 'cG5n'},
        ],
      });
      addTearDown(() => server.close(force: true));

      await OpenaiImageProvider().generate(
        endpoint: 'http://${server.address.address}:${server.port}',
        apiKey: 'key',
        model: 'gpt-image-1',
        prompt: 'a cat',
        size: '1024x1024',
        quality: 'hd',
      );

      expect(requests.single.uri.path, '/v1/images/generations');
      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      expect(body['quality'], 'high');
      expect(body['moderation'], 'low');
      expect(body.containsKey('response_format'), isFalse);
    });

    test('routes to /v1/images/edits with references', () async {
      final (server, requests, bodies) = await _server({
        'data': [
          {'b64_json': 'cG5n'},
        ],
      });
      addTearDown(() => server.close(force: true));

      await OpenaiImageProvider().generate(
        endpoint: 'http://${server.address.address}:${server.port}',
        apiKey: 'key',
        model: 'gpt-image-1',
        prompt: 'a cat',
        size: '1024x1024',
        quality: 'standard',
        referenceImages: const ['aW1n', 'aW1n'],
      );

      expect(requests.single.uri.path, '/v1/images/edits');
      expect(
        requests.single.headers.contentType?.mimeType,
        'multipart/form-data',
      );
      // Two references on a gpt-image model are sent as a repeated image[].
      expect('image[]'.allMatches(bodies.single).length, 2);
    });

    test('drops references a model cannot use', () async {
      final (server, requests, _) = await _server({
        'data': [
          {'b64_json': 'cG5n'},
        ],
      });
      addTearDown(() => server.close(force: true));

      await OpenaiImageProvider().generate(
        endpoint: 'http://${server.address.address}:${server.port}',
        apiKey: 'key',
        model: 'dall-e-3',
        prompt: 'a cat',
        size: '1024x1024',
        quality: 'standard',
        referenceImages: const ['aW1n'],
      );

      expect(requests.single.uri.path, '/v1/images/generations');
    });

    test('Electron Hub mode never uses the repeated image[] field', () async {
      final (server, _, bodies) = await _server({
        'data': [
          {'b64_json': 'cG5n'},
        ],
      });
      addTearDown(() => server.close(force: true));

      await OpenaiImageProvider(allowMultiImageField: false).generate(
        endpoint: 'http://${server.address.address}:${server.port}',
        apiKey: 'key',
        model: 'gpt-image-1',
        prompt: 'a cat',
        size: '1024x1024',
        quality: 'standard',
        referenceImages: const ['aW1n', 'aW1n'],
      );

      expect(bodies.single, isNot(contains('image[]')));
      expect(bodies.single, contains('name="image"'));
    });
  });

  group('A1111ImageProvider', () {
    test('posts txt2img with the configured sampler and overrides', () async {
      final (server, requests, bodies) = await _server({
        'images': ['cG5n'],
      });
      addTearDown(() => server.close(force: true));

      final image = await A1111ImageProvider().generate(
        settings: A1111ImageSettings(
          endpoint: 'http://${server.address.address}:${server.port}',
          model: 'anythingXL.safetensors',
          promptPrefix: 'masterpiece',
          negativePrompt: 'lowres',
          sampler: 'DPM++ 2M',
          scheduler: 'Karras',
          steps: 28,
          cfgScale: 6.5,
          width: 832,
          height: 1216,
          clipSkip: 2,
          adetailerFace: true,
        ),
        prompt: '1girl, red hair',
      );

      expect(requests.single.uri.path, '/sdapi/v1/txt2img');
      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      expect(body['prompt'], 'masterpiece, 1girl, red hair');
      expect(body['negative_prompt'], 'lowres');
      expect(body['sampler_name'], 'DPM++ 2M');
      expect(body['scheduler'], 'Karras');
      expect(body['steps'], 28);
      expect(body['width'], 832);
      expect(body['height'], 1216);
      expect(
        (body['override_settings'] as Map)['sd_model_checkpoint'],
        'anythingXL.safetensors',
      );
      expect((body['override_settings'] as Map)['CLIP_stop_at_last_layers'], 2);
      expect(body['alwayson_scripts'], isNotNull);
      expect(image, utf8.encode('png'));
    });

    test('sends basic auth when an API key is configured', () async {
      final (server, requests, _) = await _server({
        'images': ['cG5n'],
      });
      addTearDown(() => server.close(force: true));

      await A1111ImageProvider().generate(
        settings: A1111ImageSettings(
          endpoint: 'http://${server.address.address}:${server.port}',
          apiKey: 'user:pass',
        ),
        prompt: 'a cat',
      );

      expect(
        requests.single.headers.value(HttpHeaders.authorizationHeader),
        'Basic ${base64Encode(utf8.encode('user:pass'))}',
      );
    });
  });

  group('ComfyUiImageProvider', () {
    test(
      'substitutes placeholders, polls history and fetches the view',
      () async {
        final routes = <String>[];
        Map<String, dynamic>? promptBody;
        Uri? viewUri;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          routes.add('${request.method} ${request.uri.path}');
          if (request.method == 'POST' && request.uri.path == '/prompt') {
            promptBody =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, dynamic>;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'prompt_id': 'pid-1'}));
          } else if (request.uri.path == '/history/pid-1') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'pid-1': {
                  'status': {'status_str': 'success'},
                  'outputs': {
                    '9': {
                      'images': [
                        {
                          'filename': 'Glaze_00001_.png',
                          'subfolder': '',
                          'type': 'output',
                        },
                      ],
                    },
                  },
                },
              }),
            );
          } else if (request.uri.path == '/view') {
            viewUri = request.uri;
            request.response.headers.contentType = ContentType.binary;
            request.response.add(utf8.encode('png'));
          }
          await request.response.close();
        });

        final image = await ComfyUiImageProvider().generate(
          settings: ComfyUiImageSettings(
            endpoint: 'http://${server.address.address}:${server.port}',
            model: 'anythingXL.safetensors',
            sampler: 'euler',
            scheduler: 'karras',
            steps: 28,
            cfgScale: 6.5,
            width: 832,
            height: 1216,
            seed: 42,
            promptPrefix: 'masterpiece',
            negativePrompt: 'lowres',
          ),
          prompt: 'a cat',
        );

        expect(routes, ['POST /prompt', 'GET /history/pid-1', 'GET /view']);
        expect(image, utf8.encode('png'));
        expect(viewUri!.queryParameters['filename'], 'Glaze_00001_.png');
        expect(viewUri!.queryParameters['type'], 'output');

        final workflow = promptBody!['prompt'] as Map<String, dynamic>;
        final sampler = (workflow['3'] as Map)['inputs'] as Map;
        expect(sampler['steps'], 28);
        expect(sampler['cfg'], 6.5);
        expect(sampler['sampler_name'], 'euler');
        expect(sampler['scheduler'], 'karras');
        expect(sampler['seed'], 42);
        expect(
          ((workflow['4'] as Map)['inputs'] as Map)['ckpt_name'],
          'anythingXL.safetensors',
        );
        expect(((workflow['5'] as Map)['inputs'] as Map)['width'], 832);
        expect(((workflow['5'] as Map)['inputs'] as Map)['height'], 1216);
        expect(
          ((workflow['6'] as Map)['inputs'] as Map)['text'],
          'masterpiece, a cat',
        );
        expect(((workflow['7'] as Map)['inputs'] as Map)['text'], 'lowres');
      },
    );

    test('reports a node traceback from an errored history item', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.method == 'POST' && request.uri.path == '/prompt') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'prompt_id': 'pid-2'}));
        } else if (request.uri.path == '/history/pid-2') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'pid-2': {
                'status': {
                  'status_str': 'error',
                  'messages': [
                    [
                      'execution_error',
                      {
                        'node_type': 'KSampler',
                        'node_id': 3,
                        'exception_type': 'ValueError',
                        'exception_message': 'bad seed',
                      },
                    ],
                  ],
                },
                'outputs': <String, dynamic>{},
              },
            }),
          );
        }
        await request.response.close();
      });

      await expectLater(
        ComfyUiImageProvider().generate(
          settings: ComfyUiImageSettings(
            endpoint: 'http://${server.address.address}:${server.port}',
          ),
          prompt: 'a cat',
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains('KSampler [3] ValueError'),
          ),
        ),
      );
    });
  });
}
