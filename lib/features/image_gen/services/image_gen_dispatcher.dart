import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/llm/transport/llm_capture_context.dart';
import '../../../core/llm/transport/llm_request_capture.dart';
import '../image_gen_capabilities.dart';
import '../image_gen_models.dart';
import 'a1111_image_provider.dart';
import 'comfyui_image_provider.dart';
import 'gemini_image_provider.dart';
import 'image_prompt_builder.dart';
import 'naistera_image_provider.dart';
import 'novelai_image_provider.dart';
import 'openai_image_provider.dart';
import 'openrouter_image_provider.dart';
import 'routmy_image_provider.dart';
import 'xai_image_provider.dart';

/// Routes a prepared prompt + reference set to the configured provider client.
///
/// Everything prompt-shaped (style block, reference descriptions, critical
/// instruction) has already been applied by the caller; this class only knows
/// about endpoints, credentials and per-model parameter validation.
class ImageGenDispatcher {
  const ImageGenDispatcher();

  Future<Uint8List> generate({
    required ImageGenSettings settings,
    required String prompt,
    required List<Map<String, String>> references,
    required String llmEndpoint,
    required String llmApiKey,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
  }) async {
    // Image providers talk to their own endpoints over Dio, so nothing in the
    // transport layer sees them: without this the turn that drew a picture
    // showed every request it made except the one that drew it.
    LlmRequestCapture.recordAuxiliary(
      stage: captureContext?.stage ?? 'image.generate',
      endpoint: settings.useSameEndpoint
          ? llmEndpoint
          : settings.customEndpoint,
      model: _captureModel(settings),
      context: captureContext,
      messages: [
        {'role': 'prompt', 'content': prompt},
      ],
      params: {
        'apiType': settings.apiType.name,
        'referenceCount': references.length,
        'aspectRatio': ?instructionAspectRatio,
        'imageSize': ?instructionImageSize,
      },
    );
    switch (settings.apiType) {
      case ImageGenApiType.openai:
        return _openai(
          settings,
          prompt,
          references,
          llmEndpoint,
          llmApiKey,
          instructionAspectRatio,
          cancelToken,
        );
      case ImageGenApiType.xai:
        return _xai(
          settings,
          prompt,
          references,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken,
        );
      case ImageGenApiType.electronhub:
        return _electronhub(
          settings,
          prompt,
          references,
          instructionAspectRatio,
          cancelToken,
        );
      case ImageGenApiType.gemini:
        return _gemini(
          settings,
          prompt,
          references,
          llmEndpoint,
          llmApiKey,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken,
        );
      case ImageGenApiType.openrouter:
        return _openrouter(
          settings,
          prompt,
          references,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken,
        );
      case ImageGenApiType.naistera:
        return NaisteraImageProvider().generate(
          apiKey: settings.naisteraApiKey,
          model: settings.naisteraModel,
          prompt: prompt,
          aspectRatio: _validOverride(
            instructionAspectRatio,
            NaisteraConstants.aspectRatios,
            settings.naisteraAspectRatio,
          ),
          references: references.isEmpty ? null : references,
          supportsReferences: settings.naisteraSupportsReferences,
          cancelToken: cancelToken,
        );
      case ImageGenApiType.routmy:
        return _routmy(
          settings,
          prompt,
          references,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken: cancelToken,
        );
      case ImageGenApiType.a1111:
        return A1111ImageProvider().generate(
          settings: settings.a1111,
          prompt: prompt,
          cancelToken: cancelToken,
        );
      case ImageGenApiType.novelai:
        return NovelAIImageProvider().generate(
          settings: settings.novelai,
          prompt: prompt,
          references: references,
          instructionAspectRatio: instructionAspectRatio,
          cancelToken: cancelToken,
        );
      case ImageGenApiType.comfyui:
        return ComfyUiImageProvider().generate(
          settings: settings.comfyui,
          prompt: prompt,
          cancelToken: cancelToken,
        );
    }
  }

  /// Best-effort name of the model that will draw: each provider keeps its own
  /// field, and the capture is a diagnostic, not a contract.
  static String _captureModel(ImageGenSettings settings) =>
      switch (settings.apiType) {
        ImageGenApiType.naistera => settings.naisteraModel,
        ImageGenApiType.routmy => settings.routmyModel,
        ImageGenApiType.novelai => settings.novelai.model,
        ImageGenApiType.comfyui => settings.comfyui.model.isEmpty
            ? settings.apiType.name
            : settings.comfyui.model,
        _ => settings.customModel.isEmpty
            ? settings.apiType.name
            : settings.customModel,
      };

  Future<Uint8List> _openai(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String llmEndpoint,
    String llmApiKey,
    String? instructionAspectRatio,
    CancelToken? cancelToken,
  ) {
    final endpoint = settings.useSameEndpoint
        ? llmEndpoint
        : settings.customEndpoint;
    final apiKey = settings.useSameEndpoint ? llmApiKey : settings.customApiKey;
    final model = settings.customModel.isEmpty
        ? 'dall-e-3'
        : settings.customModel;

    return OpenaiImageProvider().generate(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
      prompt: prompt,
      // The configured size wins; a per-tag aspect ratio maps to the size the
      // model family understands.
      size:
          _sizeForAspect(instructionAspectRatio, model) ??
          _effectiveSize(
            settings.openaiSize,
            settings.openaiCustomWidth,
            settings.openaiCustomHeight,
          ),
      quality: settings.openaiQuality,
      referenceImages: _imagesOf(references),
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _xai(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  ) {
    final config = settings.xai;
    return XaiImageProvider(baseUrl: config.endpoint).generate(
      apiKey: config.apiKey,
      model: config.model,
      prompt: prompt,
      aspectRatio: _validOverride(
        instructionAspectRatio,
        XaiConstants.aspectRatios,
        config.aspectRatio,
      ),
      // The tag writes `1K` / `2K`; xAI spells them lowercase.
      resolution: config.resolution == customImageSizeOption
          ? _effectiveSize(
              config.resolution,
              config.customWidth,
              config.customHeight,
            )
          : _validOverride(
              instructionImageSize?.toLowerCase(),
              XaiConstants.resolutions,
              config.resolution,
            ),
      quality: config.quality,
      references: references,
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _electronhub(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String? instructionAspectRatio,
    CancelToken? cancelToken,
  ) {
    final config = settings.electronhub;
    final endpoint = config.endpoint.trim().isEmpty
        ? ElectronHubConstants.defaultEndpoint
        : config.endpoint.trim();

    // Electron Hub's /v1/images/edits takes a single `image` field only.
    return OpenaiImageProvider(allowMultiImageField: false).generate(
      endpoint: endpoint,
      apiKey: config.apiKey,
      model: config.model,
      prompt: prompt,
      size:
          _sizeForAspect(instructionAspectRatio, config.model) ??
          _effectiveSize(config.size, config.customWidth, config.customHeight),
      quality: config.quality,
      referenceImages: _imagesOf(references),
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _gemini(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String llmEndpoint,
    String llmApiKey,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  ) {
    final endpoint = settings.useSameEndpoint
        ? llmEndpoint
        : settings.customEndpoint;
    final apiKey = settings.useSameEndpoint ? llmApiKey : settings.customApiKey;
    final model = settings.customModel.isEmpty
        ? 'imagen-3.0-generate-002'
        : settings.customModel;
    final caps = geminiCapabilities(model);

    return GeminiImageProvider().generate(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
      prompt: prompt,
      aspectRatio: _validOverride(
        instructionAspectRatio,
        caps.aspectRatios,
        settings.geminiAspectRatio,
      ),
      // Gemini 2.5 Flash Image has no imageSize parameter.
      imageSize: caps.imageSizes == null
          ? null
          : _resolveSize(
              override: instructionImageSize,
              allowed: caps.imageSizes!,
              configured: settings.geminiImageSize,
              width: settings.geminiCustomWidth,
              height: settings.geminiCustomHeight,
            ),
      referenceImages: references.take(caps.maxReferences).toList(),
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _openrouter(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  ) {
    final config = settings.openrouter;
    final caps = openRouterCapabilities(config.model);

    return OpenRouterImageProvider().generate(
      apiKey: config.apiKey,
      endpoint: config.endpoint,
      model: config.model,
      prompt: prompt,
      aspectRatio: _validOverride(
        instructionAspectRatio,
        caps.aspectRatios,
        config.aspectRatio,
      ),
      imageSize: caps.imageSizes == null
          ? ''
          : _resolveSize(
              override: instructionImageSize,
              allowed: caps.imageSizes!,
              configured: config.imageSize,
              width: config.customWidth,
              height: config.customHeight,
            ),
      references: references,
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _routmy(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String? instructionAspectRatio,
    String? instructionImageSize, {
    CancelToken? cancelToken,
  }) {
    final images = _imagesOf(references);
    return RoutmyImageProvider(
      baseUrl: settings.routmyMirror.baseUrl,
    ).generate(
      apiKey: settings.routmyApiKey,
      model: settings.routmyModel,
      // rout.my sends references without captions — name them in the prompt.
      prompt: imagePromptWithReferenceLabels(prompt, references),
      aspectRatio: _validOverride(
        instructionAspectRatio,
        RoutMyConstants.aspectRatios,
        settings.routmyAspectRatio,
      ),
      imageSize: _resolveSize(
        override: instructionImageSize,
        allowed: RoutMyConstants.imageSizes,
        configured: settings.routmyImageSize,
        width: settings.routmyCustomWidth,
        height: settings.routmyCustomHeight,
      ),
      quality: settings.routmyQuality,
      referenceImages: images,
      cancelToken: cancelToken,
    );
  }

  /// `size` for a per-tag aspect ratio on the OpenAI images API, or null when
  /// the tag carried no (usable) ratio for this model family.
  static String? _sizeForAspect(String? instructionAspectRatio, String model) {
    final aspect = instructionAspectRatio?.trim();
    if (aspect == null || !OpenAIConstants.aspectRatios.contains(aspect)) {
      return null;
    }
    return openAiAspectRatioToSize(aspect, classifyOpenAiImageModel(model));
  }

  static List<String>? _imagesOf(List<Map<String, String>> references) {
    final images = references
        .map((ref) => ref['image'] ?? '')
        .where((image) => image.isNotEmpty)
        .toList();
    return images.isEmpty ? null : images;
  }

  /// Accepts a per-tag override only when the provider/model allows it.
  static String _validOverride(
    String? override,
    List<String> allowed,
    String fallback,
  ) {
    final value = override?.trim();
    return value != null && allowed.contains(value) ? value : fallback;
  }

  /// The effective size: a valid per-tag override wins, then the manual
  /// `{width}x{height}` when the picker is on the "Custom" entry, then the
  /// configured preset.
  static String _resolveSize({
    required String? override,
    required List<String> allowed,
    required String configured,
    required int width,
    required int height,
  }) {
    final value = override?.trim();
    if (value != null && value.isNotEmpty && allowed.contains(value)) {
      return value;
    }
    return _effectiveSize(configured, width, height);
  }

  /// Expands the "Custom" sentinel into `{width}x{height}`; any other value
  /// passes through unchanged.
  static String _effectiveSize(String configured, int width, int height) =>
      configured == customImageSizeOption ? '${width}x$height' : configured;
}
