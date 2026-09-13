import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/services/catalog_http.dart';
import 'package:glaze_flutter/features/catalog/services/datacat_provider.dart';
import 'package:glaze_flutter/features/catalog/services/janny_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers every catalog request from [reply], and keeps what was asked.
///
/// [reply] receives the request and how many requests came before it, so a
/// test can refuse the first attempt and serve the retry.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.reply);

  final ({int status, String body}) Function(RequestOptions options, int index)
  reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final answer = reply(options, requests.length);
    requests.add(options);
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The body DataCat answers a request made with a token it has forgotten —
/// the Cloudflare Turnstile blob from the report.
const _refused =
    '{"success":false,"serverInstanceId":"main-4330-v26b",'
    '"hostname":"datacat.run","turnstile":{"action":"character-card-download"},'
    '"lease":{"leaseValid":false}}';

const _card =
    '{"character":{"name":"Yixuan","personality":"a body",'
    '"first_message":"hello"}}';

String? _header(RequestOptions options, String name) =>
    options.headers[name]?.toString();

Map<String, dynamic> _query(RequestOptions options) =>
    ((jsonDecode(options.data as String) as Map<String, dynamic>)['queries']
            as List)
        .first
    as Map<String, dynamic>;

void main() {
  group('DataCat re-establishes a session the server has forgotten', () {
    test('the card detail recovers instead of dead-ending on 403', () async {
      SharedPreferences.setMockInitialValues({'gz_dc_token': 'stale'});
      final adapter = _ScriptedAdapter((options, index) {
        if (options.path.contains('/liberator/identify')) {
          return (status: 200, body: '{"sessionToken":"fresh"}');
        }
        return _header(options, 'X-Session-Token') == 'fresh'
            ? (status: 200, body: _card)
            : (status: 403, body: _refused);
      });
      setCatalogHttpAdapter(adapter);

      final downloaded = await datacatGetCharacter('uuid-1');

      expect(downloaded.charData.name, 'Yixuan');
      // Refused, re-identified, asked again — and the fresh token is the one
      // the next call starts from.
      expect(adapter.requests.map((r) => r.uri.path), [
        '/api/characters/uuid-1',
        '/api/liberator/identify',
        '/api/characters/uuid-1',
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gz_dc_token'), 'fresh');
    });

    test('browsing recovers on its own, with no probe request first', () async {
      SharedPreferences.setMockInitialValues({'gz_dc_token': 'stale'});
      final adapter = _ScriptedAdapter((options, index) {
        if (options.path.contains('/liberator/identify')) {
          return (status: 200, body: '{"sessionToken":"fresh"}');
        }
        return _header(options, 'X-Session-Token') == 'fresh'
            ? (status: 200, body: '{"characters":[],"totalCount":0}')
            : (status: 401, body: 'unauthorized');
      });
      setCatalogHttpAdapter(adapter);

      await datacatBrowse(filters: const CatalogFilters(sort: 'recent'));

      expect(adapter.requests, hasLength(3));
      expect(adapter.requests.first.uri.path, '/api/characters/recent-public');
    });

    test('bot protection a fresh session cannot cure is asked once', () async {
      SharedPreferences.setMockInitialValues({'gz_dc_token': 'stale'});
      final adapter = _ScriptedAdapter((options, index) {
        if (options.path.contains('/liberator/identify')) {
          return (status: 200, body: '{"sessionToken":"fresh"}');
        }
        return (status: 403, body: _refused);
      });
      setCatalogHttpAdapter(adapter);

      await expectLater(
        datacatGetCharacter('uuid-1'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            403,
          ),
        ),
      );
      expect(
        adapter.requests.where((r) => r.uri.path == '/api/characters/uuid-1'),
        hasLength(2),
      );
    });

    test('a failure that is not about the token is not retried', () async {
      SharedPreferences.setMockInitialValues({'gz_dc_token': 'stale'});
      final adapter = _ScriptedAdapter(
        (options, index) => (status: 500, body: 'boom'),
      );
      setCatalogHttpAdapter(adapter);

      await expectLater(datacatGetCharacter('uuid-1'), throwsA(anything));
      expect(adapter.requests, hasLength(1));
    });
  });

  group('Janny asks a rejected search again more plainly', () {
    test('a 400 drops the sort, then the preferences', () async {
      SharedPreferences.setMockInitialValues({'gz_janny_token': 'tok'});
      final adapter = _ScriptedAdapter(
        (options, index) => index < 2
            ? (
                status: 400,
                body:
                    '{"message":"Attribute totalToken is not filterable.",'
                    '"code":"invalid_search_filter"}',
              )
            : (
                status: 200,
                body:
                    '{"results":[{"hits":[{"id":"1","name":"Kept"}],'
                    '"totalHits":1}]}',
              ),
      );
      setCatalogHttpAdapter(adapter);

      final result = await jannySearch(
        query: 'x',
        filters: const CatalogFilters(sort: 'newest', minTokens: 500),
      );

      expect(result.characters.single.name, 'Kept');
      expect(adapter.requests, hasLength(3));
      final bodies = adapter.requests.map(_query).toList();
      expect(bodies[0]['sort'], ['createdAtStamp:desc']);
      expect(bodies[1].containsKey('sort'), isFalse);
      expect(bodies[1]['filter'], contains('totalToken >= 500'));
      expect(bodies[2]['filter'], 'isNsfw = false');
    });

    test(
      'a degraded search never drops what the reader asked not to see',
      () async {
        SharedPreferences.setMockInitialValues({'gz_janny_token': 'tok'});
        final adapter = _ScriptedAdapter(
          (options, index) => (status: 400, body: '{"message":"bad syntax"}'),
        );
        setCatalogHttpAdapter(adapter);

        await expectLater(
          jannySearch(filters: const CatalogFilters(nsfw: false)),
          throwsA(anything),
        );
        expect(adapter.requests, isNotEmpty);
        for (final body in adapter.requests.map(_query)) {
          expect(body['filter'], contains('isNsfw = false'));
        }
      },
    );

    test('the request asks for nothing the result is not read for', () async {
      SharedPreferences.setMockInitialValues({'gz_janny_token': 'tok'});
      final adapter = _ScriptedAdapter(
        (options, index) => (status: 200, body: '{"results":[]}'),
      );
      setCatalogHttpAdapter(adapter);

      await jannySearch(query: 'x');

      final body = _query(adapter.requests.single);
      // Every one of these lands in Meilisearch's `_formatted` block or its
      // facet distribution, neither of which the provider reads — and every
      // one is a clause the backend can reject with a 400.
      expect(body.containsKey('facets'), isFalse);
      expect(body.containsKey('attributesToHighlight'), isFalse);
      expect(body.containsKey('attributesToCrop'), isFalse);
      expect(body.containsKey('cropMarker'), isFalse);
    });

    test('a refused search token is replaced by the shipped one', () async {
      SharedPreferences.setMockInitialValues({'gz_janny_token': 'stale'});
      final adapter = _ScriptedAdapter(
        (options, index) => _header(options, 'Authorization') == 'Bearer stale'
            ? (status: 401, body: 'unauthorized')
            : (status: 200, body: '{"results":[{"hits":[],"totalHits":0}]}'),
      );
      setCatalogHttpAdapter(adapter);

      await jannySearch(query: 'x');

      expect(adapter.requests, hasLength(2));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gz_janny_token'), isNull);
    });

    test('a server fault is reported, not worked around', () async {
      SharedPreferences.setMockInitialValues({'gz_janny_token': 'tok'});
      final adapter = _ScriptedAdapter(
        (options, index) => (status: 500, body: 'boom'),
      );
      setCatalogHttpAdapter(adapter);

      await expectLater(jannySearch(query: 'x'), throwsA(anything));
      expect(adapter.requests, hasLength(1));
    });
  });
}
