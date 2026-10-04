import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_capabilities.dart';
import 'package:glaze_flutter/features/image_gen/services/xai_image_provider.dart';

void main() {
  /// Serves one canned JSON response and captures the request the client made.
  Future<
    ({
      XaiImageProvider provider,
      Future<({String path, Map<String, dynamic> body})> request,
    })
  >
  createProvider(Map<String, dynamic> responseBody) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final request = server.first.then((httpRequest) async {
      final body =
          jsonDecode(await utf8.decoder.bind(httpRequest).join())
              as Map<String, dynamic>;
      httpRequest.response.headers.contentType = ContentType.json;
      httpRequest.response.write(jsonEncode(responseBody));
      await httpRequest.response.close();
      return (path: httpRequest.uri.path, body: body);
    });
    return (
      provider: XaiImageProvider(
        baseUrl: 'http://${server.address.host}:${server.port}',
      ),
      request: request,
    );
  }

  Map<String, String> reference(String image) => {
    'name': 'Lucy',
    'image': image,
    'mime': 'image/jpeg',
    'description': 'red hair',
    'source': 'additional',
  };

  group('XaiImageProvider routing', () {
    test('goes to /v1/images/generations without references', () async {
      final server = await createProvider({
        'data': [
          {'b64_json': 'AQ=='},
        ],
      });

      final bytes = await server.provider.generate(
        apiKey: 'xai-key',
        model: 'grok-imagine-image-2.0',
        prompt: 'a castle',
        aspectRatio: '16:9',
        resolution: '2k',
        quality: 'low',
      );
      final request = await server.request;

      expect(bytes, [1]);
      expect(request.path, '/v1/images/generations');
      expect(request.body['aspect_ratio'], '16:9');
      expect(request.body['resolution'], '2k');
      expect(request.body['quality'], 'low');
      expect(request.body['response_format'], 'b64_json');
      expect(request.body.containsKey('image'), isFalse);
      expect(request.body.containsKey('images'), isFalse);
    });

    test('sends one reference on /v1/images/edits as `image`', () async {
      final server = await createProvider({
        'data': [
          {'b64_json': 'AQ=='},
        ],
      });

      await server.provider.generate(
        apiKey: 'xai-key',
        model: 'grok-imagine-image-2.0',
        prompt: 'a castle',
        aspectRatio: '1:1',
        resolution: '1k',
        quality: 'medium',
        references: [reference('QUJD')],
      );
      final request = await server.request;

      expect(request.path, '/v1/images/edits');
      expect(request.body.containsKey('images'), isFalse);
      expect(request.body['image'], {
        'type': 'image_url',
        'url': 'data:image/jpeg;base64,QUJD',
      });
    });

    test('sends several references as `images`, capped at three', () async {
      final server = await createProvider({
        'data': [
          {'b64_json': 'AQ=='},
        ],
      });

      await server.provider.generate(
        apiKey: 'xai-key',
        model: 'grok-imagine-image',
        prompt: 'a castle',
        aspectRatio: '1:1',
        resolution: '1k',
        quality: 'medium',
        references: [
          reference('QQ=='),
          reference('Qg=='),
          reference('Qw=='),
          reference('RA=='),
        ],
      );
      final request = await server.request;

      expect(request.path, '/v1/images/edits');
      expect(request.body.containsKey('image'), isFalse);
      expect((request.body['images'] as List).length, 3);
    });

    test('a generation-only model never reaches /edits', () async {
      final server = await createProvider({
        'data': [
          {'b64_json': 'AQ=='},
        ],
      });

      await server.provider.generate(
        apiKey: 'xai-key',
        model: 'grok-2-image',
        prompt: 'a castle',
        aspectRatio: '1:1',
        resolution: '1k',
        quality: 'medium',
        references: [reference('QUJD')],
      );
      final request = await server.request;

      expect(request.path, '/v1/images/generations');
      expect(request.body.containsKey('image'), isFalse);
    });

    test('omits quality for models that reject it', () async {
      final server = await createProvider({
        'data': [
          {'b64_json': 'AQ=='},
        ],
      });

      await server.provider.generate(
        apiKey: 'xai-key',
        model: 'grok-imagine-image',
        prompt: 'a castle',
        aspectRatio: '1:1',
        resolution: '1k',
        quality: 'low',
      );

      expect((await server.request).body.containsKey('quality'), isFalse);
    });

    test('keeps a reference that already is a data URL', () async {
      final server = await createProvider({
        'data': [
          {'b64_json': 'AQ=='},
        ],
      });

      await server.provider.generate(
        apiKey: 'xai-key',
        model: 'grok-imagine-image-2.0',
        prompt: 'a castle',
        aspectRatio: '1:1',
        resolution: '1k',
        quality: 'medium',
        references: [
          {'image': 'data:image/png;base64,QQ==', 'mime': 'image/jpeg'},
        ],
      );

      expect((await server.request).body['image'], {
        'type': 'image_url',
        'url': 'data:image/png;base64,QQ==',
      });
    });
  });

  group('XaiConstants', () {
    test('strips a trailing /v1 and falls back to the public endpoint', () {
      expect(XaiConstants.normalizeEndpoint(''), 'https://api.x.ai');
      expect(XaiConstants.normalizeEndpoint('  '), 'https://api.x.ai');
      expect(
        XaiConstants.normalizeEndpoint('https://proxy.example/v1'),
        'https://proxy.example',
      );
      expect(
        XaiConstants.normalizeEndpoint('https://proxy.example/v1/'),
        'https://proxy.example',
      );
    });

    test('normalizes the tag-supplied parameters', () {
      expect(XaiConstants.normalizeAspectRatio('42:1'), '1:1');
      expect(XaiConstants.normalizeAspectRatio('19.5:9'), '19.5:9');
      expect(XaiConstants.normalizeResolution('4K'), '1k');
      expect(XaiConstants.normalizeResolution('2K'), '2k');
      expect(XaiConstants.normalizeQuality('hd'), 'medium');
      expect(XaiConstants.normalizeQuality('LOW'), 'low');
    });

    test('reference support is decided per model, not per provider', () {
      expect(XaiConstants.supportsReferences('grok-imagine-image-2.0'), isTrue);
      expect(XaiConstants.supportsReferences('grok-2-image'), isFalse);

      const base = ImageGenSettings(apiType: ImageGenApiType.xai);
      expect(
        providerMaxReferences(
          base.copyWith(xai: const XaiImageSettings(model: 'grok-2-image')),
        ),
        0,
      );
      expect(
        providerMaxReferences(
          base.copyWith(
            xai: const XaiImageSettings(model: 'grok-imagine-image-2.0'),
          ),
        ),
        XaiConstants.maxReferences,
      );
    });
  });
}
