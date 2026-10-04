import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/utils/error_format.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_status_tracker.dart';

/// Builds the exception shape a streaming ext-block request produces: the
/// error body is still an undecoded byte stream when the transport catches it.
Future<DioException> _streamingError(int status, String body) {
  final options = RequestOptions(path: '/chat/completions');
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

void main() {
  group('ext block failures use the shared formatError', () {
    test('renders the provider message instead of the Dio dump', () async {
      final error = await _streamingError(
        400,
        '{"error":{"message":"Unsupported parameter: top_k"}}',
      );

      final content = formatBlockErrorContent(formatError(error));

      expect(content, startsWith('<p class="ext-block-error">'));
      expect(content, contains('HTTP 400'));
      expect(content, contains('Unsupported parameter: top_k'));
      // The raw `DioException.toString()` dump must not reach the panel.
      expect(content, isNot(contains('RequestOptions')));
      expect(content, isNot(contains('DioException')));
    });

    test('keeps the provider message on its own line as a <br>', () async {
      final error = await _streamingError(
        429,
        '{"error":{"message":"Rate limit reached"}}',
      );

      final content = formatBlockErrorContent(formatError(error));

      expect(content, contains('<br>'));
      expect(content.split('<br>'), hasLength(2));
      expect(content, isNot(contains('\n')));
    });

    test('escapes HTML in the provider message', () {
      final content = formatBlockErrorContent(
        'HTTP 400\n<script>alert("x")</script> & more',
      );

      expect(content, isNot(contains('<script>')));
      expect(content, contains('&lt;script&gt;'));
      expect(content, contains('&amp; more'));
    });

    test('carries a network failure through as plain prose', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/chat/completions'),
        type: DioExceptionType.connectionError,
      );

      final message = formatError(error);

      expect(message, isNot(contains('DioException')));
      expect(message, isNot(contains('RequestOptions')));
      expect(formatBlockErrorContent(message), contains(message));
    });
  });
}
