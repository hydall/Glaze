import 'package:freezed_annotation/freezed_annotation.dart';

part 'image_gen_models.freezed.dart';

enum ImageGenApiType { openai, gemini, naistera, routmy, ruRoutmy }

const routmyMaxInjectedReferenceImages = 10;

@freezed
abstract class ReferenceImage with _$ReferenceImage {
  const factory ReferenceImage({
    required String name,
    required String imageData,
    @Default('match') String matchMode,
  }) = _ReferenceImage;
}

@freezed
abstract class ImageGenSettings with _$ImageGenSettings {
  const factory ImageGenSettings({
    @Default(false) bool enabled,
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
    @Default(false) bool naisteraSendCharAvatar,
    @Default(false) bool naisteraSendUserAvatar,
    @Default('') String routmyApiKey,
    @Default('google/gemini-3.1-flash-image-preview') String routmyModel,
    @Default('1:1') String routmyAspectRatio,
    @Default('1K') String routmyImageSize,
    @Default('standard') String routmyQuality,
    @Default(false) bool routmySendCharAvatar,
    @Default(false) bool routmySendUserAvatar,
    @Default([]) List<ReferenceImage> additionalReferences,
    @Default([]) List<ReferenceImage> routmyAdditionalRefs,
    @Default(false) bool imageContextEnabled,
    @Default(1) int imageContextCount,
    @Default('') String ruRoutmyApiKey,
    @Default('google/gemini-3.1-flash-image-preview') String ruRoutmyModel,
    @Default('1:1') String ruRoutmyAspectRatio,
    @Default('1K') String ruRoutmyImageSize,
    @Default('standard') String ruRoutmyQuality,
    @Default(false) bool ruRoutmySendCharAvatar,
    @Default(false) bool ruRoutmySendUserAvatar,
  }) = _ImageGenSettings;
}

class RoutMyConstants {
  static const String baseUrl = 'https://api.rout.my';

  static const models = [
    ('google/gemini-3.1-flash-image-preview', 'Gemini 3.1 Flash Image'),
    ('google/gemini-3.1-flash-lite-image', 'Gemini 3.1 Flash Lite Image'),
    ('google/gemini-3-pro-image', 'Gemini 3 Pro Image'),
    ('google/gemini-omni-flash-preview', 'Gemini Omni Flash'),
    ('openai/gpt-image-1.5', 'GPT Image 1.5'),
    ('openai/gpt-image-2', 'GPT Image 2'),
    ('meta/muse-spark-1.1', 'Muse Spark 1.1'),
    ('bytedance/seedream-5.0-pro', 'Seedream 5.0 Pro'),
  ];

  // Models that generate images via /v1/chat/completions with modalities:[image,text].
  // openai/gpt-image-* are NOT here — rout.my rejects them on chat completions
  // ("not a language model"). They go through /v1/images/edits (with refs) or
  // /v1/images/generations (without refs).
  static const chatImageModels = {
    'google/gemini-3.1-flash-image-preview',
    'google/gemini-3.1-flash-lite-image',
    'google/gemini-3-pro-image',
    'google/gemini-omni-flash-preview',
  };

  static const aspectRatios = [
    '1:1',
    '2:3',
    '3:2',
    '3:4',
    '4:3',
    '4:5',
    '5:4',
    '9:16',
    '16:9',
    '21:9',
  ];

  static const imageSizes = ['1K', '2K', '4K'];
  static const seedreamImageSizes = ['1K', '2K'];
}

class RuRoutMyConstants {
  static const String baseUrl = 'https://ru-api.rout.my';

  static const models = RoutMyConstants.models;
  static const aspectRatios = RoutMyConstants.aspectRatios;
  static const imageSizes = RoutMyConstants.imageSizes;
}

class NaisteraConstants {
  static const models = [
    ('grok', 'Grok'),
    ('grok-pro', 'Grok Pro'),
    ('nano banana', 'Nano Banana'),
    ('novelai', 'NovelAI'),
  ];

  static const aspectRatios = ['1:1', '16:9', '9:16', '3:2', '2:3'];

  static const noRefModels = {'grok-pro', 'novelai'};
}

class OpenAIConstants {
  static const sizes = ['1024x1024', '1792x1024', '1024x1792', '512x512'];
  static const qualities = ['standard', 'hd'];
}

class GeminiConstants {
  static const aspectRatios = [
    '1:1',
    '9:16',
    '16:9',
    '3:4',
    '4:3',
    '2:3',
    '3:2',
  ];
  static const imageSizes = ['1K', '2K', '4K'];
}
