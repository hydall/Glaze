import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
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

  group('a rejected request that carried an image', () {
    /// Nothing tells Glaze whether the active model is multimodal, so the only
    /// evidence is the rejection itself plus the body that was sent.
    String formatRejection({
      required int status,
      required Object? body,
    }) {
      final options = RequestOptions(path: '/chat/completions', data: body);
      return formatError(
        DioException.badResponse(
          statusCode: status,
          requestOptions: options,
          response: Response<dynamic>(
            requestOptions: options,
            statusCode: status,
            data: const {
              'error': {'message': 'Invalid content type'},
            },
          ),
        ),
      );
    }

    Object openAiBody() => {
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,AAAA'},
            },
          ],
        },
      ],
    };

    test('names images as a possible cause', () {
      final lines = formatRejection(status: 400, body: openAiBody()).split('\n');

      expect(lines, hasLength(3));
      expectStatusLine(lines.first, 400);
      expect(lines[1], 'Invalid content type');
      expect(lines.last, 'error_images_maybe_unsupported'.tr());
      expect(lines.last, isNotEmpty);
    });

    test('says nothing when the request carried no image', () {
      final lines = formatRejection(
        status: 400,
        body: {
          'messages': [
            {'role': 'user', 'content': 'look'},
          ],
        },
      ).split('\n');

      expect(lines, hasLength(2));
    });

    test('says nothing about a failure that is not about the payload', () {
      final lines = formatRejection(
        status: 500,
        body: openAiBody(),
      ).split('\n');

      expect(lines, hasLength(2));
    });

    test('reads every shape the transports build', () {
      // Anthropic, Gemini, the Responses API, and a body Dio was handed
      // already encoded.
      final bodies = <Object>[
        {
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'data': 'AAAA'},
                },
              ],
            },
          ],
        },
        {
          'contents': [
            {
              'parts': [
                {
                  'inline_data': {'mime_type': 'image/png', 'data': 'AAAA'},
                },
              ],
            },
          ],
        },
        {
          'input': [
            {
              'content': [
                {'type': 'input_image', 'image_url': 'data:image/png;base64,A'},
              ],
            },
          ],
        },
        '{"messages":[{"content":[{"type":"image_url"}]}]}',
      ];

      for (final body in bodies) {
        expect(
          formatRejection(status: 400, body: body).split('\n'),
          hasLength(3),
          reason: 'no hint for $body',
        );
      }
    });
  });

  test('every message key this file names has an EN and RU string', () {
    final source = File(
      'lib/core/utils/error_format.dart',
    ).readAsStringSync();
    // Every key, not just the status descriptions: a hint added to the status
    // line is as visible to the reader as the line itself.
    final keys = RegExp(r"'(error_[a-z0-9_]+)'")
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
