import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/llm/transport/endpoint_normalizer.dart';
import '../image_gen_models.dart';
import 'comfyui_image_provider.dart';

/// Lightweight connectivity and model-discovery requests for the image-gen
/// settings sheet. Generation itself remains in the provider-specific clients.
class ImageGenConnectionService {
  final Dio _dio;

  ImageGenConnectionService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ),
          );

  Future<void> checkConnection({
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
  }) async {
    switch (settings.apiType) {
      case ImageGenApiType.openai:
        final connection = _openAiConnection(
          settings: settings,
          llmEndpoint: llmEndpoint,
          llmApiKey: llmApiKey,
        );
        await _get(_openAiModelsUrl(connection.endpoint), connection.apiKey);
      case ImageGenApiType.gemini:
        final connection = _openAiConnection(
          settings: settings,
          llmEndpoint: llmEndpoint,
          llmApiKey: llmApiKey,
        );
        await _get(_geminiModelsUrl(connection.endpoint), connection.apiKey);
      case ImageGenApiType.xai:
        if (settings.xai.apiKey.trim().isEmpty) {
          throw StateError('xAI API key not configured');
        }
        await _get(
          '${XaiConstants.normalizeEndpoint(settings.xai.endpoint)}/v1/models',
          settings.xai.apiKey,
        );
      case ImageGenApiType.naistera:
        if (settings.naisteraApiKey.trim().isEmpty) {
          throw StateError('Naistera API key not configured');
        }
        await _get(
          '${NaisteraConstants.baseUrl}/api/models',
          settings.naisteraApiKey,
        );
      case ImageGenApiType.routmy:
        if (settings.routmyApiKey.trim().isEmpty) {
          throw StateError('rout.my API key not configured');
        }
        // `/v1/models` is a public catalog and answers 200 for any key, so a
        // real probe has to hit an authenticated route.
        await _checkRoutmyChat(
          settings.routmyMirror.baseUrl,
          settings.routmyApiKey,
        );
      case ImageGenApiType.openrouter:
        if (settings.openrouter.apiKey.trim().isEmpty) {
          throw StateError('OpenRouter API key not configured');
        }
        await _get(
          '${_openRouterBase(settings)}/models',
          settings.openrouter.apiKey,
        );
      case ImageGenApiType.electronhub:
        if (settings.electronhub.apiKey.trim().isEmpty) {
          throw StateError('Electron Hub API key not configured');
        }
        await _get(
          _openAiModelsUrl(_electronHubBase(settings)),
          settings.electronhub.apiKey,
        );
      case ImageGenApiType.a1111:
        // /sdapi/v1/sd-models answers as soon as the server runs with --api.
        await _get(
          '${_a1111Base(settings)}/sdapi/v1/sd-models',
          null,
          extraHeaders: _a1111AuthHeaders(settings.a1111.apiKey),
        );
      case ImageGenApiType.novelai:
        if (settings.novelai.apiKey.trim().isEmpty) {
          throw StateError('NovelAI API key not configured');
        }
        // Tag suggestions is a cheap authenticated GET on the image host.
        await _get(
          '${_novelAiBase(settings)}/ai/generate-image/suggest-tags'
          '?model=${Uri.encodeQueryComponent(settings.novelai.model)}'
          '&prompt=a',
          settings.novelai.apiKey,
        );
      case ImageGenApiType.comfyui:
        // /system_stats is the cheapest route that proves the server is up.
        await _get(
          '${_comfyUiBase(settings)}/system_stats',
          null,
          extraHeaders: _comfyUiAuthHeaders(settings.comfyui.apiKey),
        );
    }
  }

  /// Image models exposed by xAI. The listing mixes chat and image models, so
  /// only the ones whose id reads as an image model are kept.
  Future<List<String>> fetchXaiModels(ImageGenSettings settings) async {
    final data = await _get(
      '${XaiConstants.normalizeEndpoint(settings.xai.endpoint)}/v1/models',
      settings.xai.apiKey,
    );
    final models = data is Map ? data['data'] : null;
    if (models is! List) return const [];
    return models
        .whereType<Map<Object?, Object?>>()
        .map((model) => model['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty && id.toLowerCase().contains('image'))
        .toList();
  }

  /// Image models exposed by rout.my (`GET /v1/models`). Each entry keeps the
  /// `/images/edits` capability the catalog advertises, which decides whether
  /// references can be routed for that model. Entries without an `endpoints`
  /// field fall back to keyword matching.
  Future<List<RoutmyModelInfo>> fetchRoutmyModels(
    ImageGenSettings settings,
  ) async {
    final data = await _get(
      '${settings.routmyMirror.baseUrl}/v1/models',
      settings.routmyApiKey,
    );
    final models = data is Map ? data['data'] : null;
    if (models is! List) return const [];
    final result = <RoutmyModelInfo>[];
    for (final raw in models.whereType<Map<Object?, Object?>>()) {
      final id = raw['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final endpoints = raw['endpoints'];
      final endpointList = endpoints is List
          ? endpoints.map((endpoint) => endpoint.toString()).toList()
          : const <String>[];
      final isImage = endpointList.isEmpty
          ? _looksLikeImageModel(id)
          : endpointList.any((endpoint) => endpoint.contains('/images/'));
      if (!isImage) continue;
      result.add(
        RoutmyModelInfo(
          id: id,
          name: raw['name']?.toString() ?? '',
          supportsEdits: endpointList.any(
            (endpoint) => endpoint.contains('/images/edits'),
          ),
        ),
      );
    }
    return result;
  }

  /// Image models exposed by OpenRouter (`output_modalities=image`).
  Future<List<String>> fetchOpenRouterModels(ImageGenSettings settings) async {
    final data = await _get(
      '${_openRouterBase(settings)}/models'
      '?input_modalities=image%2Ctext&output_modalities=image',
      settings.openrouter.apiKey,
    );
    final models = data is Map ? data['data'] : null;
    if (models is! List) return const [];
    return models
        .whereType<Map<Object?, Object?>>()
        .map((model) => model['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  /// Electron Hub tags each model with the endpoints it serves; image models
  /// are the ones exposing `/images/generations` or `/images/edits`. Older
  /// responses without the field fall back to keyword matching.
  Future<List<String>> fetchElectronHubModels(ImageGenSettings settings) async {
    final data = await _get(
      _openAiModelsUrl(_electronHubBase(settings)),
      settings.electronhub.apiKey,
    );
    final models = data is Map ? data['data'] : null;
    if (models is! List) return const [];
    return models
        .whereType<Map<Object?, Object?>>()
        .where((model) {
          final endpoints = model['endpoints'];
          if (endpoints is List && endpoints.isNotEmpty) {
            return endpoints.any(
              (endpoint) =>
                  endpoint.toString().contains('/images/generations') ||
                  endpoint.toString().contains('/images/edits'),
            );
          }
          return _looksLikeImageModel(model['id']?.toString() ?? '');
        })
        .map((model) => model['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  /// Checkpoints loaded by the local AUTOMATIC1111 / Forge server.
  Future<List<String>> fetchA1111Models(ImageGenSettings settings) async {
    final data = await _get(
      '${_a1111Base(settings)}/sdapi/v1/sd-models',
      null,
      extraHeaders: _a1111AuthHeaders(settings.a1111.apiKey),
    );
    if (data is! List) return const [];
    return data
        .whereType<Map<Object?, Object?>>()
        .map(
          (model) => (model['title'] ?? model['model_name'])?.toString() ?? '',
        )
        .where((title) => title.isNotEmpty)
        .toList();
  }

  /// Checkpoint / UNet / GGUF entries loaded by the local ComfyUI server.
  Future<List<String>> fetchComfyUiModels(ImageGenSettings settings) =>
      ComfyUiImageProvider().fetchModels(settings.comfyui);

  static String _openRouterBase(ImageGenSettings settings) {
    final endpoint = settings.openrouter.endpoint.trim();
    return (endpoint.isEmpty ? OpenRouterConstants.defaultEndpoint : endpoint)
        .replaceFirst(RegExp(r'/+$'), '');
  }

  static String _electronHubBase(ImageGenSettings settings) {
    final endpoint = settings.electronhub.endpoint.trim();
    return (endpoint.isEmpty ? ElectronHubConstants.defaultEndpoint : endpoint)
        .replaceFirst(RegExp(r'/+$'), '');
  }

  static String _novelAiBase(ImageGenSettings settings) =>
      NovelAIConstants.normalizeEndpoint(settings.novelai.endpoint);

  static String _a1111Base(ImageGenSettings settings) {
    final endpoint = settings.a1111.endpoint.trim();
    return (endpoint.isEmpty ? A1111Constants.defaultEndpoint : endpoint)
        .replaceFirst(RegExp(r'/+$'), '');
  }

  static Map<String, String> _a1111AuthHeaders(String apiKey) {
    final key = apiKey.trim();
    if (key.isEmpty) return const {};
    return {'Authorization': 'Basic ${base64Encode(utf8.encode(key))}'};
  }

  static String _comfyUiBase(ImageGenSettings settings) {
    final endpoint = settings.comfyui.endpoint.trim();
    return (endpoint.isEmpty ? ComfyUiConstants.defaultEndpoint : endpoint)
        .replaceFirst(RegExp(r'/+$'), '');
  }

  static Map<String, String> _comfyUiAuthHeaders(String apiKey) {
    final key = apiKey.trim();
    if (key.isEmpty) return const {};
    return {'Authorization': 'Basic ${base64Encode(utf8.encode(key))}'};
  }

  Future<List<String>> fetchOpenAiModels({
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
  }) async {
    final connection = _openAiConnection(
      settings: settings,
      llmEndpoint: llmEndpoint,
      llmApiKey: llmApiKey,
    );
    final data = await _get(
      _openAiModelsUrl(connection.endpoint),
      connection.apiKey,
    );
    final models = data is Map ? data['data'] : null;
    if (models is! List) return const [];

    return models
        .whereType<Map<Object?, Object?>>()
        .map((model) => model['id']?.toString() ?? '')
        .where(_looksLikeImageModel)
        .toList();
  }

  static const _imageKeywords = [
    'dall-e',
    'midjourney',
    'stable-diffusion',
    'sdxl',
    'flux',
    'imagen',
    'image',
    'seedream',
    'hidream',
    'ideogram',
    'gpt-image',
    'wanx',
    'qwen',
    'drawing',
  ];
  static const _videoKeywords = [
    'sora',
    'kling',
    'veo',
    'pika',
    'runway',
    'luma',
    'video',
    'cogvideo',
  ];

  static bool _looksLikeImageModel(String id) {
    if (id.isEmpty) return false;
    final lower = id.toLowerCase();
    return !_videoKeywords.any(lower.contains) &&
        _imageKeywords.any(lower.contains);
  }

  ({String endpoint, String apiKey}) _openAiConnection({
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
  }) {
    final endpoint =
        (settings.useSameEndpoint ? llmEndpoint : settings.customEndpoint)
            .trim();
    final apiKey =
        (settings.useSameEndpoint ? llmApiKey : settings.customApiKey).trim();
    if (endpoint.isEmpty) throw StateError('Image endpoint not configured');
    if (apiKey.isEmpty) throw StateError('Image API key not configured');
    return (endpoint: endpoint, apiKey: apiKey);
  }

  Future<dynamic> _get(
    String url,
    String? apiKey, {
    Map<String, String> extraHeaders = const {},
  }) async {
    final response = await _dio.get<dynamic>(
      url,
      options: Options(
        headers: {
          if (apiKey != null && apiKey.isNotEmpty)
            'Authorization': 'Bearer $apiKey',
          ...extraHeaders,
        },
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw StateError('HTTP $status');
    }
    return response.data;
  }

  /// Minimal authenticated request that proves the rout.my key is accepted.
  /// `GET /v1/models` cannot be used: it is a public catalog that answers 200
  /// for any key, so it would report a bad key as connected. A 403 still means
  /// the key is valid (the probe model is just unavailable on the plan).
  Future<void> _checkRoutmyChat(String baseUrl, String apiKey) async {
    final response = await _dio.post<dynamic>(
      '$baseUrl/v1/chat/completions',
      data: {
        'model': 'openai/gpt-5.4-mini',
        'messages': [
          {'role': 'user', 'content': 'ping'},
        ],
        'max_tokens': 1,
        'stream': false,
      },
      options: Options(
        headers: {'Authorization': 'Bearer $apiKey'},
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300 || status == 403) return;
    if (status == 401) {
      throw StateError('Invalid rout.my API key (HTTP 401)');
    }
    throw StateError('HTTP $status${_errorMessage(response.data)}');
  }

  /// `error.message` from a rout.my error body, prefixed for a status line.
  static String _errorMessage(dynamic data) {
    if (data is Map) {
      final error = data['error'];
      if (error is Map) {
        final message = error['message'];
        if (message is String && message.trim().isNotEmpty) {
          return ': ${message.trim()}';
        }
      }
    }
    return '';
  }

  /// Both probes reuse the chat transports' normalization, so an endpoint
  /// typed without a scheme or without `/v1` is checked at the URL the
  /// provider will actually be called on.
  static String _openAiModelsUrl(String endpoint) =>
      EndpointNormalizer.modelsUrl(endpoint);

  static String _geminiModelsUrl(String endpoint) {
    final base = EndpointNormalizer.geminiBase(endpoint);
    return base.isEmpty ? '' : '$base/v1beta/models';
  }

  void dispose() => _dio.close();
}
