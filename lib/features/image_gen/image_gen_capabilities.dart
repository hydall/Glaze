/// Model classification and per-model capability tables.
///
/// Ported from https://github.com/0xl0cal/sillyimages (`src/providers.js`):
/// which models accept reference images, how many, which `aspect_ratio` /
/// `image_size` values they understand, and how `quality` has to be spelled.
library;

import 'image_gen_models.dart';

/// Capabilities of one image model.
class ImageModelCaps {
  const ImageModelCaps({
    required this.maxReferences,
    required this.imageSizes,
    required this.aspectRatios,
  });

  final int maxReferences;

  /// `null` — the model does not accept an image-size parameter, so it must
  /// not be sent (Gemini 2.5 Flash Image, FLUX via OpenRouter).
  final List<String>? imageSizes;
  final List<String> aspectRatios;
}

// ───────────────────────── Gemini ─────────────────────────

/// `gemini-3.1-flash-image` | `gemini-3-pro-image` | `gemini-2.5-flash-image`
/// | `unknown` (proxy alias with a custom id — optimistic defaults).
String classifyGeminiImageModel(String? modelId) {
  final id = (modelId ?? '').toLowerCase().trim();
  if (id.isEmpty) return 'unknown';

  if (id.startsWith('gemini-3.1-flash-image')) return 'gemini-3.1-flash-image';
  if (id.startsWith('gemini-3-pro-image')) return 'gemini-3-pro-image';
  if (id.startsWith('gemini-2.5-flash-image')) return 'gemini-2.5-flash-image';

  // Proxy aliases, most specific first.
  if (id.contains('nano-banana-2') || id.contains('nano banana 2')) {
    return 'gemini-3.1-flash-image';
  }
  if (id.contains('nano-banana-pro') || id.contains('nano banana pro')) {
    return 'gemini-3-pro-image';
  }
  if (id.contains('nano-banana') || id.contains('nano banana')) {
    return 'gemini-2.5-flash-image';
  }
  return 'unknown';
}

const _geminiCaps = <String, ImageModelCaps>{
  'gemini-3.1-flash-image': ImageModelCaps(
    maxReferences: 14,
    imageSizes: ['512', '1K', '2K', '4K'],
    aspectRatios: [
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
      '1:4',
      '4:1',
      '1:8',
      '8:1',
    ],
  ),
  'gemini-3-pro-image': ImageModelCaps(
    maxReferences: 11,
    imageSizes: ['1K', '2K', '4K'],
    aspectRatios: [
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
    ],
  ),
  'gemini-2.5-flash-image': ImageModelCaps(
    maxReferences: 3,
    // The model rejects imageSize — never send it.
    imageSizes: null,
    aspectRatios: [
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
    ],
  ),
  'unknown': ImageModelCaps(
    maxReferences: maxGenerationReferenceImages,
    imageSizes: GeminiConstants.imageSizes,
    aspectRatios: GeminiConstants.aspectRatios,
  ),
};

ImageModelCaps geminiCapabilities(String? modelId) =>
    _geminiCaps[classifyGeminiImageModel(modelId)] ?? _geminiCaps['unknown']!;

// ───────────────────────── OpenAI-compatible ─────────────────────────

/// `gpt-image-1.5` | `gpt-image-1-mini` | `gpt-image-1` | `gpt-image`
/// | `flux-kontext` | `dall-e-3` | `dall-e-2` | `unknown`.
String classifyOpenAiImageModel(String? modelId) {
  final id = (modelId ?? '').toLowerCase().trim();
  if (id.contains('gpt-image-1.5') || id.contains('gpt-image-1-5')) {
    return 'gpt-image-1.5';
  }
  if (id.contains('gpt-image-1-mini')) return 'gpt-image-1-mini';
  if (id.contains('gpt-image-1')) return 'gpt-image-1';
  if (id.contains('gpt-image')) return 'gpt-image';
  if (id.contains('flux-1-kontext') || id.contains('flux-kontext')) {
    return 'flux-kontext';
  }
  if (id.contains('dall-e-3')) return 'dall-e-3';
  if (id.contains('dall-e-2')) return 'dall-e-2';
  return 'unknown';
}

/// The gpt-image family supports multi-image `/v1/images/edits` via `image[]`.
bool isGptImageFamily(String kind) =>
    kind == 'gpt-image-1.5' ||
    kind == 'gpt-image-1-mini' ||
    kind == 'gpt-image-1' ||
    kind == 'gpt-image';

/// References accepted by `/v1/images/edits` for a model family.
/// dall-e-3 / unknown never route through /edits.
int openAiMaxReferences(String kind) {
  if (isGptImageFamily(kind)) return maxGenerationReferenceImages;
  if (kind == 'flux-kontext') return 1;
  if (kind == 'dall-e-2') return 1;
  return 0;
}

/// Maps an aspect ratio to the `size` string a model family understands.
/// Returns null when the family has no mapping — the caller falls back to the
/// configured size.
String? openAiAspectRatioToSize(String? aspect, String kind) {
  final value = (aspect ?? '').trim();
  if (value.isEmpty) return null;

  if (isGptImageFamily(kind)) {
    return const {
      '1:1': '1024x1024',
      '16:9': '1536x1024',
      '9:16': '1024x1536',
      '3:2': '1536x1024',
      '2:3': '1024x1536',
      '4:3': '1536x1024',
      '3:4': '1024x1536',
    }[value];
  }
  if (kind == 'dall-e-3') {
    return const {
      '1:1': '1024x1024',
      '16:9': '1792x1024',
      '9:16': '1024x1792',
    }[value];
  }
  if (kind == 'dall-e-2') return '1024x1024';
  return null;
}

/// Normalizes the UI quality value for a model family. Returns null when the
/// parameter is not supported and must be omitted.
String? normalizeOpenAiQuality(String? userQuality, String kind) {
  final q = (userQuality ?? '').toLowerCase().trim();

  if (isGptImageFamily(kind)) {
    if (const {'low', 'medium', 'high', 'auto'}.contains(q)) return q;
    if (q == 'hd') return 'high';
    if (q == 'standard') return 'medium';
    return 'auto';
  }
  if (kind == 'dall-e-3') {
    return const {'standard', 'hd'}.contains(q) ? q : 'standard';
  }
  if (kind == 'dall-e-2') return 'standard';
  return q.isEmpty ? null : q;
}

// ───────────────────────── OpenRouter ─────────────────────────

/// Gemini kinds are delegated to [geminiCapabilities]; everything else gets
/// generic capabilities (aspect ratio allowed, no image size).
String classifyOpenRouterImageModel(String? modelId) {
  final id = (modelId ?? '').toLowerCase().trim();
  if (id.isEmpty) return 'unknown';

  if (id.startsWith('google/')) {
    final kind = classifyGeminiImageModel(id.substring('google/'.length));
    if (kind != 'unknown') return kind;
  }
  if (id.startsWith('black-forest-labs/')) return 'flux';
  if (id.startsWith('sourceful/')) return 'sourceful';
  return 'unknown';
}

bool isGeminiOpenRouterModel(String? modelId) {
  final kind = classifyOpenRouterImageModel(modelId);
  return kind.startsWith('gemini-');
}

ImageModelCaps openRouterCapabilities(String? modelId) {
  final kind = classifyOpenRouterImageModel(modelId);
  if (kind.startsWith('gemini-')) return _geminiCaps[kind]!;
  return const ImageModelCaps(
    maxReferences: maxGenerationReferenceImages,
    imageSizes: null,
    aspectRatios: OpenRouterConstants.aspectRatios,
  );
}

// ───────────────────────── Active provider ─────────────────────────

/// How many reference images the active provider/model accepts per request.
/// 0 — references are unsupported and the UI hides the reference sections.
int providerMaxReferences(ImageGenSettings settings) {
  switch (settings.apiType) {
    case ImageGenApiType.openai:
      return openAiMaxReferences(
        classifyOpenAiImageModel(settings.customModel),
      );
    case ImageGenApiType.electronhub:
      return openAiMaxReferences(
        classifyOpenAiImageModel(settings.electronhub.model),
      );
    case ImageGenApiType.gemini:
      return geminiCapabilities(settings.customModel).maxReferences;
    case ImageGenApiType.openrouter:
      return openRouterCapabilities(settings.openrouter.model).maxReferences;
    case ImageGenApiType.naistera:
      return NaisteraConstants.supportsReferences(settings.naisteraModel)
          ? maxGenerationReferenceImages
          : 0;
    case ImageGenApiType.routmy:
    case ImageGenApiType.ruRoutmy:
      return routmyMaxInjectedReferenceImages;
    case ImageGenApiType.a1111:
      // txt2img only.
      return 0;
  }
}
