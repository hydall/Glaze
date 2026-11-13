import 'image_gen_models.dart';

/// JSON (de)serialization for [ImageGenSettings].
///
/// Also carries the migration off the pre-overhaul shape, where reference
/// images and avatar toggles were duplicated per provider
/// (`additionalReferences` for Naistera, `routmyAdditionalRefs` for rout.my,
/// `naisteraSendCharAvatar` / `routmySendCharAvatar` / `ruRoutmySendCharAvatar`).
/// Both lists are merged into one shared library and the avatar flags are
/// OR-ed, matching the single reference library of the upstream extension.
///
/// The retired RU mirror (`apiType == 'ruRoutmy'`) is folded into the single
/// [ImageGenApiType.routmy] provider: its model parameters are carried over
/// when the current rout.my fields are empty.
class ImageGenSettingsCodec {
  const ImageGenSettingsCodec._();

  static Map<String, dynamic> toJson(ImageGenSettings s) => {
    'enabled': s.enabled,
    'concurrentGeneration': s.concurrentGeneration,
    'apiType': s.apiType.name,
    'useSameEndpoint': s.useSameEndpoint,
    'customEndpoint': s.customEndpoint,
    'customApiKey': s.customApiKey,
    'customModel': s.customModel,
    'openaiSize': s.openaiSize,
    'openaiQuality': s.openaiQuality,
    'openaiCustomWidth': s.openaiCustomWidth,
    'openaiCustomHeight': s.openaiCustomHeight,
    'geminiAspectRatio': s.geminiAspectRatio,
    'geminiImageSize': s.geminiImageSize,
    'geminiCustomWidth': s.geminiCustomWidth,
    'geminiCustomHeight': s.geminiCustomHeight,
    'naisteraApiKey': s.naisteraApiKey,
    'naisteraModel': s.naisteraModel,
    'naisteraAspectRatio': s.naisteraAspectRatio,
    'naisteraNegativePrompt': s.naisteraNegativePrompt,
    'naisteraModels': s.naisteraModels.map(_naisteraModelToJson).toList(),
    'naisteraCharacterDescriptionsMode':
        s.naisteraCharacterDescriptionsMode.name,
    'routmyApiKey': s.routmyApiKey,
    'routmyModel': s.routmyModel,
    'routmyAspectRatio': s.routmyAspectRatio,
    'routmyImageSize': s.routmyImageSize,
    'routmyCustomWidth': s.routmyCustomWidth,
    'routmyCustomHeight': s.routmyCustomHeight,
    'routmyQuality': s.routmyQuality,
    'routmyMirror': s.routmyMirror.name,
    'routmyModels': s.routmyModels.map(_routmyModelToJson).toList(),
    'xai': _xaiToJson(s.xai),
    'openrouter': _openRouterToJson(s.openrouter),
    'electronhub': _electronHubToJson(s.electronhub),
    'a1111': _a1111ToJson(s.a1111),
    'novelai': _novelAiToJson(s.novelai),
    'comfyui': _comfyUiToJson(s.comfyui),
    'tensorart': _tensorArtToJson(s.tensorart),
    'sendCharAvatar': s.sendCharAvatar,
    'charAppearanceSource': s.charAppearanceSource.name,
    'sendUserAvatar': s.sendUserAvatar,
    'references': s.references.map(_refToJson).toList(),
    'sendRefDescriptions': s.sendRefDescriptions,
    'refInstructionEnabled': s.refInstructionEnabled,
    'refInstruction': s.refInstruction,
    'imageContextEnabled': s.imageContextEnabled,
    'imageContextCount': s.imageContextCount,
    'styles': s.styles.map(styleToJson).toList(),
    'activeStyleId': s.activeStyleId,
  };

  static ImageGenSettings fromJson(Map<String, dynamic> m) => ImageGenSettings(
    enabled: castBool(m['enabled'], false),
    concurrentGeneration: castBool(m['concurrentGeneration'], false),
    apiType: parseApiType(m['apiType'] as String?),
    useSameEndpoint: castBool(m['useSameEndpoint'], true),
    customEndpoint: m['customEndpoint'] as String? ?? '',
    customApiKey: m['customApiKey'] as String? ?? '',
    customModel: m['customModel'] as String? ?? '',
    openaiSize: m['openaiSize'] as String? ?? '1024x1024',
    openaiQuality: m['openaiQuality'] as String? ?? 'standard',
    openaiCustomWidth: castInt(m['openaiCustomWidth'], 1024),
    openaiCustomHeight: castInt(m['openaiCustomHeight'], 1024),
    geminiAspectRatio: m['geminiAspectRatio'] as String? ?? '1:1',
    geminiImageSize: m['geminiImageSize'] as String? ?? '1K',
    geminiCustomWidth: castInt(m['geminiCustomWidth'], 1024),
    geminiCustomHeight: castInt(m['geminiCustomHeight'], 1024),
    naisteraApiKey: m['naisteraApiKey'] as String? ?? '',
    naisteraModel:
        m['naisteraModel'] as String? ?? NaisteraConstants.defaultModel,
    naisteraAspectRatio: m['naisteraAspectRatio'] as String? ?? '1:1',
    naisteraNegativePrompt: m['naisteraNegativePrompt'] as String? ?? '',
    naisteraModels: _naisteraModelsFromJson(m['naisteraModels']),
    naisteraCharacterDescriptionsMode: _descriptionsMode(
      m['naisteraCharacterDescriptionsMode'],
      // The pre-mode build carried a plain on/off switch.
      legacyEnabled: m['naisteraSendCharacterDescriptions'],
    ),
    routmyApiKey: _routmyLegacy(m, 'routmyApiKey', 'ruRoutmyApiKey', ''),
    routmyModel: _routmyLegacy(
      m,
      'routmyModel',
      'ruRoutmyModel',
      'google/gemini-3.1-flash-image-preview',
    ),
    routmyAspectRatio: _routmyLegacy(
      m,
      'routmyAspectRatio',
      'ruRoutmyAspectRatio',
      '1:1',
    ),
    routmyImageSize: _routmyLegacy(
      m,
      'routmyImageSize',
      'ruRoutmyImageSize',
      '1K',
    ),
    routmyCustomWidth: castInt(m['routmyCustomWidth'], 1024),
    routmyCustomHeight: castInt(m['routmyCustomHeight'], 1024),
    routmyQuality: _routmyLegacy(
      m,
      'routmyQuality',
      'ruRoutmyQuality',
      'standard',
    ),
    routmyMirror: _routmyMirror(m['routmyMirror'], m['apiType']),
    routmyModels: _routmyModelsFromJson(m['routmyModels']),
    xai: _xaiFromJson(m['xai']),
    openrouter: _openRouterFromJson(m['openrouter']),
    electronhub: _electronHubFromJson(m['electronhub']),
    a1111: _a1111FromJson(m['a1111']),
    novelai: _novelAiFromJson(m['novelai']),
    comfyui: _comfyUiFromJson(m['comfyui']),
    tensorart: _tensorArtFromJson(m['tensorart']),
    sendCharAvatar: _legacyAvatarFlag(m, 'sendCharAvatar', const [
      'naisteraSendCharAvatar',
      'routmySendCharAvatar',
      'ruRoutmySendCharAvatar',
    ]),
    charAppearanceSource: _charAppearanceSource(m['charAppearanceSource']),
    sendUserAvatar: _legacyAvatarFlag(m, 'sendUserAvatar', const [
      'naisteraSendUserAvatar',
      'routmySendUserAvatar',
      'ruRoutmySendUserAvatar',
    ]),
    references: _mergedReferences(m),
    sendRefDescriptions: castBool(m['sendRefDescriptions'], true),
    refInstructionEnabled: castBool(m['refInstructionEnabled'], true),
    refInstruction: m['refInstruction'] as String? ?? '',
    imageContextEnabled: castBool(m['imageContextEnabled'], false),
    imageContextCount: castInt(m['imageContextCount'], 1),
    styles: parseStyles(m['styles']),
    activeStyleId: m['activeStyleId'] as String? ?? '',
  );

  // ─── Reference library ───────────────────────────────────────────────────

  static Map<String, dynamic> _refToJson(ReferenceImage r) => {
    'name': r.name,
    'imageData': r.imageData,
    'matchMode': r.matchMode,
    'description': r.description,
    'enabled': r.enabled,
  };

  static ReferenceImage refFromJson(Map<String, dynamic> m) => ReferenceImage(
    name: m['name'] as String? ?? '',
    imageData: m['imageData'] as String? ?? '',
    matchMode: m['matchMode'] as String? ?? 'match',
    description: m['description'] as String? ?? '',
    enabled: castBool(m['enabled'], true),
  );

  static List<ReferenceImage> parseRefs(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map<Object?, Object?>>()
        .map((e) => refFromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// New shared list when present, otherwise the two legacy per-provider
  /// lists merged and de-duplicated on (name, imageData).
  static List<ReferenceImage> _mergedReferences(Map<String, dynamic> m) {
    if (m.containsKey('references')) return parseRefs(m['references']);

    final merged = <ReferenceImage>[];
    final seen = <String>{};
    for (final legacyKey in const [
      'additionalReferences',
      'routmyAdditionalRefs',
    ]) {
      for (final ref in parseRefs(m[legacyKey])) {
        final key = '${ref.name} ${ref.imageData}';
        if (!seen.add(key)) continue;
        merged.add(ref);
      }
    }
    return merged;
  }

  static bool _legacyAvatarFlag(
    Map<String, dynamic> m,
    String key,
    List<String> legacyKeys,
  ) {
    if (m.containsKey(key)) return castBool(m[key], false);
    return legacyKeys.any((legacy) => castBool(m[legacy], false));
  }

  /// Current rout.my field, or — for a settings blob written while the
  /// retired RU mirror existed (`apiType == 'ruRoutmy'`) — the matching
  /// `ruRoutmy*` field, so the merged provider keeps the RU configuration.
  static String _routmyLegacy(
    Map<String, dynamic> m,
    String key,
    String legacyKey,
    String fallback,
  ) {
    final value = m[key] as String?;
    if (value != null && value.isNotEmpty) return value;
    if ((m['apiType'] as String?) == 'ruRoutmy') {
      final legacy = m[legacyKey] as String?;
      if (legacy != null && legacy.isNotEmpty) return legacy;
    }
    return fallback;
  }

  /// The stored mirror, or — for a settings blob written while the RU mirror
  /// was a separate provider (`apiType == 'ruRoutmy'`) — the RU host.
  static RoutMyMirror _routmyMirror(dynamic value, dynamic legacyApiType) {
    for (final mirror in RoutMyMirror.values) {
      if (mirror.name == value) return mirror;
    }
    return legacyApiType == 'ruRoutmy' ? RoutMyMirror.ru : RoutMyMirror.global;
  }

  // ─── Styles ──────────────────────────────────────────────────────────────

  static Map<String, dynamic> styleToJson(ImageStyle s) => {
    'id': s.id,
    'name': s.name,
    'value': s.value,
    'negativePrompt': s.negativePrompt,
  };

  static List<ImageStyle> parseStyles(dynamic value) {
    if (value is! List) return const [];
    final styles = <ImageStyle>[];
    for (var i = 0; i < value.length; i++) {
      final raw = value[i];
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final id = (map['id'] as String? ?? '').trim();
      styles.add(
        ImageStyle(
          id: id.isEmpty
              ? 'style-${DateTime.now().microsecondsSinceEpoch}-$i'
              : id,
          name: (map['name'] as String? ?? '').trim().isEmpty
              ? 'Style ${i + 1}'
              : (map['name'] as String).trim(),
          value: (map['value'] as String? ?? '').trim(),
          negativePrompt: (map['negativePrompt'] as String? ?? '').trim(),
        ),
      );
    }
    return styles;
  }

  // ─── Provider sub-settings ───────────────────────────────────────────────

  static Map<String, dynamic> _xaiToJson(XaiImageSettings s) => {
    'apiKey': s.apiKey,
    'endpoint': s.endpoint,
    'model': s.model,
    'aspectRatio': s.aspectRatio,
    'resolution': s.resolution,
    'quality': s.quality,
    'customWidth': s.customWidth,
    'customHeight': s.customHeight,
  };

  static XaiImageSettings _xaiFromJson(dynamic value) {
    if (value is! Map) return const XaiImageSettings();
    final m = Map<String, dynamic>.from(value);
    return XaiImageSettings(
      apiKey: m['apiKey'] as String? ?? '',
      endpoint: m['endpoint'] as String? ?? '',
      model: m['model'] as String? ?? 'grok-imagine-image-2.0',
      aspectRatio: m['aspectRatio'] as String? ?? '1:1',
      resolution: m['resolution'] as String? ?? '1k',
      quality: m['quality'] as String? ?? 'medium',
      customWidth: castInt(m['customWidth'], 1024),
      customHeight: castInt(m['customHeight'], 1024),
    );
  }

  // ─── rout.my catalog ─────────────────────────────────────────────────────

  static Map<String, dynamic> _routmyModelToJson(RoutmyModelInfo m) => {
    'id': m.id,
    'name': m.name,
    'supportsEdits': m.supportsEdits,
  };

  static List<RoutmyModelInfo> _routmyModelsFromJson(dynamic value) {
    if (value is! List) return const [];
    final models = <RoutmyModelInfo>[];
    for (final raw in value) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final id = (m['id'] as String? ?? '').trim();
      if (id.isEmpty) continue;
      models.add(
        RoutmyModelInfo(
          id: id,
          name: m['name'] as String? ?? '',
          supportsEdits: castBool(m['supportsEdits'], false),
        ),
      );
    }
    return models;
  }

  // ─── Naistera catalog ────────────────────────────────────────────────────

  static Map<String, dynamic> _naisteraModelToJson(NaisteraModelInfo m) => {
    'id': m.id,
    'name': m.name,
    'references': m.references,
    'negativePrompt': m.negativePrompt,
  };

  static List<NaisteraModelInfo> _naisteraModelsFromJson(dynamic value) {
    if (value is! List) return const [];
    final models = <NaisteraModelInfo>[];
    for (final raw in value) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final id = (m['id'] as String? ?? '').trim();
      if (id.isEmpty) continue;
      models.add(
        NaisteraModelInfo(
          id: id,
          name: m['name'] as String? ?? '',
          references: castBool(m['references'], true),
          negativePrompt: castBool(m['negativePrompt'], false),
        ),
      );
    }
    return models;
  }

  /// The stored character-appearance source, defaulting to the avatar image.
  static CharacterAppearanceSource _charAppearanceSource(dynamic value) {
    for (final source in CharacterAppearanceSource.values) {
      if (source.name == value) return source;
    }
    return CharacterAppearanceSource.image;
  }

  /// The stored mode, or — for a settings blob written before the modes
  /// existed — the on/off switch it replaced.
  static CharacterDescriptionsMode _descriptionsMode(
    dynamic value, {
    dynamic legacyEnabled,
  }) {
    for (final mode in CharacterDescriptionsMode.values) {
      if (mode.name == value) return mode;
    }
    if (legacyEnabled != null && !castBool(legacyEnabled, true)) {
      return CharacterDescriptionsMode.none;
    }
    return CharacterDescriptionsMode.asIs;
  }

  static Map<String, dynamic> _openRouterToJson(OpenRouterImageSettings s) => {
    'apiKey': s.apiKey,
    'endpoint': s.endpoint,
    'model': s.model,
    'aspectRatio': s.aspectRatio,
    'imageSize': s.imageSize,
    'customWidth': s.customWidth,
    'customHeight': s.customHeight,
  };

  static OpenRouterImageSettings _openRouterFromJson(dynamic value) {
    if (value is! Map) return const OpenRouterImageSettings();
    final m = Map<String, dynamic>.from(value);
    return OpenRouterImageSettings(
      apiKey: m['apiKey'] as String? ?? '',
      endpoint: m['endpoint'] as String? ?? '',
      model: m['model'] as String? ?? 'google/gemini-2.5-flash-image',
      aspectRatio: m['aspectRatio'] as String? ?? '1:1',
      imageSize: m['imageSize'] as String? ?? '1K',
      customWidth: castInt(m['customWidth'], 1024),
      customHeight: castInt(m['customHeight'], 1024),
    );
  }

  static Map<String, dynamic> _electronHubToJson(ElectronHubImageSettings s) =>
      {
        'apiKey': s.apiKey,
        'endpoint': s.endpoint,
        'model': s.model,
        'size': s.size,
        'quality': s.quality,
        'customWidth': s.customWidth,
        'customHeight': s.customHeight,
      };

  static ElectronHubImageSettings _electronHubFromJson(dynamic value) {
    if (value is! Map) return const ElectronHubImageSettings();
    final m = Map<String, dynamic>.from(value);
    return ElectronHubImageSettings(
      apiKey: m['apiKey'] as String? ?? '',
      endpoint: m['endpoint'] as String? ?? '',
      model: m['model'] as String? ?? 'gpt-image-1',
      size: m['size'] as String? ?? '1024x1024',
      quality: m['quality'] as String? ?? 'standard',
      customWidth: castInt(m['customWidth'], 1024),
      customHeight: castInt(m['customHeight'], 1024),
    );
  }

  static Map<String, dynamic> _a1111ToJson(A1111ImageSettings s) => {
    'endpoint': s.endpoint,
    'apiKey': s.apiKey,
    'model': s.model,
    'width': s.width,
    'height': s.height,
    'customSize': s.customSize,
    'steps': s.steps,
    'cfgScale': s.cfgScale,
    'sampler': s.sampler,
    'scheduler': s.scheduler,
    'seed': s.seed,
    'clipSkip': s.clipSkip,
    'promptPrefix': s.promptPrefix,
    'negativePrompt': s.negativePrompt,
    'vae': s.vae,
    'restoreFaces': s.restoreFaces,
    'enableHr': s.enableHr,
    'hrUpscaler': s.hrUpscaler,
    'hrScale': s.hrScale,
    'denoisingStrength': s.denoisingStrength,
    'hrSecondPassSteps': s.hrSecondPassSteps,
    'adetailerFace': s.adetailerFace,
  };

  static A1111ImageSettings _a1111FromJson(dynamic value) {
    if (value is! Map) return const A1111ImageSettings();
    final m = Map<String, dynamic>.from(value);
    return A1111ImageSettings(
      endpoint: m['endpoint'] as String? ?? '',
      apiKey: m['apiKey'] as String? ?? '',
      model: m['model'] as String? ?? '',
      width: castInt(m['width'], 512),
      height: castInt(m['height'], 512),
      customSize: castBool(m['customSize'], false),
      steps: castInt(m['steps'], 20),
      cfgScale: castDouble(m['cfgScale'], 7),
      sampler: m['sampler'] as String? ?? 'Euler a',
      scheduler: m['scheduler'] as String? ?? 'Automatic',
      seed: castInt(m['seed'], -1),
      clipSkip: castInt(m['clipSkip'], 1),
      promptPrefix: m['promptPrefix'] as String? ?? '',
      negativePrompt: m['negativePrompt'] as String? ?? '',
      vae: m['vae'] as String? ?? '',
      restoreFaces: castBool(m['restoreFaces'], false),
      enableHr: castBool(m['enableHr'], false),
      hrUpscaler: m['hrUpscaler'] as String? ?? '',
      hrScale: castDouble(m['hrScale'], 2),
      denoisingStrength: castDouble(m['denoisingStrength'], 0.7),
      hrSecondPassSteps: castInt(m['hrSecondPassSteps'], 0),
      adetailerFace: castBool(m['adetailerFace'], false),
    );
  }

  static Map<String, dynamic> _novelAiToJson(NovelAIImageSettings s) => {
    'apiKey': s.apiKey,
    'endpoint': s.endpoint,
    'model': s.model,
    'sampler': s.sampler,
    'noiseSchedule': s.noiseSchedule,
    'steps': s.steps,
    'scale': s.scale,
    'cfgRescale': s.cfgRescale,
    'width': s.width,
    'height': s.height,
    'customSize': s.customSize,
    'seed': s.seed,
    'negativePrompt': s.negativePrompt,
    'ucPreset': s.ucPreset,
    'qualityToggle': s.qualityToggle,
    'varietyBoost': s.varietyBoost,
  };

  static NovelAIImageSettings _novelAiFromJson(dynamic value) {
    if (value is! Map) return const NovelAIImageSettings();
    final m = Map<String, dynamic>.from(value);
    return NovelAIImageSettings(
      apiKey: m['apiKey'] as String? ?? '',
      endpoint: m['endpoint'] as String? ?? '',
      model: m['model'] as String? ?? 'nai-diffusion-4-5-full',
      sampler: m['sampler'] as String? ?? 'k_euler_ancestral',
      noiseSchedule: m['noiseSchedule'] as String? ?? 'karras',
      steps: castInt(m['steps'], 28),
      scale: castDouble(m['scale'], 5),
      cfgRescale: castDouble(m['cfgRescale'], 0),
      width: castInt(m['width'], 832),
      height: castInt(m['height'], 1216),
      customSize: castBool(m['customSize'], false),
      seed: castInt(m['seed'], -1),
      negativePrompt: m['negativePrompt'] as String? ?? '',
      ucPreset: m['ucPreset'] as String? ?? 'light',
      qualityToggle: castBool(m['qualityToggle'], true),
      varietyBoost: castBool(m['varietyBoost'], false),
    );
  }

  static Map<String, dynamic> _comfyUiToJson(ComfyUiImageSettings s) => {
    'endpoint': s.endpoint,
    'apiKey': s.apiKey,
    'workflows': s.workflows.map(_comfyWorkflowToJson).toList(),
    'activeWorkflowId': s.activeWorkflowId,
    'model': s.model,
    'vae': s.vae,
    'sampler': s.sampler,
    'scheduler': s.scheduler,
    'steps': s.steps,
    'cfgScale': s.cfgScale,
    'seed': s.seed,
    'denoise': s.denoise,
    'clipSkip': s.clipSkip,
    'width': s.width,
    'height': s.height,
    'customSize': s.customSize,
    'promptPrefix': s.promptPrefix,
    'negativePrompt': s.negativePrompt,
  };

  static ComfyUiImageSettings _comfyUiFromJson(dynamic value) {
    if (value is! Map) return const ComfyUiImageSettings();
    final m = Map<String, dynamic>.from(value);
    final workflows = _comfyWorkflowsFromJson(m);
    final storedActive = (m['activeWorkflowId'] as String? ?? '').trim();
    // A blob written before the workflow library existed has no
    // `activeWorkflowId`; the single migrated entry becomes the active one.
    final activeWorkflowId =
        storedActive.isNotEmpty || m.containsKey('workflows')
        ? storedActive
        : (workflows.isEmpty ? '' : workflows.first.id);
    return ComfyUiImageSettings(
      endpoint: m['endpoint'] as String? ?? '',
      apiKey: m['apiKey'] as String? ?? '',
      workflows: workflows,
      activeWorkflowId: activeWorkflowId,
      model: m['model'] as String? ?? '',
      vae: m['vae'] as String? ?? '',
      sampler: m['sampler'] as String? ?? ComfyUiConstants.defaultSampler,
      scheduler: m['scheduler'] as String? ?? ComfyUiConstants.defaultScheduler,
      steps: castInt(m['steps'], ComfyUiConstants.defaultSteps),
      cfgScale: castDouble(m['cfgScale'], ComfyUiConstants.defaultCfgScale),
      seed: castInt(m['seed'], -1),
      denoise: castDouble(m['denoise'], ComfyUiConstants.defaultDenoise),
      clipSkip: castInt(m['clipSkip'], ComfyUiConstants.defaultClipSkip),
      width: castInt(m['width'], ComfyUiConstants.defaultWidth),
      height: castInt(m['height'], ComfyUiConstants.defaultHeight),
      customSize: castBool(m['customSize'], false),
      promptPrefix: m['promptPrefix'] as String? ?? '',
      negativePrompt: m['negativePrompt'] as String? ?? '',
    );
  }

  static Map<String, dynamic> _comfyWorkflowToJson(ComfyUiWorkflow w) => {
    'id': w.id,
    'name': w.name,
    'json': w.json,
  };

  /// Parses the workflow library, migrating a pre-library `workflow` string
  /// into a single named entry so an already-saved graph is not lost.
  static List<ComfyUiWorkflow> _comfyWorkflowsFromJson(Map<String, dynamic> m) {
    final raw = m['workflows'];
    if (raw is List) {
      final workflows = <ComfyUiWorkflow>[];
      for (final entry in raw) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        final id = (map['id'] as String? ?? '').trim();
        if (id.isEmpty) continue;
        workflows.add(
          ComfyUiWorkflow(
            id: id,
            name: (map['name'] as String? ?? '').trim().isEmpty
                ? id
                : (map['name'] as String).trim(),
            json: map['json'] as String? ?? '',
          ),
        );
      }
      return workflows;
    }
    final legacy = (m['workflow'] as String? ?? '').trim();
    if (legacy.isEmpty) return const [];
    return [
      ComfyUiWorkflow(id: 'workflow-1', name: 'Workflow 1', json: legacy),
    ];
  }

  // ─── TensorArt ───────────────────────────────────────────────────────────

  static Map<String, dynamic> _tensorArtToJson(TensorArtImageSettings s) => {
    'accessKey': s.accessKey,
    'endpoint': s.endpoint,
    'toolName': s.toolName,
    'aspectRatio': s.aspectRatio,
    'imageSize': s.imageSize,
    'width': s.width,
    'height': s.height,
    'count': s.count,
    'tools': s.tools.map(_tensorArtToolToJson).toList(),
  };

  static TensorArtImageSettings _tensorArtFromJson(dynamic value) {
    if (value is! Map) return const TensorArtImageSettings();
    final m = Map<String, dynamic>.from(value);
    return TensorArtImageSettings(
      accessKey: m['accessKey'] as String? ?? '',
      endpoint: m['endpoint'] as String? ?? '',
      toolName: m['toolName'] as String? ?? TensorArtConstants.defaultTool,
      aspectRatio: m['aspectRatio'] as String? ?? '1:1',
      imageSize: m['imageSize'] as String? ?? '1K',
      width: castInt(m['width'], 1024),
      height: castInt(m['height'], 1024),
      count: castInt(m['count'], 1),
      tools: _tensorArtToolsFromJson(m['tools']),
    );
  }

  static Map<String, dynamic> _tensorArtToolToJson(TensorArtTool t) => {
    'name': t.name,
    'description': t.description,
    'taskType': t.taskType,
    'estimatedCost': t.estimatedCost,
    'imageOutput': t.imageOutput,
    'inputs': t.inputs.map(_tensorArtInputToJson).toList(),
  };

  static Map<String, dynamic> _tensorArtInputToJson(TensorArtToolInput input) =>
      {
        'type': input.type,
        'description': input.description,
        'format': input.format,
        'requiresAssetFields': input.requiresAssetFields,
      };

  static List<TensorArtTool> _tensorArtToolsFromJson(dynamic value) {
    if (value is! List) return const [];
    final tools = <TensorArtTool>[];
    for (final raw in value) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final name = (m['name'] as String? ?? '').trim();
      if (name.isEmpty) continue;
      tools.add(
        TensorArtTool(
          name: name,
          description: m['description'] as String? ?? '',
          taskType: m['taskType'] as String? ?? '',
          estimatedCost: m['estimatedCost'] as String? ?? '',
          imageOutput: castBool(m['imageOutput'], true),
          inputs: _tensorArtInputsFromJson(m['inputs']),
        ),
      );
    }
    return tools;
  }

  static List<TensorArtToolInput> _tensorArtInputsFromJson(dynamic value) {
    if (value is! List) return const [];
    final inputs = <TensorArtToolInput>[];
    for (final raw in value) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final type = (m['type'] as String? ?? '').trim();
      if (type.isEmpty) continue;
      inputs.add(
        TensorArtToolInput(
          type: type,
          description: m['description'] as String? ?? '',
          format: m['format'] as String? ?? '',
          requiresAssetFields: castBool(m['requiresAssetFields'], false),
        ),
      );
    }
    return inputs;
  }

  // ─── Primitive coercion ──────────────────────────────────────────────────

  static bool castBool(dynamic v, bool defaultValue) {
    if (v is bool) return v;
    if (v == 'true') return true;
    if (v == 'false') return false;
    return defaultValue;
  }

  static int castInt(dynamic v, int defaultValue) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? defaultValue;
    return defaultValue;
  }

  static double castDouble(dynamic v, double defaultValue) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? defaultValue;
    return defaultValue;
  }

  static ImageGenApiType parseApiType(String? v) {
    // The RU mirror was removed; its stored value folds into rout.my.
    if (v == 'ruRoutmy') return ImageGenApiType.routmy;
    for (final type in ImageGenApiType.values) {
      if (type.name == v) return type;
    }
    return ImageGenApiType.openai;
  }
}
