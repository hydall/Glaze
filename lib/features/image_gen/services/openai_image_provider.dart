import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/llm/transport/endpoint_normalizer.dart';
import '../image_gen_capabilities.dart';
import 'image_gen_http.dart';

/// OpenAI-compatible images API.
///
/// Without references the request goes to `/v1/images/generations` (JSON);
/// with references it goes to `/v1/images/edits` (multipart), mirroring
/// https://github.com/0xl0cal/sillyimages (`src/providers.js`, `OpenAIProvider`).
/// Which models accept references — and how many — comes from
/// [openAiMaxReferences].
class OpenaiImageProvider {
  OpenaiImageProvider({this.allowMultiImageField = true});

  /// Electron Hub's `/v1/images/edits` only accepts a single `image` field,
  /// while OpenAI accepts a repeated `image[]`.
  final bool allowMultiImageField;

  final ImageGenHttp _http = ImageGenHttp();

  Future<Uint8List> generate({
    required String endpoint,
    required String apiKey,
    required String model,
    required String prompt,
    required String size,
    required String quality,
    List<String>? referenceImages,
    CancelToken? cancelToken,
  }) async {
    final kind = classifyOpenAiImageModel(model);
    final maxRefs = openAiMaxReferences(kind);
    final refs = (referenceImages ?? const <String>[])
        .where((ref) => ref.isNotEmpty)
        .take(maxRefs)
        .toList();

    if (refs.isNotEmpty) {
      return _edit(
        url: _imagesUrl(endpoint, 'edits'),
        apiKey: apiKey,
        model: model,
        kind: kind,
        prompt: prompt,
        size: size,
        quality: quality,
        references: refs,
        cancelToken: cancelToken,
      );
    }

    return _generate(
      url: _imagesUrl(endpoint, 'generations'),
      apiKey: apiKey,
      model: model,
      kind: kind,
      prompt: prompt,
      size: size,
      quality: quality,
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _generate({
    required String url,
    required String apiKey,
    required String model,
    required String kind,
    required String prompt,
    required String size,
    required String quality,
    CancelToken? cancelToken,
  }) {
    final normalizedQuality = normalizeOpenAiQuality(quality, kind);
    final gptImage = isGptImageFamily(kind);
    return _http.postAndExtract(
      url: url,
      apiKey: apiKey,
      body: {
        'model': model,
        'prompt': prompt,
        'n': 1,
        if (size.isNotEmpty) 'size': size,
        'quality': ?normalizedQuality,
        // gpt-image-* always answers with base64 and rejects response_format;
        // it does understand `moderation`, which dall-e-* does not.
        if (!gptImage) 'response_format': 'b64_json',
        if (gptImage) 'moderation': 'low',
      },
      cancelToken: cancelToken,
      extract: (json) => _extractImage(json, cancelToken),
    );
  }

  Future<Uint8List> _edit({
    required String url,
    required String apiKey,
    required String model,
    required String kind,
    required String prompt,
    required String size,
    required String quality,
    required List<String> references,
    CancelToken? cancelToken,
  }) async {
    final normalizedQuality = normalizeOpenAiQuality(quality, kind);
    final fields = <String, String>{
      'model': model,
      'prompt': prompt,
      'n': '1',
      if (size.isNotEmpty) 'size': size,
      'quality': ?normalizedQuality,
      if (isGptImageFamily(kind)) 'moderation': 'low',
    };

    final multiRef =
        allowMultiImageField && isGptImageFamily(kind) && references.length > 1;
    final imageFields = <(String, Uint8List, String, String)>[];
    for (var i = 0; i < (multiRef ? references.length : 1); i++) {
      // Always declared as PNG — matches the upstream extension, which wraps
      // every reference blob as image/png regardless of the real format.
      imageFields.add((
        multiRef ? 'image[]' : 'image',
        _toBytes(references[i]),
        'reference-$i.png',
        'image/png',
      ));
    }

    final json = await _http.postMultipart(
      url: url,
      fields: fields,
      imageFields: imageFields,
      apiKey: apiKey,
      cancelToken: cancelToken,
    );
    return _extractImage(json, cancelToken);
  }

  Future<Uint8List> _extractImage(
    Map<String, dynamic> json,
    CancelToken? cancelToken,
  ) async {
    final data = json['data'] as List?;
    if (data == null || data.isEmpty) {
      throw Exception('No image data in response');
    }
    for (final item in data) {
      if (item is! Map) continue;
      final imageObj = Map<String, dynamic>.from(item);
      final b64 = imageObj['b64_json'] as String?;
      if (b64 != null && b64.isNotEmpty) {
        return ImageGenHttp.base64ToBytes(ImageGenHttp.stripBase64Prefix(b64));
      }
      final imgUrl = imageObj['url'] as String?;
      if (imgUrl != null && imgUrl.isNotEmpty) {
        return ImageGenHttp.downloadImage(imgUrl, cancelToken: cancelToken);
      }
    }
    throw Exception('No b64_json or url in image response');
  }

  Uint8List _toBytes(String reference) =>
      base64Decode(ImageGenHttp.stripBase64Prefix(reference));

  /// Appends the images path unless the endpoint already points at one.
  /// Same normalization as the chat transports — the image endpoint field is
  /// the same free text, so a missing scheme, a missing `/v1` or a pasted full
  /// `…/images/generations` all resolve here instead of 404ing.
  static String _imagesUrl(String endpoint, String action) =>
      EndpointNormalizer.imagesUrl(endpoint, action);
}
