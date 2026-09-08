import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';

void main() {
  test('formats a provider message from a streaming HTTP error body', () async {
    final options = RequestOptions(path: '/chat/completions');
    final error = DioException.badResponse(
      statusCode: 400,
      requestOptions: options,
      response: Response<ResponseBody>(
        requestOptions: options,
        statusCode: 400,
        data: ResponseBody.fromString(
          '{"error":{"message":"Unsupported parameter: top_k"}}',
          400,
        ),
      ),
    );

    final decoded = await decodeStreamingError(error);

    expect(formatError(decoded), 'HTTP 400: Unsupported parameter: top_k');
  });

  test('formats a plain-text streaming HTTP error body', () async {
    final options = RequestOptions(path: '/chat/completions');
    final error = DioException.badResponse(
      statusCode: 400,
      requestOptions: options,
      response: Response<ResponseBody>(
        requestOptions: options,
        statusCode: 400,
        data: ResponseBody.fromString('Model is not available', 400),
      ),
    );

    final decoded = await decodeStreamingError(error);

    expect(formatError(decoded), 'HTTP 400: Model is not available');
  });

  test('formats a custom provider detail field', () async {
    final options = RequestOptions(path: '/v1/chat/completions');
    final error = DioException.badResponse(
      statusCode: 400,
      requestOptions: options,
      response: Response<ResponseBody>(
        requestOptions: options,
        statusCode: 400,
        data: ResponseBody.fromString(
          '{"detail":"Context length exceeds model limit"}',
          400,
        ),
      ),
    );

    final decoded = await decodeStreamingError(error);

    expect(
      formatError(decoded),
      'HTTP 400: Context length exceeds model limit',
    );
  });
}
