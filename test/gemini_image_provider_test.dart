import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/services/gemini_image_provider.dart';

void main() {
  test(
    'uses legacy generateContent format and passes image context inline',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.uri.path, '/v1beta/models/gemini-image:generateContent');
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer key',
        );
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final parts =
            ((body['contents'] as List).single as Map)['parts'] as List;
        expect(parts.first, {
          'inlineData': {'mimeType': 'image/jpeg', 'data': 'aW1hZ2U='},
        });
        expect(parts.last, {'text': 'draw this'});
        expect((body['generationConfig'] as Map)['imageConfig'], {
          'aspectRatio': '16:9',
          'imageSize': '2K',
        });

        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'inlineData': {'mimeType': 'image/png', 'data': 'cG5n'},
                    },
                  ],
                },
              },
            ],
          }),
        );
        await request.response.close();
      });

      final image = await GeminiImageProvider().generate(
        endpoint: 'http://${server.address.address}:${server.port}',
        apiKey: 'key',
        model: 'gemini-image',
        prompt: 'draw this',
        aspectRatio: '16:9',
        imageSize: '2K',
        referenceImages: const [
          {'image': 'aW1hZ2U=', 'mime': 'image/jpeg'},
        ],
      );

      expect(image, utf8.encode('png'));
    },
  );
}
