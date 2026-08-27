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
