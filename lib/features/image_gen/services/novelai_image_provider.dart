import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';

import '../image_gen_models.dart';
import 'image_gen_http.dart';

/// NovelAI Image Generation (`POST {base}/ai/generate-image`).
///
/// The token is a NovelAI persistent access key sent as a Bearer token. The
/// response is a ZIP attachment with the generated image; some proxies answer
/// JSON with a base64 `image` instead, so both are accepted. V4 / V4.5 / V5
/// models take the structured `v4_prompt` captions, while V3 keeps a plain
/// `prompt` field. Precise Reference (Director Tools) images are V4.5 and V5
/// only.
class NovelAIImageProvider {
  final ImageGenHttp _http = ImageGenHttp();

  Future<Uint8List> generate({
    required NovelAIImageSettings settings,
    required String prompt,
    List<Map<String, String>>? references,
    String? instructionAspectRatio,
    CancelToken? cancelToken,
  }) async {
    final model = NovelAIConstants.normalizeModel(settings.model);
    final isV4 = NovelAIConstants.isV4(model);
    final quality = settings.qualityToggle;

    final positive = quality
        ? NovelAIConstants.applyQualityTags(prompt, model)
        : prompt.trim();
    final negative = NovelAIConstants.resolveNegativePrompt(
      model: model,
      presetId: settings.ucPreset,
      userNegative: settings.negativePrompt,
    );

    final size =
        NovelAIConstants.sizeForAspect(instructionAspectRatio) ??
        (settings.width, settings.height);

    final parameters = <String, dynamic>{
      'params_version': NovelAIConstants.isV5(model) ? 4 : 3,
      'width': size.$1.clamp(64, 1600),
      'height': size.$2.clamp(64, 1600),
      'scale': settings.scale.clamp(0, 10),
      'sampler': settings.sampler,
      'steps': settings.steps.clamp(1, 50),
      'n_samples': 1,
      'ucPreset': NovelAIConstants.ucPresetIndex(settings.ucPreset),
      'qualityToggle': quality,
      'dynamic_thresholding': false,
      'cfg_rescale': settings.cfgRescale.clamp(0, 1),
      'noise_schedule': settings.noiseSchedule,
      'seed': settings.seed < 0 ? Random().nextInt(0xFFFFFFFF) : settings.seed,
      'negative_prompt': negative,
      'legacy': false,
      'legacy_v3_extend': false,
      'legacy_uc': false,
      'add_original_image': false,
      'controlnet_strength': 1,
      'normalize_reference_strength_multiple': false,
      'use_coords': false,
      'characterPrompts': <dynamic>[],
      if (settings.varietyBoost) 'skip_cfg_above_sigma': 58,
    };

    if (isV4) {
      parameters['v4_prompt'] = _v4Condition(positive);
      parameters['v4_negative_prompt'] = _v4Condition(negative, legacyUc: true);
    } else {
      parameters['prompt'] = positive;
    }

    _attachReferences(parameters, model, settings, references);

    final bytes = await _http.postForBytes(
      url: '${NovelAIConstants.normalizeEndpoint(settings.endpoint)}'
          '/ai/generate-image',
      apiKey: settings.apiKey,
      body: {
        'input': positive,
        'model': model,
        'action': 'generate',
        'parameters': parameters,
        'use_new_shared_trial': true,
      },
      cancelToken: cancelToken,
    );

    return _extractImage(bytes);
  }

  static Map<String, dynamic> _v4Condition(
    String caption, {
    bool legacyUc = false,
  }) {
    final condition = <String, dynamic>{
      'caption': {'base_caption': caption, 'char_captions': <dynamic>[]},
    };
    if (legacyUc) {
      condition['legacy_uc'] = false;
    } else {
      condition['use_coords'] = false;
      condition['use_order'] = true;
    }
    return condition;
  }

  /// Attaches Precise Reference (Director Tools) images when the model takes
  /// them. NovelAI wants bare base64 — the collector already strips the data
  /// URL and fits the image to the model's sizes — plus one entry per
  /// parallel array.
  ///
  /// The type travels as the reference's `base_caption`: a library entry's
  /// own `novelaiType` when the model offers it, otherwise the provider
  /// setting; on V5 "Prefer same outfit" picks the caption variant. Strength
  /// goes as is. Fidelity goes inverted, as the secondary strength, the way
  /// NovelAI's site sends it; V5 has no Fidelity and is sent 0, as if at 1.
  void _attachReferences(
    Map<String, dynamic> parameters,
    String model,
    NovelAIImageSettings settings,
    List<Map<String, String>>? references,
  ) {
    if (!NovelAIConstants.supportsReferences(model)) return;
    final refs = (references ?? const <Map<String, String>>[])
        .where((ref) => (ref['image'] ?? '').isNotEmpty)
        .take(NovelAIConstants.maxReferences)
        .toList();
    if (refs.isEmpty) return;

    final defaultType = NovelAIConstants.effectiveReferenceType(
      model,
      settings.referenceType,
    );
    final strength = settings.referenceStrength
        .clamp(
          NovelAIConstants.referenceValueMin,
          NovelAIConstants.referenceStrengthMax(model),
        )
        .toDouble();
    final secondary = NovelAIConstants.referenceSupportsFidelity(model)
        ? 1.0 -
              settings.referenceFidelity
                  .clamp(
                    NovelAIConstants.referenceValueMin,
                    NovelAIConstants.referenceFidelityMax,
                  )
                  .toDouble()
        : 0.0;

    String caption(Map<String, String> ref) =>
        NovelAIConstants.referenceCaption(
          model: model,
          type: NovelAIConstants.effectiveReferenceType(
            model,
            ref['novelaiType'],
            fallback: defaultType,
          ),
          sameOutfit: settings.referenceSameOutfit,
        );

    parameters['director_reference_images'] = [
      for (final ref in refs) ref['image']!,
    ];
    parameters['director_reference_descriptions'] = [
      for (final ref in refs)
        {
          'caption': {'base_caption': caption(ref), 'char_captions': <dynamic>[]},
          'legacy_uc': false,
        },
    ];
    parameters['director_reference_strength_values'] = List.filled(
      refs.length,
      strength,
    );
    parameters['director_reference_secondary_strength_values'] = List.filled(
      refs.length,
      secondary,
    );
    parameters['director_reference_information_extracted'] = List.filled(
      refs.length,
      1.0,
    );
  }

  /// Unwraps the image out of a ZIP, a JSON `{image: base64}` body or raw
  /// image bytes.
  static Uint8List _extractImage(Uint8List bytes) {
    if (bytes.isEmpty) throw Exception('Empty NovelAI response');

    if (_isZip(bytes)) {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive.files) {
        if (!file.isFile) continue;
        if (_isImageName(file.name) && file.content.isNotEmpty) {
          return file.content;
        }
      }
      for (final file in archive.files) {
        if (file.isFile && file.content.isNotEmpty) return file.content;
      }
      throw Exception('No image in NovelAI ZIP response');
    }

    if (bytes[0] == 0x7B) {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) {
        // Official `Accept: application/json` shape: {images: [{image, ...}]}.
        final images = decoded['images'];
        if (images is List) {
          for (final entry in images) {
            if (entry is Map && entry['image'] is String) {
              final image = entry['image'] as String;
              if (image.isNotEmpty) {
                return ImageGenHttp.base64ToBytes(
                  ImageGenHttp.stripBase64Prefix(image),
                );
              }
            }
          }
        }
        final image = decoded['image'];
        if (image is String && image.isNotEmpty) {
          return ImageGenHttp.base64ToBytes(
            ImageGenHttp.stripBase64Prefix(image),
          );
        }
      }
    }

    if (_looksLikeImage(bytes)) return bytes;

    try {
      final text = utf8.decode(bytes).trim();
      if (text.isNotEmpty && !text.contains(RegExp(r'\s'))) {
        return ImageGenHttp.base64ToBytes(
          ImageGenHttp.stripBase64Prefix(text),
        );
      }
    } catch (_) {
      // Not text either — fall through to the error.
    }
    throw Exception('Unrecognized NovelAI image response');
  }

  static bool _isZip(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);

  static bool _isImageName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp');
  }

  static bool _looksLikeImage(Uint8List b) {
    if (b.length < 4) return false;
    // PNG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return true;
    }
    // JPEG
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
    // GIF
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true;
    // WebP (RIFF....WEBP)
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return true;
    }
    return false;
  }
}
