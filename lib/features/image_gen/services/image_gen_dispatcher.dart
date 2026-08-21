import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../image_gen_capabilities.dart';
import '../image_gen_models.dart';
import 'a1111_image_provider.dart';
import 'gemini_image_provider.dart';
import 'image_prompt_builder.dart';
import 'naistera_image_provider.dart';
import 'openai_image_provider.dart';
import 'openrouter_image_provider.dart';
import 'routmy_image_provider.dart';

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
  }) async {
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
          cancelToken: cancelToken,
        );
      case ImageGenApiType.routmy:
        return _routmy(
          settings,
          prompt,
          references,
          instructionAspectRatio,
          instructionImageSize,
          isRu: false,
          cancelToken: cancelToken,
        );
      case ImageGenApiType.ruRoutmy:
        return _routmy(
          settings,
          prompt,
          references,
          instructionAspectRatio,
          instructionImageSize,
          isRu: true,
          cancelToken: cancelToken,
        );
      case ImageGenApiType.a1111:
        return A1111ImageProvider().generate(
          settings: settings.a1111,
          prompt: prompt,
          cancelToken: cancelToken,
        );
    }
  }

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
          _sizeForAspect(instructionAspectRatio, model) ?? settings.openaiSize,
      quality: settings.openaiQuality,
      referenceImages: _imagesOf(references),
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
      size: _sizeForAspect(instructionAspectRatio, config.model) ?? config.size,
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
          : _validOverride(
              instructionImageSize,
              caps.imageSizes!,
              settings.geminiImageSize,
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
          : _validOverride(
              instructionImageSize,
              caps.imageSizes!,
              config.imageSize,
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
    required bool isRu,
    CancelToken? cancelToken,
  }) {
    final images = _imagesOf(references);
    return RoutmyImageProvider(
      baseUrl: isRu ? RuRoutMyConstants.baseUrl : RoutMyConstants.baseUrl,
    ).generate(
      apiKey: isRu ? settings.ruRoutmyApiKey : settings.routmyApiKey,
      model: isRu ? settings.ruRoutmyModel : settings.routmyModel,
      // rout.my sends references without captions — name them in the prompt.
      prompt: imagePromptWithReferenceLabels(prompt, references),
      aspectRatio: _validOverride(
        instructionAspectRatio,
        RoutMyConstants.aspectRatios,
        isRu ? settings.ruRoutmyAspectRatio : settings.routmyAspectRatio,
      ),
      imageSize: _validOverride(
        instructionImageSize,
        RoutMyConstants.imageSizes,
        isRu ? settings.ruRoutmyImageSize : settings.routmyImageSize,
      ),
      quality: isRu ? settings.ruRoutmyQuality : settings.routmyQuality,
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
}
