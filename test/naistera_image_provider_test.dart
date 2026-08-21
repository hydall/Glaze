import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/services/naistera_image_provider.dart';

void main() {
  /// Serves canned JSON and records every request, so the tests can assert on
  /// the path/method the client actually used.
  Future<
    ({
      String baseUrl,
      List<({String method, String path, Map<String, dynamic>? body})> requests,
    })
  >
  startServer(List<Map<String, dynamic>> responses) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests =
        <({String method, String path, Map<String, dynamic>? body})>[];
    var index = 0;
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      requests.add((
        method: request.method,
        path: request.uri.path,
        body: raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>,
      ));
      final response = responses[index.clamp(0, responses.length - 1)];
      index++;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    return (
      baseUrl: 'http://${server.address.host}:${server.port}',
      requests: requests,
    );
  }

  group('NaisteraImageProvider', () {
    test('posts to /api/generate and decodes data_url', () async {
      final server = await startServer([
        {'data_url': 'data:image/png;base64,AQI=', 'content_type': 'image/png'},
      ]);

      final bytes = await NaisteraImageProvider(
        baseUrl: server.baseUrl,
      ).generate(
        apiKey: 'key',
        model: 'grok',
        prompt: 'a cat',
        aspectRatio: '16:9',
      );

      expect(bytes, [1, 2]);
      expect(server.requests.single.method, 'POST');
      expect(server.requests.single.path, '/api/generate');
      expect(server.requests.single.body, {
        'prompt': 'a cat',
        'aspect_ratio': '16:9',
        'model': 'grok',
      });
    });

    test('sends references as data URLs in reference_objects', () async {
      final server = await startServer([
        {'data_url': 'data:image/png;base64,AQI='},
      ]);

      await NaisteraImageProvider(baseUrl: server.baseUrl).generate(
        apiKey: 'key',
        model: 'nano banana 2',
        prompt: 'a cat',
        aspectRatio: '1:1',
        references: [
          {
            'name': 'Mia',
            'image': 'AQI=',
            'mime': 'image/jpeg',
            'description': 'Mia',
            'source': 'char',
          },
          {
            'name': 'ctx',
            'image': 'data:image/png;base64,AQI=',
            'mime': 'image/png',
            'description': '',
            'source': 'context',
          },
        ],
      );

      expect(server.requests.single.body!['reference_objects'], [
        {'image': 'data:image/jpeg;base64,AQI=', 'description': 'Mia'},
        {'image': 'data:image/png;base64,AQI=', 'description': ''},
      ]);
    });

    test('drops references for models that do not accept them', () async {
      final server = await startServer([
        {'data_url': 'data:image/png;base64,AQI='},
      ]);

      await NaisteraImageProvider(baseUrl: server.baseUrl).generate(
        apiKey: 'key',
        model: 'novelai',
        prompt: 'a cat',
        aspectRatio: '1:1',
        references: [
          {'image': 'AQI=', 'mime': 'image/png', 'description': 'Mia'},
        ],
      );

      expect(
        server.requests.single.body!.containsKey('reference_objects'),
        isFalse,
      );
    });

    test('normalizes a retired model label', () async {
      final server = await startServer([
        {'data_url': 'data:image/png;base64,AQI='},
      ]);

      await NaisteraImageProvider(baseUrl: server.baseUrl).generate(
        apiKey: 'key',
        model: 'nano banana',
        prompt: 'a cat',
        aspectRatio: '1:1',
      );

      expect(server.requests.single.body!['model'], 'nano banana 2');
    });

    test('polls the job endpoint when the response is async', () async {
      final server = await startServer([
        {'job_id': 'job1'},
        {'status': 'pending'},
        {'status': 'completed', 'data_url': 'data:image/png;base64,AQI='},
      ]);

      final bytes = await NaisteraImageProvider(
        baseUrl: server.baseUrl,
        pollInterval: const Duration(milliseconds: 10),
      ).generate(
        apiKey: 'key',
        model: 'grok',
        prompt: 'a cat',
        aspectRatio: '1:1',
      );

      expect(bytes, [1, 2]);
      expect(server.requests.map((r) => r.method).toList(), [
        'POST',
        'GET',
        'GET',
      ]);
      expect(server.requests.last.path, '/api/generate/jobs/job1');
    });

    test('reports a failed job instead of hanging', () async {
      final server = await startServer([
        {'job_id': 'job1'},
        {'status': 'failed', 'detail': 'moderation'},
      ]);

      await expectLater(
        NaisteraImageProvider(
          baseUrl: server.baseUrl,
          pollInterval: const Duration(milliseconds: 10),
        ).generate(
          apiKey: 'key',
          model: 'grok',
          prompt: 'a cat',
          aspectRatio: '1:1',
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('moderation'),
          ),
        ),
      );
    });
  });
}
