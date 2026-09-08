import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'image_gen_http.dart';

class OpenaiImageProvider {
  final ImageGenHttp _http = ImageGenHttp();

  Future<Uint8List> generate({
    required String endpoint,
    required String apiKey,
    required String model,
    required String prompt,
    required String size,
    required String quality,
    CancelToken? cancelToken,
  }) async {
    String url = endpoint;
    if (!url.contains('/v1') && !url.contains('/images')) {
      url = '$url/v1/images/generations';
    } else if (!url.contains('/images/generations')) {
      url = '$url/images/generations';
    }

    final b64 = await _http.postAndExtractBase64(
      url: url,
      apiKey: apiKey,
      body: {
        'model': model,
        'prompt': prompt,
        'n': 1,
        'size': size,
        'quality': quality,
        'response_format': 'b64_json',
      },
      cancelToken: cancelToken,
      extractBase64: (json) {
        final data = json['data'] as List?;
        if (data == null || data.isEmpty) throw Exception('No image data in response');
        return (data.first as Map<String, dynamic>)['b64_json'] as String;
      },
    );
    return ImageGenHttp.base64ToBytes(b64);
  }
}
