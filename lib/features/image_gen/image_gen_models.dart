import 'package:freezed_annotation/freezed_annotation.dart';

import 'image_gen_constants.dart';

export 'image_gen_constants.dart';

part 'image_gen_models.freezed.dart';

enum ImageGenApiType {
  openai,
  xai,
  gemini,
  naistera,
  routmy,
  ruRoutmy,
  openrouter,
  electronhub,
  a1111,
  novelai,
}

extension ImageGenApiTypeLabel on ImageGenApiType {
  /// Provider name shown in the settings sheet.
  String get label => switch (this) {
    ImageGenApiType.openai => 'OpenAI',
    ImageGenApiType.xai => 'xAI Imagine',
    ImageGenApiType.gemini => 'Gemini',
    ImageGenApiType.naistera => 'Naistera',
    ImageGenApiType.routmy => 'rout.my',
    ImageGenApiType.ruRoutmy => 'RU-rout.my',
    ImageGenApiType.openrouter => 'OpenRouter',
    ImageGenApiType.electronhub => 'Electron Hub',
    ImageGenApiType.a1111 => 'AUTOMATIC1111 / Forge',
    ImageGenApiType.novelai => 'NovelAI',
  };
}

/// How the character / persona appearance descriptions reach a Naistera
/// prompt.
///
/// Ported from https://github.com/0xl0cal/sillyimages
/// (`naisteraCharacterDescriptionsMode`).
enum CharacterDescriptionsMode {
  /// Never append them.
  none,

  /// `Character descriptions:` block with one `- {{char}}: ...` line each.
  asIs,

  /// NovelAI character prompts — one `\| description` line per character,
  /// persona first.
  characterPrompt,
}

/// One model of the Naistera catalog as served by `GET /api/models`.
///
/// The catalog is fetched in the settings sheet and persisted, so reference
/// support follows what the API says instead of a hardcoded deny-list.
@freezed
abstract class NaisteraModelInfo with _$NaisteraModelInfo {
  const factory NaisteraModelInfo({
    required String id,
    @Default('') String name,
    @Default(true) bool references,
  }) = _NaisteraModelInfo;
}

/// xAI Imagine connection and per-model parameters.
@freezed
abstract class XaiImageSettings with _$XaiImageSettings {
  const factory XaiImageSettings({
    @Default('') String apiKey,
    @Default('') String endpoint,
    @Default('grok-imagine-image-2.0') String model,
    @Default('1:1') String aspectRatio,
    @Default('1k') String resolution,
    @Default('medium') String quality,
  }) = _XaiImageSettings;
}

/// One entry of the shared reference library: an image plus the trigger names
/// that pull it into a prompt.
///
/// [name] is a comma-separated alias list. [description] is sent to the
/// provider next to the image when `sendRefDescriptions` is on, so the model
/// knows *who* the picture shows.
@freezed
abstract class ReferenceImage with _$ReferenceImage {
  const factory ReferenceImage({
    required String name,
    required String imageData,
    @Default('match') String matchMode,
    @Default('') String description,
    @Default(true) bool enabled,
  }) = _ReferenceImage;
}

/// A named prompt style. The active style replaces whatever `style` the model
/// wrote into the image tag; with no active style the tag's own style wins.
@freezed
abstract class ImageStyle with _$ImageStyle {
  const factory ImageStyle({
    required String id,
    required String name,
    @Default('') String value,
  }) = _ImageStyle;
}

@freezed
abstract class OpenRouterImageSettings with _$OpenRouterImageSettings {
  const factory OpenRouterImageSettings({
    @Default('') String apiKey,
    @Default('') String endpoint,
    @Default('google/gemini-2.5-flash-image') String model,
    @Default('1:1') String aspectRatio,
    @Default('1K') String imageSize,
  }) = _OpenRouterImageSettings;
}

@freezed
abstract class ElectronHubImageSettings with _$ElectronHubImageSettings {
  const factory ElectronHubImageSettings({
    @Default('') String apiKey,
    @Default('') String endpoint,
    @Default('gpt-image-1') String model,
    @Default('1024x1024') String size,
    @Default('standard') String quality,
  }) = _ElectronHubImageSettings;
}

/// AUTOMATIC1111 / Forge / reForge `txt2img` parameters.
@freezed
abstract class A1111ImageSettings with _$A1111ImageSettings {
  const factory A1111ImageSettings({
    @Default('') String endpoint,
    @Default('') String apiKey,
    @Default('') String model,
    @Default(512) int width,
    @Default(512) int height,
    @Default(20) int steps,
    @Default(7.0) double cfgScale,
    @Default('Euler a') String sampler,
    @Default('Automatic') String scheduler,
    @Default(-1) int seed,
    @Default(1) int clipSkip,
    @Default('') String promptPrefix,
    @Default('') String negativePrompt,
    @Default('') String vae,
    @Default(false) bool restoreFaces,
    @Default(false) bool enableHr,
    @Default('') String hrUpscaler,
    @Default(2.0) double hrScale,
    @Default(0.7) double denoisingStrength,
    @Default(0) int hrSecondPassSteps,
    @Default(false) bool adetailerFace,
  }) = _A1111ImageSettings;
}

/// NovelAI Image Generation connection and sampling parameters.
@freezed
abstract class NovelAIImageSettings with _$NovelAIImageSettings {
  const factory NovelAIImageSettings({
    @Default('') String apiKey,
    @Default('') String endpoint,
    @Default('nai-diffusion-4-5-full') String model,
    @Default('k_euler_ancestral') String sampler,
    @Default('karras') String noiseSchedule,
    @Default(28) int steps,
    @Default(5.0) double scale,
    @Default(0.0) double cfgRescale,
    @Default(832) int width,
    @Default(1216) int height,
    @Default(-1) int seed,
    @Default('') String negativePrompt,
    @Default('light') String ucPreset,
    @Default(true) bool qualityToggle,
    @Default(false) bool varietyBoost,
  }) = _NovelAIImageSettings;
}

@freezed
abstract class ImageGenSettings with _$ImageGenSettings {
  const factory ImageGenSettings({
    @Default(false) bool enabled,

    /// Fire every image tag of a message at the same time. Off by default:
    /// the images of one message are generated one at a time, each finished
    /// from start to end before the next one starts.
    @Default(false) bool concurrentGeneration,
    @Default(ImageGenApiType.openai) ImageGenApiType apiType,
    @Default(true) bool useSameEndpoint,
    @Default('') String customEndpoint,
    @Default('') String customApiKey,
    @Default('') String customModel,
    @Default('1024x1024') String openaiSize,
    @Default('standard') String openaiQuality,
    @Default('1:1') String geminiAspectRatio,
    @Default('1K') String geminiImageSize,
    @Default('') String naisteraApiKey,
    @Default('grok') String naisteraModel,
    @Default('1:1') String naisteraAspectRatio,

    /// Catalog last loaded from `GET /api/models`. Empty until the user hits
    /// refresh — [NaisteraConstants.models] is the fallback shortlist.
    @Default([]) List<NaisteraModelInfo> naisteraModels,
    @Default(CharacterDescriptionsMode.asIs)
    CharacterDescriptionsMode naisteraCharacterDescriptionsMode,
    @Default('') String routmyApiKey,
    @Default('google/gemini-3.1-flash-image-preview') String routmyModel,
    @Default('1:1') String routmyAspectRatio,
    @Default('1K') String routmyImageSize,
    @Default('standard') String routmyQuality,
    @Default('') String ruRoutmyApiKey,
    @Default('google/gemini-3.1-flash-image-preview') String ruRoutmyModel,
    @Default('1:1') String ruRoutmyAspectRatio,
    @Default('1K') String ruRoutmyImageSize,
    @Default('standard') String ruRoutmyQuality,
    @Default(XaiImageSettings()) XaiImageSettings xai,
    @Default(OpenRouterImageSettings()) OpenRouterImageSettings openrouter,
    @Default(ElectronHubImageSettings()) ElectronHubImageSettings electronhub,
    @Default(A1111ImageSettings()) A1111ImageSettings a1111,
    @Default(NovelAIImageSettings()) NovelAIImageSettings novelai,
    // Reference handling — shared by every provider that accepts references.
    @Default(false) bool sendCharAvatar,
    @Default(false) bool sendUserAvatar,
    @Default([]) List<ReferenceImage> references,
    @Default(true) bool sendRefDescriptions,
    @Default(true) bool refInstructionEnabled,
    @Default('') String refInstruction,
    @Default(false) bool imageContextEnabled,
    @Default(1) int imageContextCount,
    // Style library. An empty [activeStyleId] means "no style" — the style
    // written by the model into the image tag is used as-is.
    @Default([]) List<ImageStyle> styles,
    @Default('') String activeStyleId,
  }) = _ImageGenSettings;

  const ImageGenSettings._();

  /// Effective critical instruction sent with reference images, or an empty
  /// string when the user switched it off.
  String get effectiveRefInstruction {
    if (!refInstructionEnabled) return '';
    final raw = refInstruction.trim();
    return raw.isEmpty ? defaultReferenceInstruction : raw;
  }

  /// Reference support of the selected Naistera model: the fetched catalog
  /// when it knows the model, the shipped deny-list otherwise.
  bool get naisteraSupportsReferences {
    final id = NaisteraConstants.normalizeModel(naisteraModel);
    for (final model in naisteraModels) {
      if (model.id == id || model.id == naisteraModel) return model.references;
    }
    return NaisteraConstants.supportsReferences(naisteraModel);
  }

  /// Human-readable label of a Naistera model id — the catalog name when it is
  /// known, then the shipped shortlist, then the raw id.
  String naisteraModelLabel(String id) {
    for (final model in naisteraModels) {
      if (model.id == id) {
        return model.name.trim().isEmpty ? model.id : model.name;
      }
    }
    for (final model in NaisteraConstants.models) {
      if (model.$1 == id) return model.$2;
    }
    return id;
  }

  /// Active style, or null when "no style" is selected.
  ImageStyle? get activeStyle {
    if (activeStyleId.isEmpty) return null;
    for (final style in styles) {
      if (style.id == activeStyleId) return style;
    }
    return null;
  }
}
