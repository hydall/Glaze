import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'image_gen_http.dart';
import '../image_gen_models.dart';

class RoutmyImageProvider {
  final ImageGenHttp _http = ImageGenHttp();
  final String baseUrl;

  RoutmyImageProvider({this.baseUrl = RoutMyConstants.baseUrl});

  Future<Uint8List> generate({
    required String apiKey,
    required String model,
    required String prompt,
    required String aspectRatio,
    required String imageSize,
    required String quality,
    List<String>? referenceImages,
    CancelToken? cancelToken,
  }) async {
    final hasRefs = referenceImages != null && referenceImages.isNotEmpty;

    // References are documented only on `/v1/images/edits`, which the catalog
    // advertises only for the edit-capable models. The provider still checks
    // so a reference set that slipped past the UI gate is dropped rather than
    // sent to `/v1/images/generations`, which has no image input.
    if (hasRefs && RoutMyConstants.supportsReferences(model)) {
      return _editImages(
        apiKey: apiKey,
        model: model,
        prompt: prompt,
        aspectRatio: aspectRatio,
        imageSize: imageSize,
        quality: quality,
        referenceImages: referenceImages,
        cancelToken: cancelToken,
      );
    }
    return _generateImages(
      apiKey: apiKey,
      model: model,
      prompt: prompt,
      aspectRatio: aspectRatio,
      imageSize: imageSize,
      quality: quality,
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _generateImages({
    required String apiKey,
    required String model,
    required String prompt,
    required String aspectRatio,
    required String imageSize,
    required String quality,
    CancelToken? cancelToken,
  }) async {
    final url = '$baseUrl/v1/images/generations';
    final normalizedQuality = _normalizeQuality(quality);
    final isSeedreamModel = model == 'bytedance/seedream-5.0-pro';
    final normalizedImageSize =
        isSeedreamModel &&
            !RoutMyConstants.seedreamImageSizes.contains(imageSize)
        ? '2K'
        : imageSize;

    final body = <String, dynamic>{
      'model': model,
      'prompt': prompt,
      'n': 1,
      'image_config': {
        'aspect_ratio': aspectRatio,
        'image_size': normalizedImageSize,
      },
      if (!isSeedreamModel) 'quality': ?normalizedQuality,
    };

    final json = await _http.post(
      url: url,
      apiKey: apiKey,
      body: body,
      cancelToken: cancelToken,
    );
    return _extractImageBytes(json, cancelToken: cancelToken);
  }

  /// OpenAI-style image edits via multipart/form-data.
  /// Mirrors sillyimages exactly: single `image` field with PNG MIME for one ref,
  /// `image[]` repeated for multiple. rout.my proxies OpenAI-style file fields.
  Future<Uint8List> _editImages({
    required String apiKey,
    required String model,
    required String prompt,
    required String aspectRatio,
    required String imageSize,
    required String quality,
    required List<String> referenceImages,
    CancelToken? cancelToken,
  }) async {
    final url = '$baseUrl/v1/images/edits';

    final validRefs = referenceImages.where((s) => s.isNotEmpty).toList();

    // Plain string fields — mirror sillyimages field order exactly
    final fields = <String, String>{'model': model, 'prompt': prompt, 'n': '1'};

    // Map aspect ratio → OpenAI WxH size (gpt-image-2 specific sizes)
    final sizeStr = _aspectToSizeGptImage2(aspectRatio);
    if (sizeStr != null) fields['size'] = sizeStr;

    // quality: only send if non-empty and valid for gpt-image family
    final q = _normalizeQuality(quality);
    if (q != null) fields['quality'] = q;

    // Image files — sillyimages always uses 'image/png' MIME regardless of actual format.
    // Single ref → field name 'image'; multiple → 'image[]' repeated.
    final imageFields = <(String, Uint8List, String, String)>[];
    final multiRef = validRefs.length > 1;
    for (var i = 0; i < validRefs.length; i++) {
      final bytes = _base64ToBytes(validRefs[i]);
      final fieldName = multiRef ? 'image[]' : 'image';
      // Always declare as PNG — matches sillyimages iigBase64ToBlob(b64, 'image/png')
      imageFields.add((fieldName, bytes, 'reference-$i.png', 'image/png'));
    }

    final json = await _http.postMultipart(
      url: url,
      fields: fields,
      imageFields: imageFields,
      apiKey: apiKey,
      cancelToken: cancelToken,
    );
    return _extractImageBytes(json, cancelToken: cancelToken);
  }

  /// gpt-image-2 size map (different from gpt-image-1 family).
  String? _aspectToSizeGptImage2(String aspect) {
    const map = <String, String>{
      '1:1': '1024x1024',
      '16:9': '2048x1152',
      '9:16': '1152x2048',
      '3:2': '1536x1024',
      '2:3': '1024x1536',
      '4:3': '1536x1152',
      '3:4': '1152x1536',
    };
    return map[aspect];
  }

  /// Normalize quality string for gpt-image family.
  String? _normalizeQuality(String quality) {
    const valid = {'low', 'medium', 'high', 'auto'};
    final q = quality.toLowerCase().trim();
    if (valid.contains(q)) return q;
    if (q == 'hd') return 'high';
    if (q == 'standard') return 'medium';
    if (q.isEmpty) return null;
    return 'auto';
  }

  /// Decode bare base64 or data-URL to raw bytes.
  Uint8List _base64ToBytes(String s) {
    if (s.startsWith('data:')) {
      final comma = s.indexOf(',');
      if (comma != -1) s = s.substring(comma + 1);
    }
    return base64Decode(s);
  }

  Future<Uint8List> _extractImageBytes(
    Map<String, dynamic> json, {
    CancelToken? cancelToken,
  }) async {
    final data = json['data'] as List?;
    if (data != null) {
      for (final item in data) {
        if (item is! Map) continue;
        final imageObj = Map<String, dynamic>.from(item);
        final b64 = imageObj['b64_json'] as String?;
        if (b64 != null && b64.isNotEmpty) {
          return ImageGenHttp.base64ToBytes(_base64Payload(b64));
        }
        final imgUrl = imageObj['url'] as String?;
        if (imgUrl != null && imgUrl.isNotEmpty) {
          return _downloadImage(imgUrl, cancelToken: cancelToken);
        }
      }
    }
    _throwIfAsyncTask(json);
    if (data != null) {
      for (final item in data) {
        if (item is Map) _throwIfAsyncTask(Map<String, dynamic>.from(item));
      }
    }
    throw Exception('No image in response');
  }

  void _throwIfAsyncTask(Map<String, dynamic> json) {
    final status = json['status'];
    final id = json['task_id'] ?? json['id'];
    final object = json['object'];
    final isTask =
        status != null &&
        (id != null || object == 'image.generation.task') &&
        json['url'] == null &&
        json['b64_json'] == null;
    if (!isTask) return;

    final safeStatus = _safeTaskValue(status, maxLength: 40);
    final safeId = _safeTaskValue(id, maxLength: 120);
    throw Exception(
      'rout.my returned an asynchronous image task '
      '(status=$safeStatus, id=$safeId), but no polling endpoint is documented',
    );
  }

  String _safeTaskValue(Object? value, {required int maxLength}) {
    if (value == null) return 'unknown';
    if (value is! String && value is! num && value is! bool) return 'unknown';
    final sanitized = value.toString().replaceAll(
      RegExp(r'[^A-Za-z0-9._:\-]'),
      '_',
    );
    return sanitized.length <= maxLength
        ? sanitized
        : '${sanitized.substring(0, maxLength)}...';
  }

  String _base64Payload(String value) {
    final normalized = value.trim();
    if (!normalized.toLowerCase().startsWith('data:')) return normalized;
    final comma = normalized.indexOf(',');
    if (comma == -1 ||
        !normalized.substring(0, comma).toLowerCase().contains(';base64')) {
      throw Exception('Invalid base64 image data URI');
    }
    return normalized.substring(comma + 1);
  }

  Future<Uint8List> _downloadImage(
    String url, {
    CancelToken? cancelToken,
  }) async {
    if (url.toLowerCase().startsWith('data:')) {
      final commaIdx = url.indexOf(',');
      if (commaIdx == -1) throw Exception('Invalid data URL');
      return ImageGenHttp.base64ToBytes(_base64Payload(url));
    }
    try {
      final response = await _http.getRaw(url, cancelToken: cancelToken);
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('rout.my image download returned an empty response');
      }
      return bytes;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      final status = error.response?.statusCode;
      throw Exception(
        'rout.my image download failed${status == null ? '' : ' (HTTP $status)'}',
      );
    }
  }
}
