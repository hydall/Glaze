import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'image_gen_http.dart';

class GeminiImageProvider {
  final ImageGenHttp _http = ImageGenHttp();

  Future<Uint8List> generate({
    required String endpoint,
    required String apiKey,
    required String model,
    required String prompt,
    required String aspectRatio,
    required String imageSize,
    CancelToken? cancelToken,
  }) async {
    String url = endpoint;
    if (!url.contains('/v1')) {
      url = '$url/v1/models/$model:predict';
    }

    final b64 = await _http.postAndExtractBase64(
      url: '$url?key=$apiKey',
      body: {
        'instances': [{'prompt': prompt}],
        'parameters': {
          'sampleCount': 1,
          'aspectRatio': aspectRatio,
          'imageSize': imageSize,
        },
      },
      cancelToken: cancelToken,
      extractBase64: (json) {
        final predictions = json['predictions'] as List?;
        if (predictions == null || predictions.isEmpty) throw Exception('No predictions in response');
        return (predictions.first as Map<String, dynamic>)['bytesBase64Encoded'] as String;
      },
    );
    return ImageGenHttp.base64ToBytes(b64);
  }
}
