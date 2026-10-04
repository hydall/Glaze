import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../image_gen_capabilities.dart';
import '../image_gen_constants.dart';
import 'image_gen_http.dart';
import 'image_prompt_builder.dart';

/// OpenRouter image generation over `/chat/completions` with
/// `modalities: [image, text]`.
///
/// Ported from https://github.com/0xl0cal/sillyimages (`src/providers.js`,
/// `OpenRouterProvider`): references travel as `image_url` content parts,
/// each preceded by a `Reference N: ...` text label, and `image_config`
/// carries the aspect ratio (plus image size for the Gemini models that take
/// one).
class OpenRouterImageProvider {
  final ImageGenHttp _http = ImageGenHttp();

  Future<Uint8List> generate({
    required String apiKey,
    required String endpoint,
    required String model,
    required String prompt,
    required String aspectRatio,
    required String imageSize,
    List<Map<String, String>>? references,
    CancelToken? cancelToken,
  }) async {
    final base =
        (endpoint.trim().isEmpty
                ? OpenRouterConstants.defaultEndpoint
                : endpoint.trim())
            .replaceFirst(RegExp(r'/+$'), '');
    final url = base.endsWith('/chat/completions')
        ? base
        : '$base/chat/completions';

    final caps = openRouterCapabilities(model);
    final refs = (references ?? const <Map<String, String>>[])
        .where((ref) => (ref['image'] ?? '').isNotEmpty)
        .take(caps.maxReferences)
        .toList();

    final Object content;
    if (refs.isEmpty) {
      content = prompt;
    } else {
      final parts = <Map<String, dynamic>>[];
      for (var i = 0; i < refs.length; i++) {
        final label = referenceTextLabel(i + 1, refs[i]['description']);
        if (label.isNotEmpty) parts.add({'type': 'text', 'text': label});
        parts.add({
          'type': 'image_url',
          'image_url': {'url': _asDataUrl(refs[i])},
        });
      }
      parts.add({'type': 'text', 'text': prompt});
      content = parts;
    }

    final json = await _http.post(
      url: url,
      apiKey: apiKey,
      body: {
        'model': model,
        'messages': [
          {'role': 'user', 'content': content},
        ],
        // Gemini answers with text and image; FLUX / Sourceful only image.
        'modalities': isGeminiOpenRouterModel(model)
            ? ['image', 'text']
            : ['image'],
        // OpenRouter-compatible proxies default to CDN links; this asks for
        // base64. openrouter.ai itself ignores it.
        'enable_base64_output': true,
        'image_config': {
          'aspect_ratio': aspectRatio,
          if (caps.imageSizes != null && imageSize.isNotEmpty)
            'image_size': imageSize,
        },
      },
      cancelToken: cancelToken,
    );

    final imageUrl = _extractImageUrl(json);
    if (imageUrl == null || imageUrl.isEmpty) {
      throw Exception('No image in OpenRouter response');
    }
    if (imageUrl.startsWith('data:')) {
      return ImageGenHttp.base64ToBytes(
        ImageGenHttp.stripBase64Prefix(imageUrl),
      );
    }
    return ImageGenHttp.downloadImage(imageUrl, cancelToken: cancelToken);
  }

  /// Handles the shapes seen in the wild: `images[].image_url.url`,
  /// `images[].data_url`, `images[].b64_json` and content parts.
  String? _extractImageUrl(Map<String, dynamic> json) {
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map) return null;
    final message = first['message'];
    if (message is! Map) return null;

    final images = message['images'];
    if (images is List) {
      for (final image in images) {
        if (image is! Map) continue;
        final imageUrl = image['image_url'];
        if (imageUrl is Map && imageUrl['url'] is String) {
          return imageUrl['url'] as String;
        }
        if (image['data_url'] is String) return image['data_url'] as String;
        final b64 = image['b64_json'];
        if (b64 is String && b64.isNotEmpty) {
          final mime =
              (image['image_base64'] is Map
                  ? image['image_base64']['media_type']
                  : null) ??
              image['media_type'] ??
              'image/png';
          return 'data:$mime;base64,$b64';
        }
        if (image['url'] is String) return image['url'] as String;
      }
    }

    final content = message['content'];
    if (content is List) {
      for (final part in content) {
        if (part is! Map) continue;
        final imageUrl = part['image_url'];
        if (part['type'] == 'image_url' &&
            imageUrl is Map &&
            imageUrl['url'] is String) {
          return imageUrl['url'] as String;
        }
        if (part['type'] == 'image' && part['image'] is String) {
          return part['image'] as String;
        }
        if (part['type'] == 'input_image' && imageUrl is String) {
          return imageUrl;
        }
      }
    }
    return null;
  }

  String _asDataUrl(Map<String, String> reference) {
    final image = reference['image'] ?? '';
    if (image.startsWith('data:') ||
        image.startsWith('http://') ||
        image.startsWith('https://')) {
      return image;
    }
    return 'data:${reference['mime'] ?? _sniffMime(image)};base64,$image';
  }

  String _sniffMime(String b64) {
    if (b64.startsWith('/9j/')) return 'image/jpeg';
    if (b64.startsWith('iVBORw0KGgo')) return 'image/png';
    if (b64.startsWith('UklGR')) return 'image/webp';
    if (b64.startsWith('R0lGOD')) return 'image/gif';
    return 'image/png';
  }
}
