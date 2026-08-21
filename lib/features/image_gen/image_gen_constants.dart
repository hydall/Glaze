/// Provider-specific constant tables for image generation.
///
/// Kept out of `image_gen_models.dart` (which re-exports this file) so the
/// freezed model stays readable while the provider catalog grows.
///
/// The OpenRouter / Electron Hub / AUTOMATIC1111 tables are ported from
/// https://github.com/0xl0cal/sillyimages (`src/providers.js`, `src/settings.js`).
library;

const routmyMaxInjectedReferenceImages = 10;

/// Upper bound on how many reference images any provider is asked to accept in
/// a single request. Providers narrow it further via their capability tables.
const maxGenerationReferenceImages = 10;

/// Default critical instruction prefixed to a prompt whenever at least one
/// reference image is sent. Editable and switchable off in settings.
const defaultReferenceInstruction =
    '[CRITICAL: The reference image(s) above show the EXACT appearance of the '
    'character(s). You MUST precisely copy their: face structure, eye color, '
    'hair color and style, skin tone, body type, clothing, and all distinctive '
    'features. Do not deviate from the reference appearances.]';

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
  /// Base of the public API. The generation route is `/api/generate`; the
  /// legacy `/prompt/api/img` route answers 405 Method Not Allowed.
  static const String baseUrl = 'https://naistera.org';

  static const models = [
    ('grok', 'Grok'),
    ('grok-pro', 'Grok Pro'),
    ('nano banana 2', 'Nano Banana 2'),
    ('novelai', 'NovelAI'),
  ];

  static const aspectRatios = ['1:1', '16:9', '9:16', '3:2', '2:3'];

  static const noRefModels = {'grok-pro', 'novelai'};

  /// Maps stored and retired model labels onto the ids the API accepts today,
  /// so a settings blob written by an older build keeps generating.
  static String normalizeModel(String? model) {
    final raw = (model ?? '').trim().toLowerCase();
    if (raw.isEmpty) return 'grok';
    switch (raw) {
      case 'grok pro':
      case 'grok-pro':
      case 'grok-imagine-pro':
      case 'imagine-pro':
        return 'grok-pro';
      case 'nano-banana':
      case 'nano banana':
      case 'nano banana pro':
      case 'nano-banana-pro':
      case 'nano-banana-2':
      case 'nano banana 2':
        return 'nano banana 2';
      case 'novel ai':
      case 'novelai':
        return 'novelai';
    }
    return models.any((m) => m.$1 == raw) ? raw : 'grok';
  }

  static bool supportsReferences(String? model) =>
      !noRefModels.contains(normalizeModel(model));
}

class OpenAIConstants {
  static const sizes = ['1024x1024', '1792x1024', '1024x1792', '512x512'];
  static const qualities = ['standard', 'hd'];

  /// Aspect ratios offered in the UI; mapped to a concrete `size` per model
  /// family by [openAiAspectRatioToSize].
  static const aspectRatios = [
    '1:1',
    '16:9',
    '9:16',
    '3:2',
    '2:3',
    '4:3',
    '3:4',
  ];
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

class OpenRouterConstants {
  static const String defaultEndpoint = 'https://openrouter.ai/api/v1';

  /// Shortlist shown in the model picker. Any other id can be typed in.
  static const models = [
    ('google/gemini-3.1-flash-image-preview', 'Gemini 3.1 Flash Image'),
    ('google/gemini-3-pro-image-preview', 'Gemini 3 Pro Image'),
    ('google/gemini-2.5-flash-image', 'Gemini 2.5 Flash Image'),
    ('black-forest-labs/flux-1.1-pro', 'FLUX 1.1 Pro'),
    ('black-forest-labs/flux-kontext-max', 'FLUX Kontext Max'),
  ];

  /// Presets OpenRouter maps to concrete sizes on their side. The extra
  /// 1:4 / 4:1 / 1:8 / 8:1 ratios are Gemini 3.1 Flash only.
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
}

class ElectronHubConstants {
  static const String defaultEndpoint = 'https://api.electronhub.ai';

  static const models = [
    ('gpt-image-1.5', 'GPT Image 1.5'),
    ('gpt-image-1', 'GPT Image 1'),
    ('gpt-image-1-mini', 'GPT Image 1 Mini'),
    ('flux-1-kontext-pro', 'FLUX.1 Kontext Pro'),
    ('flux-1-kontext-max', 'FLUX.1 Kontext Max'),
    ('dall-e-3', 'DALL·E 3'),
  ];

  static const sizes = OpenAIConstants.sizes;
  static const qualities = OpenAIConstants.qualities;
  static const aspectRatios = OpenAIConstants.aspectRatios;
}

/// AUTOMATIC1111 / Forge / reForge (`/sdapi/v1/txt2img`).
class A1111Constants {
  static const String defaultEndpoint = 'http://127.0.0.1:7860';

  static const samplers = [
    'Euler a',
    'Euler',
    'LMS',
    'Heun',
    'DPM2',
    'DPM2 a',
    'DPM++ 2S a',
    'DPM++ 2M',
    'DPM++ SDE',
    'DPM++ 2M SDE',
    'DDIM',
    'PLMS',
    'UniPC',
    'LCM',
    'Restart',
  ];

  static const schedulers = [
    'Automatic',
    'Karras',
    'Exponential',
    'SGM Uniform',
    'Simple',
    'Normal',
    'DDIM',
    'Beta',
  ];

  /// (id, width, height, label)
  static const resolutionPresets = [
    ('512x512', 512, 512, '512x512 (1:1, SD 1.5)'),
    ('768x512', 768, 512, '768x512 (3:2, SD 1.5)'),
    ('512x768', 512, 768, '512x768 (2:3, SD 1.5)'),
    ('960x540', 960, 540, '960x540 (16:9)'),
    ('540x960', 540, 960, '540x960 (9:16)'),
    ('1024x1024', 1024, 1024, '1024x1024 (1:1, SDXL)'),
    ('1152x896', 1152, 896, '1152x896 (9:7, SDXL)'),
    ('896x1152', 896, 1152, '896x1152 (7:9, SDXL)'),
    ('1216x832', 1216, 832, '1216x832 (19:13, SDXL)'),
    ('832x1216', 832, 1216, '832x1216 (13:19, SDXL)'),
    ('1344x768', 1344, 768, '1344x768 (4:3, SDXL)'),
    ('768x1344', 768, 1344, '768x1344 (3:4, SDXL)'),
    ('1536x640', 1536, 640, '1536x640 (24:10, SDXL)'),
    ('640x1536', 640, 1536, '640x1536 (10:24, SDXL)'),
    ('1920x1088', 1920, 1088, '1920x1088 (16:9, 1080p)'),
    ('1088x1920', 1088, 1920, '1088x1920 (9:16, 1080p)'),
  ];
}
