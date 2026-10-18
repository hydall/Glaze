import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/tensor_art_image_provider.dart';

Future<HttpServer> _startServer(
  List<String> bodies,
  Future<void> Function(HttpServer server, HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    bodies.add(await utf8.decoder.bind(request).join());
    await handler(server, request);
  });
  addTearDown(() => server.close(force: true));
  return server;
}

String _base(HttpServer server) =>
    'http://${server.address.address}:${server.port}/openworks/v1';

void _json(HttpRequest request, Map<String, dynamic> body) {
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
}

void main() {
  test('lists only image tools and parses their inputs', () async {
    final bodies = <String>[];
    final server = await _startServer(bodies, (server, request) async {
      expect(request.uri.path, '/openworks/v1/tool/list');
      expect(request.headers.value('Echo-Access-Key'), 'ak_tensor_test');
      _json(request, {
        'code': '0',
        'data': {
          'tools': [
            {
              'name': 'anime_lab_wai_illustrious',
              'description': 'text to image',
              'estimatedCost': '1.33',
              'inputs': [
                {'type': 'STRING', 'description': 'prompt'},
                {'type': 'INTEGER', 'description': 'image width'},
                {'type': 'INTEGER', 'description': 'image height'},
                {'type': 'INTEGER', 'description': 'result image count'},
              ],
              'outputs': [
                {'type': 'FILE', 'format': 'image'},
              ],
            },
            {
              'name': 'smart_edit',
              'description': 'image editing',
              'inputs': [
                {'type': 'STRING', 'description': 'editing prompt'},
                {
                  'type': 'ARRAY',
                  'description': 'source image',
                  'schema': {
                    'items': {
                      'required': ['url', 'mimeType', 'assetId'],
                    },
                  },
                },
              ],
              'outputs': [
                {'type': 'FILE', 'format': 'image'},
              ],
            },
            {
              'name': 'text2video',
              'description': 'video',
              'inputs': <Object>[],
              'outputs': [
                {'type': 'FILE', 'format': 'video'},
              ],
            },
          ],
        },
      });
      await request.response.close();
    });

    final tools = await TensorArtImageProvider().fetchTools(
      accessKey: 'ak_tensor_test',
      endpoint: _base(server),
    );

    expect(tools.map((tool) => tool.name), [
      'anime_lab_wai_illustrious',
      'smart_edit',
    ]);
    final anime = tools.first;
    expect(anime.usesIntegerDimensions, isTrue);
    expect(anime.usesStringDimensions, isFalse);
    expect(anime.usesCount, isTrue);
    expect(anime.supportsReferenceImages, isFalse);
    final edit = tools.last;
    expect(edit.supportsReferenceImages, isTrue);
    expect(edit.inputs.last.requiresAssetFields, isTrue);
  });

  test('submits a text-to-image task and downloads the result', () async {
    final bodies = <String>[];
    final server = await _startServer(bodies, (server, request) async {
      switch (request.uri.path) {
        case '/openworks/v1/task':
          _json(request, {
            'code': '0',
            'data': {
              'task': {'id': 'task-1', 'status': 'WAITING'},
            },
          });
          break;
        case '/openworks/v1/task/query':
          expect(bodies.last, contains('task-1'));
          _json(request, {
            'code': '0',
            'data': {
              'tasks': [
                {
                  'id': 'task-1',
                  'status': 'FINISH',
                  'outputs': [
                    {
                      'type': 'FILE',
                      'url':
                          'http://${server.address.address}:${server.port}/result.png',
                    },
                  ],
                },
              ],
            },
          });
          break;
        case '/result.png':
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(Uint8List.fromList([1, 2, 3]));
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final settings = TensorArtImageSettings(
      accessKey: 'ak_tensor_test',
      endpoint: _base(server),
      toolName: 'anime_lab_wai_illustrious',
      width: 832,
      height: 1216,
      count: 2,
      tools: const [
        TensorArtTool(
          name: 'anime_lab_wai_illustrious',
          inputs: [
            TensorArtToolInput(type: 'STRING', description: 'prompt'),
            TensorArtToolInput(type: 'INTEGER', description: 'image width'),
            TensorArtToolInput(type: 'INTEGER', description: 'image height'),
            TensorArtToolInput(
              type: 'INTEGER',
              description: 'result image count',
            ),
          ],
        ),
      ],
    );

    final image =
        await TensorArtImageProvider(
          pollInterval: const Duration(milliseconds: 1),
        ).generate(
          settings: settings,
          prompt: 'red-haired mage',
          references: const [],
        );

    expect(image, [1, 2, 3]);
    final taskBody = jsonDecode(bodies.first) as Map<String, dynamic>;
    expect(taskBody['toolName'], 'anime_lab_wai_illustrious');
    expect(taskBody['inputs'], ['red-haired mage', 832, 1216, 2]);
  });

  test('uploads references and sends them as an array', () async {
    final bodies = <String>[];
    final uploads = <String>[];
    final server = await _startServer(bodies, (server, request) async {
      switch (request.uri.path) {
        case '/openworks/v1/file/upload':
          _json(request, {
            'code': '0',
            'data': {
              'uploadUrl':
                  'http://${server.address.address}:${server.port}/upload',
              'displayUrl':
                  'http://${server.address.address}:${server.port}/ref.png',
            },
          });
          break;
        case '/upload':
          uploads.add(bodies.last);
          request.response.statusCode = HttpStatus.ok;
          break;
        case '/openworks/v1/task':
          _json(request, {
            'code': '0',
            'data': {
              'task': {'id': 'task-2', 'status': 'WAITING'},
            },
          });
          break;
        case '/openworks/v1/task/query':
          _json(request, {
            'code': '0',
            'data': {
              'tasks': [
                {
                  'id': 'task-2',
                  'status': 'FINISH',
                  'outputs': [
                    {
                      'url':
                          'http://${server.address.address}:${server.port}/result.png',
                    },
                  ],
                },
              ],
            },
          });
          break;
        case '/result.png':
          request.response.add(Uint8List.fromList([4, 5, 6]));
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final settings = TensorArtImageSettings(
      accessKey: 'ak_tensor_test',
      endpoint: _base(server),
      toolName: 'smart_edit',
      tools: const [
        TensorArtTool(
          name: 'smart_edit',
          inputs: [
            TensorArtToolInput(type: 'STRING', description: 'editing prompt'),
            TensorArtToolInput(type: 'ARRAY', description: 'source image'),
          ],
        ),
      ],
    );

    final image =
        await TensorArtImageProvider(
          pollInterval: const Duration(milliseconds: 1),
        ).generate(
          settings: settings,
          prompt: 'add a hat',
          references: const [
            {'image': 'aW1n', 'mime': 'image/png'},
          ],
        );

    expect(image, [4, 5, 6]);
    expect(uploads, ['img']);
    final taskBody =
        jsonDecode(bodies.firstWhere((body) => body.contains('toolName')))
            as Map<String, dynamic>;
    expect(taskBody['inputs'], [
      'add a hat',
      [
        {
          'url': 'http://${server.address.address}:${server.port}/ref.png',
          'mimeType': 'image/png',
        },
      ],
    ]);
  });

  test('checks the key through task/query', () async {
    final bodies = <String>[];
    final server = await _startServer(bodies, (server, request) async {
      expect(request.uri.path, '/openworks/v1/task/query');
      expect(request.headers.value('Echo-Access-Key'), 'ak_tensor_test');
      _json(request, {
        'code': '0',
        'data': {'tasks': <Object>[]},
      });
      await request.response.close();
    });

    await TensorArtImageProvider().checkConnection(
      accessKey: 'ak_tensor_test',
      endpoint: _base(server),
    );
  });
}
