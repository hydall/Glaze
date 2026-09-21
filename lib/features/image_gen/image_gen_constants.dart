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
  ///
  /// An id that is not a known alias passes through untouched: since the
  /// catalog is loaded from `GET /api/models`, anything the API adds later
  /// must survive this, and rewriting it to `grok` would silently generate
  /// with the wrong model.
  static String normalizeModel(String? model) {
    final trimmed = (model ?? '').trim();
    if (trimmed.isEmpty) return 'grok';
    switch (trimmed.toLowerCase()) {
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
    // Case is preserved — a catalog id may well be case-sensitive.
    return trimmed;
  }

  static bool supportsReferences(String? model) =>
      !noRefModels.contains(normalizeModel(model));

  /// NovelAI models take the style as a plain prefix — the `[STYLE: ...]`
  /// wrapper reaches the sampler as literal tokens and poisons the image.
  static bool isNovelAIModel(String? model) => RegExp(
    r'^novelai(-|$)',
    caseSensitive: false,
  ).hasMatch((model ?? '').trim());
}

/// xAI Imagine (`https://api.x.ai`).
///
/// Ported from https://github.com/0xl0cal/sillyimages (`XAIProvider`):
/// `/v1/images/generations` without references, `/v1/images/edits` with them,
/// and a `quality` parameter only `grok-imagine-image-2.0` understands.
class XaiConstants {
  static const String defaultEndpoint = 'https://api.x.ai';

  /// Reference images accepted by one `/v1/images/edits` request.
  static const int maxReferences = 3;

  static const models = [
    ('grok-imagine-image-2.0', 'Grok Imagine Image 2.0'),
    ('grok-imagine-image', 'Grok Imagine Image'),
    ('grok-2-image', 'Grok 2 Image'),
  ];

  static const aspectRatios = [
    'auto',
    '1:1',
    '16:9',
    '9:16',
    '4:3',
    '3:4',
    '3:2',
    '2:3',
    '2:1',
    '1:2',
    '19.5:9',
    '9:19.5',
    '20:9',
    '9:20',
  ];

  static const resolutions = ['1k', '2k'];
  static const qualities = ['low', 'medium'];

  /// Only the Imagine image models round-trip reference images; `grok-2-image`
  /// is generation-only and 400s on `/v1/images/edits`.
  ///
  /// The upstream extension checks this too, but only to show or hide the
  /// reference rows — its collector still attaches references for every xAI
  /// model. Here the same predicate also drives [providerMaxReferences], so a
  /// generation-only model never reaches `/edits`.
  static bool supportsReferences(String? model) =>
      (model ?? '').toLowerCase().contains('grok-imagine-image');

  /// `quality` is rejected by every Imagine model except 2.0.
  static bool supportsQuality(String? model) =>
      (model ?? '').toLowerCase().contains('grok-imagine-image-2.0');

  static String normalizeAspectRatio(String? value) {
    final normalized = (value ?? '').trim();
    return aspectRatios.contains(normalized) ? normalized : '1:1';
  }

  static String normalizeResolution(String? value) =>
      (value ?? '').trim().toLowerCase() == '2k' ? '2k' : '1k';

  static String normalizeQuality(String? value) =>
      (value ?? '').trim().toLowerCase() == 'low' ? 'low' : 'medium';

  /// Strips a trailing `/v1` so the client can append its own paths.
  static String normalizeEndpoint(String? endpoint) {
    final trimmed = (endpoint ?? '').trim().replaceFirst(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return defaultEndpoint;
    return trimmed.replaceFirst(RegExp(r'/v1$', caseSensitive: false), '');
  }
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

/// NovelAI Image Generation (`POST {image base}/ai/generate-image`).
///
/// The image endpoints moved off `api.novelai.net`; the current base is
/// `https://image.novelai.net`, documented at
/// https://image.novelai.net/docs/index.html (spec at `docs/doc.json`).
/// Authentication is the NovelAI persistent token sent as `Authorization:
/// Bearer`. The response is a ZIP attachment holding the generated image(s)
/// (or JSON when `Accept: application/json` is sent). Every table below — model
/// ids, samplers, quality tags, undesired-content presets — mirrors the live
/// NovelAI web client, not a third-party wrapper.
class NovelAIConstants {
  static const String defaultEndpoint = 'https://image.novelai.net';

  static const String defaultModel = 'nai-diffusion-4-5-full';

  static const models = [
    ('nai-diffusion-5-full', 'NovelAI Diffusion V5 Full'),
    ('nai-diffusion-5-curated', 'NovelAI Diffusion V5 Curated'),
    ('nai-diffusion-4-5-full', 'NovelAI Diffusion V4.5 Full'),
    ('nai-diffusion-4-5-curated', 'NovelAI Diffusion V4.5 Curated'),
    ('nai-diffusion-4-full', 'NovelAI Diffusion V4 Full'),
    ('nai-diffusion-4-curated-preview', 'NovelAI Diffusion V4 Curated'),
    ('nai-diffusion-3', 'NovelAI Diffusion Anime V3'),
    ('nai-diffusion-furry-3', 'NovelAI Diffusion Furry V3'),
  ];

  static const samplers = [
    ('k_euler', 'Euler'),
    ('k_euler_ancestral', 'Euler Ancestral'),
    ('k_dpm_2', 'DPM2'),
    ('k_dpm_2_ancestral', 'DPM2 Ancestral'),
    ('k_dpmpp_2m', 'DPM++ 2M'),
    ('k_dpmpp_2s_ancestral', 'DPM++ 2S Ancestral'),
    ('k_dpmpp_sde', 'DPM++ SDE'),
    ('ddim', 'DDIM'),
  ];

  static const noiseSchedules = ['karras', 'exponential', 'polyexponential'];

  /// (label, width, height)
  static const resolutionPresets = [
    ('Portrait · 832x1216', 832, 1216),
    ('Landscape · 1216x832', 1216, 832),
    ('Square · 1024x1024', 1024, 1024),
    ('Large portrait · 1024x1536', 1024, 1536),
    ('Large landscape · 1536x1024', 1536, 1024),
  ];

  /// (id, label, wire index). The wire `ucPreset` is 0-3; the preset text is
  /// merged into `negative_prompt` by the client, matching the web UI. `none`
  /// is a UI-only choice: it sends index 0 but no preset text.
  static const ucPresets = [
    ('heavy', 'Heavy', 0),
    ('light', 'Light', 1),
    ('furry_focus', 'Furry Focus', 2),
    ('human_focus', 'Human Focus', 3),
  ];

  /// UI id for "no undesired-content preset".
  static const ucPresetNone = 'none';

  /// Quality-tag suffix appended to the positive prompt by `qualityToggle`.
  /// These are the exact strings the live web app's model table carries.
  static const _qualityTags = <String, String>{
    'nai-diffusion-5-full': 'very aesthetic, masterpiece, no text',
    'nai-diffusion-5-curated': 'very aesthetic, masterpiece, no text',
    'nai-diffusion-4-5-full': 'very aesthetic, masterpiece, no text',
    'nai-diffusion-4-5-curated':
        'very aesthetic, masterpiece, no text, -0.8::feet::, rating:general',
    'nai-diffusion-4-full': 'no text, best quality, very aesthetic, absurdres',
    'nai-diffusion-4-curated-preview':
        'rating:general, best quality, very aesthetic, absurdres',
    'nai-diffusion-3': 'best quality, amazing quality, very aesthetic, absurdres',
    'nai-diffusion-furry-3': '{best quality}, {amazing quality}',
  };

  /// Quality tags for the selected model; unknown ids get the V5 standard set.
  static String qualityTagsFor(String? model) =>
      _qualityTags[normalizeModel(model)] ??
      'very aesthetic, masterpiece, no text';

  /// Appends the quality tags as a suffix, comma-separated — the web UI's
  /// "Add Quality Tags" behaviour.
  static String applyQualityTags(String prompt, String? model) {
    final suffix = qualityTagsFor(model);
    final text = prompt.trim();
    if (suffix.isEmpty) return text;
    return text.isEmpty ? suffix : '$text, $suffix';
  }

  // Undesired-content preset text, per model — the exact strings the live web
  // app's preset table carries (they match https://docs.novelai.net/image/
  // undesiredcontent). The automatic `nsfw` guard is added by
  // [resolveNegativePrompt], not baked in here.
  static const Map<String, String> _ucV5 = {
    'heavy':
        'lowres, artistic error, film grain, scan artifacts, worst quality, '
        'bad quality, jpeg artifacts, very displeasing, chromatic aberration, '
        'dithering, halftone, screentone, multiple views, logo, too many '
        'watermarks, negative space, blank page',
    'light':
        'lowres, bad hands, bad anatomy, artistic error, sepia, white haze, '
        'worst quality, very displeasing, jpeg artifacts, 0::ai-generated::',
    'furry_focus':
        '{worst quality}, distracting watermark, unfinished, bad quality, '
        '{widescreen}, upscale, {sequence}, {{grandfathered content}}, blurred '
        'foreground, chromatic aberration, sketch, everyone, [sketch '
        'background], simple, [flat colors], ych (character), outline, multiple '
        'scenes, [[horror (theme)]], comic',
    'human_focus':
        'lowres, artistic error, film grain, scan artifacts, worst quality, '
        'bad quality, jpeg artifacts, very displeasing, chromatic aberration, '
        'dithering, halftone, screentone, multiple views, logo, too many '
        'watermarks, negative space, blank page, @_@, mismatched pupils, '
        'glowing eyes, bad anatomy',
  };

  static const Map<String, String> _ucV45Full = {
    'heavy':
        'lowres, artistic error, film grain, scan artifacts, worst quality, '
        'bad quality, jpeg artifacts, very displeasing, chromatic aberration, '
        'dithering, halftone, screentone, multiple views, logo, too many '
        'watermarks, negative space, blank page',
    'light':
        'lowres, artistic error, scan artifacts, worst quality, bad quality, '
        'jpeg artifacts, multiple views, very displeasing, too many watermarks, '
        'negative space, blank page',
    'furry_focus':
        '{worst quality}, distracting watermark, unfinished, bad quality, '
        '{widescreen}, upscale, {sequence}, {{grandfathered content}}, blurred '
        'foreground, chromatic aberration, sketch, everyone, [sketch '
        'background], simple, [flat colors], ych (character), outline, multiple '
        'scenes, [[horror (theme)]], comic',
    'human_focus':
        'lowres, artistic error, film grain, scan artifacts, worst quality, '
        'bad quality, jpeg artifacts, very displeasing, chromatic aberration, '
        'dithering, halftone, screentone, multiple views, logo, too many '
        'watermarks, negative space, blank page, @_@, mismatched pupils, '
        'glowing eyes, bad anatomy',
  };

  static const Map<String, String> _ucV45Curated = {
    'heavy':
        'blurry, lowres, upscaled, artistic error, film grain, scan artifacts, '
        'worst quality, bad quality, jpeg artifacts, very displeasing, '
        'chromatic aberration, halftone, multiple views, logo, too many '
        'watermarks, negative space, blank page',
    'light':
        'blurry, lowres, upscaled, artistic error, scan artifacts, jpeg '
        'artifacts, logo, too many watermarks, negative space, blank page',
    'human_focus':
        'blurry, lowres, upscaled, artistic error, film grain, scan artifacts, '
        'bad anatomy, bad hands, worst quality, bad quality, jpeg artifacts, '
        'very displeasing, chromatic aberration, halftone, multiple views, '
        'logo, too many watermarks, @_@, mismatched pupils, glowing eyes, '
        'negative space, blank page',
  };

  static const Map<String, String> _ucV4Full = {
    'heavy':
        'blurry, lowres, error, film grain, scan artifacts, worst quality, '
        'bad quality, jpeg artifacts, very displeasing, chromatic aberration, '
        'multiple views, logo, too many watermarks, white blank page, blank page',
    'light':
        'blurry, lowres, error, worst quality, bad quality, jpeg artifacts, '
        'very displeasing, white blank page, blank page',
  };

  static const Map<String, String> _ucV4Curated = {
    'heavy':
        'blurry, lowres, error, film grain, scan artifacts, worst quality, '
        'bad quality, jpeg artifacts, very displeasing, chromatic aberration, '
        'logo, dated, signature, multiple views, gigantic breasts, white blank '
        'page, blank page',
    'light':
        'blurry, lowres, error, worst quality, bad quality, jpeg artifacts, '
        'very displeasing, logo, dated, signature, white blank page, blank page',
  };

  static const Map<String, String> _ucV3 = {
    'heavy':
        'lowres, {bad}, error, fewer, extra, missing, worst quality, jpeg '
        'artifacts, bad quality, watermark, unfinished, displeasing, chromatic '
        'aberration, signature, extra digits, artistic error, username, scan, '
        '[abstract]',
    'light':
        'lowres, jpeg artifacts, worst quality, watermark, blurry, very '
        'displeasing',
    'human_focus':
        'lowres, {bad}, error, fewer, extra, missing, worst quality, jpeg '
        'artifacts, bad quality, watermark, unfinished, displeasing, chromatic '
        'aberration, signature, extra digits, artistic error, username, scan, '
        '[abstract], bad anatomy, bad hands, @_@, mismatched pupils, '
        'heart-shaped pupils, glowing eyes',
  };

  static const Map<String, String> _ucFurryV3 = {
    'heavy':
        '{{worst quality}}, [displeasing], {unusual pupils}, guide lines, '
        '{{unfinished}}, {bad}, url, artist name, {{tall image}}, mosaic, '
        '{sketch page}, comic panel, impact (font), [dated], {logo}, ych, '
        '{what}, {where is your god now}, {distorted text}, repeated text, '
        '{floating head}, {1994}, {widescreen}, absolutely everyone, sequence, '
        '{compression artifacts}, hard translated, {cropped}, {commissioner '
        'name}, unknown text, high contrast',
    'light':
        '{worst quality}, guide lines, unfinished, bad, url, tall image, '
        'widescreen, compression artifacts, unknown text',
  };

  static const _ucPresetText = <String, Map<String, String>>{
    'nai-diffusion-5-full': _ucV5,
    'nai-diffusion-5-curated': _ucV5,
    'nai-diffusion-4-5-full': _ucV45Full,
    'nai-diffusion-4-5-curated': _ucV45Curated,
    'nai-diffusion-4-full': _ucV4Full,
    'nai-diffusion-4-curated-preview': _ucV4Curated,
    'nai-diffusion-3': _ucV3,
    'nai-diffusion-furry-3': _ucFurryV3,
  };

  /// Preset text for a model and UI preset id, or an empty string when the
  /// model has no such preset (or `none` is selected).
  static String ucPresetText(String? model, String? id) {
    final key = (id ?? '').trim();
    if (key.isEmpty || key == ucPresetNone) return '';
    return _ucPresetText[normalizeModel(model)]?[key] ?? '';
  }

  /// The final negative prompt, following the web UI: the selected preset is
  /// prepended to the user's own text, and non-curated models also get an
  /// `nsfw, ` guard unless the user already wrote it.
  static String resolveNegativePrompt({
    required String? model,
    required String presetId,
    required String userNegative,
  }) {
    final preset = ucPresetText(model, presetId);
    final user = userNegative.trim();
    var result = preset;
    if (user.isNotEmpty) {
      result = preset.isEmpty ? user : '$preset, $user';
    }
    if (preset.isNotEmpty &&
        !_skipsNsfwGuard(model) &&
        !user.toLowerCase().contains('nsfw')) {
      result = 'nsfw, $result';
    }
    return result;
  }

  /// Curated (and safe/custom) models never receive the automatic `nsfw` guard.
  static bool _skipsNsfwGuard(String? model) =>
      normalizeModel(model).toLowerCase().contains('curated');

  /// Character Reference (Director Tools) images accepted per request. The
  /// feature exists only on the V4.5 family.
  static const int maxReferences = 4;

  /// Maps a per-tag aspect ratio onto a preset resolution, or null when the
  /// ratio has no equivalent — the configured resolution is then used.
  static (int, int)? sizeForAspect(String? aspect) {
    switch ((aspect ?? '').trim()) {
      case '1:1':
        return (1024, 1024);
      case '3:4':
      case '2:3':
      case '9:16':
      case '1:2':
      case '10:24':
        return (832, 1216);
      case '4:3':
      case '3:2':
      case '16:9':
      case '2:1':
      case '24:10':
        return (1216, 832);
      default:
        return null;
    }
  }

  static String normalizeModel(String? model) {
    final trimmed = (model ?? '').trim();
    return trimmed.isEmpty ? defaultModel : trimmed;
  }

  static String normalizeEndpoint(String? endpoint) {
    final trimmed = (endpoint ?? '').trim().replaceFirst(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? defaultEndpoint : trimmed;
  }

  /// V4 / V4.5 / V5 models take the structured `v4_prompt` instead of a plain
  /// `prompt` field.
  static bool isV4(String? model) {
    final id = normalizeModel(model).toLowerCase();
    return id.contains('nai-diffusion-4') || id.contains('nai-diffusion-5');
  }

  static bool isV5(String? model) =>
      normalizeModel(model).toLowerCase().contains('nai-diffusion-5');

  /// Director Tools character references are V4.5 only.
  static bool supportsReferences(String? model) =>
      normalizeModel(model).toLowerCase().contains('nai-diffusion-4-5');

  /// Integer sent as `ucPreset`; unknown ids fall back to `light`.
  static int ucPresetIndex(String? id) {
    final key = (id ?? '').trim();
    for (final (presetId, _, index) in ucPresets) {
      if (presetId == key) return index;
    }
    // `none` and unknown ids send 0, the value the web UI uses when no preset
    // is chosen. The actual text is driven by the merged negative prompt.
    return 0;
  }
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
