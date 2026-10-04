import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../image_gen_constants.dart';
import 'image_gen_http.dart';

/// xAI Imagine images API.
///
/// Ported from https://github.com/0xl0cal/sillyimages (`XAIProvider`): without
/// references the request goes to `/v1/images/generations`, with them to
/// `/v1/images/edits` — both JSON, unlike the OpenAI multipart `/edits`. One
/// reference travels in `image`, two or three in `images`, each as
/// `{type: 'image_url', url: <data URL>}`.
class XaiImageProvider {
  XaiImageProvider({this.baseUrl = XaiConstants.defaultEndpoint});

  final ImageGenHttp _http = ImageGenHttp();
  final String baseUrl;

  Future<Uint8List> generate({
    required String apiKey,
    required String model,
    required String prompt,
    required String aspectRatio,
    required String resolution,
    required String quality,
    List<Map<String, String>>? references,
    CancelToken? cancelToken,
  }) async {
    final refs = XaiConstants.supportsReferences(model)
        ? (references ?? const <Map<String, String>>[])
              .where((ref) => (ref['image'] ?? '').isNotEmpty)
              .take(XaiConstants.maxReferences)
              .toList()
        : const <Map<String, String>>[];

    final body = <String, dynamic>{
      'model': model,
      'prompt': prompt,
      'n': 1,
      'response_format': 'b64_json',
      'aspect_ratio': XaiConstants.normalizeAspectRatio(aspectRatio),
      'resolution': XaiConstants.normalizeResolution(resolution),
      if (XaiConstants.supportsQuality(model))
        'quality': XaiConstants.normalizeQuality(quality),
    };

    if (refs.length == 1) {
      body['image'] = _imageInput(refs.first);
    } else if (refs.length > 1) {
      body['images'] = refs.map(_imageInput).toList();
    }

    final path = refs.isEmpty ? 'generations' : 'edits';
    final json = await _http.post(
      url: '${XaiConstants.normalizeEndpoint(baseUrl)}/v1/images/$path',
      apiKey: apiKey,
      body: body,
      cancelToken: cancelToken,
    );
    return _extractImage(json, cancelToken);
  }

  /// The collector hands over bare base64 plus the mime it read off the file;
  /// xAI wants a full data URL.
  static Map<String, String> _imageInput(Map<String, String> reference) {
    final image = reference['image'] ?? '';
    final mime = reference['mime'] ?? 'image/png';
    return {
      'type': 'image_url',
      'url': image.startsWith('data:') ? image : 'data:$mime;base64,$image',
    };
  }

  Future<Uint8List> _extractImage(
    Map<String, dynamic> json,
    CancelToken? cancelToken,
  ) async {
    final data = json['data'];
    if (data is List) {
      for (final item in data) {
        if (item is! Map) continue;
        final entry = Map<String, dynamic>.from(item);
        final b64 = entry['b64_json'] as String?;
        if (b64 != null && b64.isNotEmpty) {
          return ImageGenHttp.base64ToBytes(
            ImageGenHttp.stripBase64Prefix(b64),
          );
        }
        final url = entry['url'] as String?;
        if (url != null && url.isNotEmpty) {
          return ImageGenHttp.downloadImage(url, cancelToken: cancelToken);
        }
      }
    }
    final url = json['url'];
    if (url is String && url.isNotEmpty) {
      return ImageGenHttp.downloadImage(url, cancelToken: cancelToken);
    }
    throw Exception('No b64_json or url in xAI image response');
  }
}
