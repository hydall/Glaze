import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';

/// Builds the exception shape a streaming request produces: the error body is
/// still an undecoded byte stream.
Future<DioException> streamingError(
  int status,
  String body, {
  String path = '/chat/completions',
}) {
  final options = RequestOptions(path: path);
  return decodeStreamingError(
    DioException.badResponse(
      statusCode: status,
      requestOptions: options,
      response: Response<ResponseBody>(
        requestOptions: options,
        statusCode: status,
        data: ResponseBody.fromString(body, status),
      ),
    ),
  );
}

/// The status line always names the code and carries a description. The
/// description itself is localized, so tests only assert its shape.
void expectStatusLine(String message, int status) {
  final line = message.split('\n').first;
  expect(line, startsWith('HTTP $status - '));
  expect(line.substring('HTTP $status - '.length), isNotEmpty);
}

void main() {
  test('keeps the HTTP description above the provider message', () async {
    final decoded = await streamingError(
      404,
      '{"error":{"message":"Unknown page - v1beta/v1"}}',
      path: '/v1beta/v1/models',
    );

    final message = formatError(decoded);

    expectStatusLine(message, 404);
    expect(message.split('\n'), hasLength(2));
    expect(message.split('\n').last, 'Unknown page - v1beta/v1');
  });

  test('formats a provider message from a streaming HTTP error body', () async {
    final decoded = await streamingError(
      400,
      '{"error":{"message":"Unsupported parameter: top_k"}}',
    );

    final message = formatError(decoded);

    expectStatusLine(message, 400);
    expect(message.split('\n').last, 'Unsupported parameter: top_k');
  });

  test('formats a plain-text streaming HTTP error body', () async {
    final decoded = await streamingError(400, 'Model is not available');

    final message = formatError(decoded);

    expectStatusLine(message, 400);
    expect(message.split('\n').last, 'Model is not available');
  });

  test('formats a custom provider detail field', () async {
    final decoded = await streamingError(
      400,
      '{"detail":"Context length exceeds model limit"}',
      path: '/v1/chat/completions',
    );

    final message = formatError(decoded);

    expectStatusLine(message, 400);
    expect(message.split('\n').last, 'Context length exceeds model limit');
  });

  test('keeps the status line alone when the body carries no message', () async {
    final decoded = await streamingError(500, '{"foo":"bar"}');

    final message = formatError(decoded);

    expectStatusLine(message, 500);
    expect(message, isNot(contains('\n')));
  });

  test('does not repeat a provider message that echoes the status text',
      () async {
    final options = RequestOptions(path: '/chat/completions');
    final error = DioException.badResponse(
      statusCode: 418,
      requestOptions: options,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: 418,
        statusMessage: "I'm a teapot",
        data: "i'm a teapot",
      ),
    );

    expect(formatError(error), "HTTP 418 - I'm a teapot");
  });

  test('falls back to the server reason phrase for unmapped codes', () async {
    final options = RequestOptions(path: '/chat/completions');
    final error = DioException.badResponse(
      statusCode: 418,
      requestOptions: options,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: 418,
        statusMessage: 'Teapot',
        data: const <String, dynamic>{
          'error': {'message': 'No coffee here'},
        },
      ),
    );

    expect(formatError(error), 'HTTP 418 - Teapot\nNo coffee here');
  });

  test('omits the description when nothing describes the status', () async {
    final options = RequestOptions(path: '/chat/completions');
    final error = DioException.badResponse(
      statusCode: 599,
      requestOptions: options,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: 599,
        statusMessage: '   ',
        data: 'upstream exploded',
      ),
    );

    expect(formatError(error), 'HTTP 599\nupstream exploded');
  });

  group('a body that arrived as text is decoded before it is shown', () {
    /// The shape the catalog client produces: `ResponseType.plain`, so the
    /// server's JSON reaches `formatError` as a String.
    DioException plainError(int status, String body, {Headers? headers}) {
      final options = RequestOptions(path: '/api/characters/uuid-1');
      return DioException.badResponse(
        statusCode: status,
        requestOptions: options,
        response: Response<dynamic>(
          requestOptions: options,
          statusCode: status,
          data: body,
          headers: headers,
        ),
      );
    }

    test('a challenge blob is not the error message', () {
      // Verbatim from the report: DataCat answers a refused download with its
      // Turnstile configuration, and the dialog showed all of it.
      final message = formatError(
        plainError(
          403,
          '{"success":false,"serverInstanceId":"main-4330-v26b",'
          '"hostname":"datacat.run",'
          '"turnstile":{"action":"character-card-download"},'
          '"lease":{"leaseValid":false}}',
        ),
      );

      expectStatusLine(message, 403);
      expect(message, isNot(contains('\n')));
      expect(message, isNot(contains('turnstile')));
    });

    test('a provider message in a plain body is found, not dumped', () {
      final message = formatError(
        plainError(400, '{"error":{"message":"Model is overloaded"}}'),
      );

      expectStatusLine(message, 400);
      expect(message.split('\n').last, 'Model is overloaded');
    });

    test("Meilisearch's own reason survives the normalization", () {
      // Janny's search runs on Meilisearch, whose 400 names the clause it
      // refused. That sentence is the whole diagnosis, so it is never dropped.
      final message = formatError(
        plainError(
          400,
          '{"message":"Attribute `totalToken` is not filterable.",'
          '"code":"invalid_search_filter","type":"invalid_request"}',
        ),
      );

      expect(
        message.split('\n').last,
        'Attribute `totalToken` is not filterable.',
      );
    });

    test('an error object wrapped in an array is still read', () {
      final message = formatError(
        plainError(404, '[{"error":{"message":"models/x is not found"}}]'),
      );

      expect(message.split('\n').last, 'models/x is not found');
    });

    test('a block page is left out entirely', () {
      final message = formatError(
        plainError(
          403,
          '<!DOCTYPE html><html><head><title>Attention Required!</title>'
          '</head><body>${'cloudflare ' * 200}</body></html>',
        ),
      );

      expectStatusLine(message, 403);
      expect(message, isNot(contains('\n')));
    });

    test('a message too long to read is cut, not passed on whole', () {
      final message = formatError(
        plainError(400, '{"error":{"message":"${'over budget. ' * 100}"}}'),
      );

      final body = message.split('\n').last;
      expect(body.length, lessThan(320));
      expect(body, endsWith('…'));
      expect(body, startsWith('over budget.'));
    });

    test('prose a provider answers with is still worth showing', () {
      final message = formatError(plainError(400, 'Model is not available'));

      expect(message.split('\n').last, 'Model is not available');
    });
  });

  group('a redirect names the endpoint as the thing to fix', () {
    DioException redirect(int status, {String? location}) {
      final options = RequestOptions(path: '/chat/completions');
      return DioException.badResponse(
        statusCode: status,
        requestOptions: options,
        response: Response<dynamic>(
          requestOptions: options,
          statusCode: status,
          headers: Headers.fromMap({
            if (location != null) 'location': [location],
          }),
        ),
      );
    }

    test('HTTP 308 is described and quotes where the server points', () {
      // The reported case: a Chutes base URL with the API path left off.
      final message = formatError(
        redirect(308, location: 'https://llm.chutes.ai/v1/chat/completions'),
      );

      final lines = message.split('\n');
      expectStatusLine(message, 308);
      expect(lines, hasLength(3));
      expect(lines[1], 'error_endpoint_redirect');
      expect(lines.last, '→ https://llm.chutes.ai/v1/chat/completions');
    });

    test('the hint stands alone when the server names no target', () {
      final message = formatError(redirect(307));

      expect(message.split('\n'), hasLength(2));
      expect(message.split('\n').last, 'error_endpoint_redirect');
    });

    test('a status that is not a redirect gains no hint', () {
      final message = formatError(redirect(404, location: '/elsewhere'));

      expect(message, isNot(contains('error_endpoint_redirect')));
      expect(message, isNot(contains('elsewhere')));
    });

    test('the redirect hint is translated in both locales', () {
      final en = loadTranslations('assets/translations/en.json');
      final ru = loadTranslations('assets/translations/ru.json');

      expect(en, contains('error_endpoint_redirect'));
      expect(ru, contains('error_endpoint_redirect'));
    });
  });

  test('every mapped HTTP status has an EN and RU description', () {
    final source = File(
      'lib/core/utils/error_format.dart',
    ).readAsStringSync();
    final keys = RegExp(r"'(error_http_\d+)'")
        .allMatches(source)
        .map((match) => match.group(1)!)
        .toSet();
    final en = loadTranslations('assets/translations/en.json');
    final ru = loadTranslations('assets/translations/ru.json');

    expect(keys, isNotEmpty);
    for (final key in keys) {
      expect(en, contains(key), reason: '$key is missing from en.json');
      expect(ru, contains(key), reason: '$key is missing from ru.json');
    }
  });
}

Map<String, dynamic> loadTranslations(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
