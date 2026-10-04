import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../image_gen_models.dart';
import 'image_gen_http.dart';

/// AUTOMATIC1111 / Forge / reForge `txt2img`.
///
/// Ported from https://github.com/0xl0cal/sillyimages (`src/providers.js`,
/// `A1111Provider`). Local Stable Diffusion backends take a tag-style prompt
/// and no reference images, so the `[STYLE: ...]` block and the reference
/// blocks are deliberately not sent — the user supplies a tag prefix instead.
class A1111ImageProvider {
  final ImageGenHttp _http = ImageGenHttp();

  Future<Uint8List> generate({
    required A1111ImageSettings settings,
    required String prompt,
    CancelToken? cancelToken,
  }) async {
    final url = '${_base(settings.endpoint)}/sdapi/v1/txt2img';

    final prefix = settings.promptPrefix.trim();
    final positive = prefix.isEmpty
        ? prompt.trim()
        : '$prefix, ${prompt.trim()}'.replaceAll(RegExp(r'^,\s*|,\s*$'), '');

    final overrideSettings = <String, dynamic>{
      'CLIP_stop_at_last_layers': settings.clipSkip.clamp(1, 12),
      if (settings.model.trim().isNotEmpty)
        'sd_model_checkpoint': settings.model.trim(),
      if (_isValidVae(settings.vae)) 'sd_vae': settings.vae,
    };

    final json = await _http.post(
      url: url,
      apiKey: null,
      extraHeaders: _authHeaders(settings.apiKey),
      body: {
        'prompt': positive,
        'negative_prompt': settings.negativePrompt,
        'steps': settings.steps.clamp(1, 150),
        'cfg_scale': settings.cfgScale.clamp(1, 30),
        'width': settings.width.clamp(64, 4096),
        'height': settings.height.clamp(64, 4096),
        'sampler_name': settings.sampler,
        'scheduler': settings.scheduler,
        'seed': settings.seed.clamp(-1, 2147483647),
        'n_iter': 1,
        'batch_size': 1,
        'restore_faces': settings.restoreFaces,
        'enable_hr': settings.enableHr,
        if (settings.hrUpscaler.isNotEmpty) 'hr_upscaler': settings.hrUpscaler,
        'hr_scale': settings.hrScale.clamp(1, 4),
        'denoising_strength': settings.denoisingStrength.clamp(0, 1),
        'hr_second_pass_steps': settings.hrSecondPassSteps.clamp(0, 150),
        'clip_skip': settings.clipSkip.clamp(1, 12),
        'override_settings': overrideSettings,
        'override_settings_restore_afterwards': false,
        'save_images': true,
        'send_images': true,
        if (settings.adetailerFace)
          'alwayson_scripts': {
            'ADetailer': {
              'args': [
                true,
                true,
                {'ad_model': 'face_yolov8n.pt'},
              ],
            },
          },
      },
      cancelToken: cancelToken,
    );

    final images = json['images'];
    if (images is! List || images.isEmpty || images.first is! String) {
      throw Exception('No image in AUTOMATIC1111 response');
    }
    return ImageGenHttp.base64ToBytes(
      ImageGenHttp.stripBase64Prefix(images.first as String),
    );
  }

  /// Checkpoint titles for the model picker.
  Future<List<String>> fetchModels(A1111ImageSettings settings) async {
    final data = await _getList(
      '${_base(settings.endpoint)}/sdapi/v1/sd-models',
      settings.apiKey,
    );
    return data
        .whereType<Map<Object?, Object?>>()
        .map(
          (model) => (model['title'] ?? model['model_name'])?.toString() ?? '',
        )
        .where((title) => title.isNotEmpty)
        .toList();
  }

  Future<List<String>> fetchSamplers(A1111ImageSettings settings) async {
    try {
      final data = await _getList(
        '${_base(settings.endpoint)}/sdapi/v1/samplers',
        settings.apiKey,
      );
      final names = data
          .whereType<Map<Object?, Object?>>()
          .map((sampler) => sampler['name']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toList();
      return names.isEmpty ? A1111Constants.samplers : names;
    } catch (_) {
      return A1111Constants.samplers;
    }
  }

  Future<List<String>> fetchSchedulers(A1111ImageSettings settings) async {
    try {
      final data = await _getList(
        '${_base(settings.endpoint)}/sdapi/v1/schedulers',
        settings.apiKey,
      );
      final names = data
          .whereType<Map<Object?, Object?>>()
          .map(
            (scheduler) =>
                (scheduler['label'] ?? scheduler['name'])?.toString() ?? '',
          )
          .where((name) => name.isNotEmpty)
          .toList();
      return names.isEmpty ? A1111Constants.schedulers : names;
    } catch (_) {
      return A1111Constants.schedulers;
    }
  }

  Future<List<String>> fetchUpscalers(A1111ImageSettings settings) async {
    try {
      final data = await _getList(
        '${_base(settings.endpoint)}/sdapi/v1/upscalers',
        settings.apiKey,
      );
      return data
          .whereType<Map<Object?, Object?>>()
          .map((upscaler) => upscaler['name']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Object?>> _getList(String url, String apiKey) async {
    final response = await Dio().get<dynamic>(
      url,
      options: Options(headers: _authHeaders(apiKey)),
    );
    final data = response.data;
    return data is List ? data : const [];
  }

  static Map<String, String> _authHeaders(String apiKey) {
    final key = apiKey.trim();
    if (key.isEmpty) return const {};
    // A1111 `--api-auth user:password` uses HTTP basic auth.
    return {'Authorization': 'Basic ${base64Encode(utf8.encode(key))}'};
  }

  static bool _isValidVae(String vae) {
    final value = vae.trim();
    return value.isNotEmpty && value != 'None' && value != 'N/A';
  }

  static String _base(String endpoint) {
    final trimmed = endpoint.trim();
    return (trimmed.isEmpty ? A1111Constants.defaultEndpoint : trimmed)
        .replaceFirst(RegExp(r'/+$'), '');
  }
}
