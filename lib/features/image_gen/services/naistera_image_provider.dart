import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'image_gen_http.dart';
import '../image_gen_models.dart';

class NaisteraImageProvider {
  final ImageGenHttp _http = ImageGenHttp();

  Future<Uint8List> generate({
    required String apiKey,
    required String model,
    required String prompt,
    required String aspectRatio,
    List<Map<String, String>>? references,
    CancelToken? cancelToken,
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'prompt': prompt,
      'aspect_ratio': aspectRatio,
    };
    if (references != null && references.isNotEmpty && !NaisteraConstants.noRefModels.contains(model)) {
      body['references'] = references;
    }

    final b64 = await _http.postAndExtractBase64(
      url: 'https://naistera.org/prompt/api/img',
      apiKey: apiKey,
      body: body,
      cancelToken: cancelToken,
      extractBase64: (json) {
        final images = json['images'] as List?;
        if (images == null || images.isEmpty) throw Exception('No images in response');
        return images.first as String;
      },
    );
    return ImageGenHttp.base64ToBytes(b64);
  }
}
