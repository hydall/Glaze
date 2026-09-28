import 'dart:convert';

import '../image_gen_models.dart';

/// The sampler parameters a ComfyUI API graph carries.
///
/// Used in both directions:
/// - [read] pulls the values out of an imported graph so the settings UI can
///   show the parameters the workflow actually runs with.
/// - [writeSettings] / [writePrompt] put the current settings back into the
///   graph before a request, for graphs that carry no `%token%` placeholders.
class ComfyUiWorkflowParams {
  const ComfyUiWorkflowParams({
    this.model,
    this.vae,
    this.sampler,
    this.scheduler,
    this.steps,
    this.cfgScale,
    this.seed,
    this.denoise,
    this.clipSkip,
    this.width,
    this.height,
  });

  final String? model;
  final String? vae;
  final String? sampler;
  final String? scheduler;
  final int? steps;
  final double? cfgScale;
  final int? seed;
  final double? denoise;
  final int? clipSkip;
  final int? width;
  final int? height;

  static const ComfyUiWorkflowParams empty = ComfyUiWorkflowParams();

  /// Parameters found in [json]; a field that is absent or left as a `%token%`
  /// placeholder is null.
  static ComfyUiWorkflowParams read(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return empty;
    }
    if (decoded is! Map) return empty;
    return fromGraph(decoded.cast<String, dynamic>());
  }

  static ComfyUiWorkflowParams fromGraph(Map<String, dynamic> graph) {
    final sampler = _primarySampler(graph);
    final latent = _latent(graph);
    final model = _modelLoader(graph);
    final vae = _vaeLoader(graph);
    final clip = _clipSkipNode(graph);

    final clipValue = clip == null
        ? null
        : _int(clip.inputs, 'stop_at_clip_layer');
    return ComfyUiWorkflowParams(
      model: model == null ? null : _string(model.inputs, model.key),
      vae: vae == null ? null : _string(vae.inputs, vae.key),
      sampler: _string(sampler, 'sampler_name'),
      scheduler: _string(sampler, 'scheduler'),
      steps: _int(sampler, 'steps'),
      cfgScale: _double(sampler, 'cfg'),
      seed: _int(sampler, 'seed'),
      denoise: _double(sampler, 'denoise'),
      clipSkip: clipValue?.abs(),
      width: _int(latent, 'width'),
      height: _int(latent, 'height'),
    );
  }

  /// Replaces the matching fields of [settings] with the parsed values; a null
  /// field leaves the setting untouched.
  ComfyUiImageSettings applyTo(ComfyUiImageSettings settings) {
    final hasSize = width != null && height != null;
    return settings.copyWith(
      model: model ?? settings.model,
      vae: vae ?? settings.vae,
      sampler: sampler ?? settings.sampler,
      scheduler: scheduler ?? settings.scheduler,
      steps: steps ?? settings.steps,
      cfgScale: cfgScale ?? settings.cfgScale,
      seed: seed ?? settings.seed,
      denoise: denoise ?? settings.denoise,
      clipSkip: clipSkip ?? settings.clipSkip,
      width: width ?? settings.width,
      height: height ?? settings.height,
      customSize: hasSize
          ? !_isPresetSize(width!, height!)
          : settings.customSize,
    );
  }

  /// Writes [prompt] / [negativePrompt] into the text nodes the sampler is
  /// wired to.
  ///
  /// The graph carries a literal prompt and no `%prompt%` token, so token
  /// substitution is a no-op and every request would reuse that baked-in text.
  /// The sampler's `positive` / `negative` links are the only reliable way to
  /// tell the conditioning nodes apart across the many encoder classes
  /// (`CLIPTextEncode`, `TextEncodeQwenImage21`, `T5TextEncode`, …). A combined
  /// node that carries both prompts (like `TextEncodeQwenImage21`) is reached
  /// for either role and gets its `prompt` / `negative_prompt` fields set.
  static void writePrompt(
    Map<String, dynamic> graph, {
    required String prompt,
    required String negativePrompt,
  }) {
    final positive = <String>{};
    final negative = <String>{};
    for (final node in graph.values) {
      final inputs = _inputsOf(node);
      if (inputs == null) continue;
      _addReference(positive, inputs['positive']);
      _addReference(negative, inputs['negative']);
    }

    // No sampler wiring to follow — fall back to the first node that carries a
    // prompt field so a minimal graph still receives the scene.
    if (positive.isEmpty && negative.isEmpty) {
      for (final node in graph.values) {
        if (_writePromptNode(node, prompt, negativePrompt)) break;
      }
      return;
    }

    for (final id in positive) {
      _writePromptField(graph[id], 'positive', prompt);
    }
    for (final id in negative) {
      _writePromptField(graph[id], 'negative', negativePrompt);
    }
  }

  /// Writes [settings] into the graph's sampler, latent, model, VAE and
  /// CLIPSetLastLayer nodes, skipping every field that still has a matching
  /// `%token%` (those were already substituted by the caller).
  static void writeSettings(
    Map<String, dynamic> graph,
    ComfyUiImageSettings settings, {
    required int seed,
    required bool Function(String token) hasToken,
  }) {
    final sampler = _primarySampler(graph);
    if (sampler != null) {
      _writeString(
        sampler,
        'sampler_name',
        settings.sampler,
        hasToken('sampler'),
      );
      _writeString(
        sampler,
        'scheduler',
        settings.scheduler,
        hasToken('scheduler'),
      );
      _writeInt(sampler, 'steps', settings.steps, hasToken('steps'));
      _writeDouble(sampler, 'cfg', settings.cfgScale, hasToken('scale'));
      _writeInt(sampler, 'seed', seed, hasToken('seed'));
      _writeDouble(sampler, 'denoise', settings.denoise, hasToken('denoise'));
    }

    final latent = _latent(graph);
    if (latent != null) {
      _writeInt(latent, 'width', settings.width, hasToken('width'));
      _writeInt(latent, 'height', settings.height, hasToken('height'));
    }

    final model = _modelLoader(graph);
    if (model != null && !hasToken('model') && settings.model.isNotEmpty) {
      model.inputs[model.key] = settings.model;
    }

    final vae = _vaeLoader(graph);
    if (vae != null && !hasToken('vae') && settings.vae.isNotEmpty) {
      vae.inputs[vae.key] = settings.vae;
    }

    final clip = _clipSkipNode(graph);
    if (clip != null && !hasToken('clip_skip')) {
      clip.inputs['stop_at_clip_layer'] = -settings.clipSkip;
    }
  }

  // ── Node lookup ──────────────────────────────────────────────────────────

  /// The sampler the scene flow passes through: the one wired through
  /// `positive` / `negative`, otherwise the first sampler-looking node.
  static Map<String, dynamic>? _primarySampler(Map<String, dynamic> graph) {
    final references = <String>{};
    for (final node in graph.values) {
      final inputs = _inputsOf(node);
      if (inputs == null) continue;
      _addReference(references, inputs['positive']);
      _addReference(references, inputs['negative']);
    }
    for (final id in references) {
      final inputs = _inputsOf(graph[id]);
      if (inputs != null && _isSampler(inputs)) return inputs;
    }
    for (final node in graph.values) {
      final inputs = _inputsOf(node);
      if (inputs != null && _isSampler(inputs)) return inputs;
    }
    return null;
  }

  static bool _isSampler(Map<String, dynamic> inputs) =>
      inputs.containsKey('sampler_name') ||
      (inputs.containsKey('steps') && inputs.containsKey('cfg')) ||
      (inputs.containsKey('seed') &&
          inputs.containsKey('positive') &&
          inputs.containsKey('negative'));

  static Map<String, dynamic>? _latent(Map<String, dynamic> graph) {
    for (final node in graph.values) {
      final inputs = _inputsOf(node);
      if (inputs == null) continue;
      if (inputs['width'] is int && inputs['height'] is int) return inputs;
    }
    return null;
  }

  static const Map<String, String> _modelKeys = {
    'CheckpointLoaderSimple': 'ckpt_name',
    'CheckpointLoader': 'ckpt_name',
    'UNETLoader': 'unet_name',
    'UnetLoaderGGUF': 'unet_name',
  };

  static _NodeRef? _modelLoader(Map<String, dynamic> graph) {
    for (final entry in graph.entries) {
      final node = entry.value;
      if (node is! Map) continue;
      final key = _modelKeys[node['class_type']?.toString()];
      if (key == null) continue;
      final inputs = _inputsOf(node);
      if (inputs == null || inputs[key] is! String) continue;
      return _NodeRef(inputs, key);
    }
    return null;
  }

  static _NodeRef? _vaeLoader(Map<String, dynamic> graph) {
    for (final node in graph.values) {
      if (node is! Map) continue;
      if (node['class_type']?.toString() != 'VAELoader') continue;
      final inputs = _inputsOf(node);
      if (inputs == null || inputs['vae_name'] is! String) continue;
      return _NodeRef(inputs, 'vae_name');
    }
    return null;
  }

  static _NodeRef? _clipSkipNode(Map<String, dynamic> graph) {
    for (final node in graph.values) {
      if (node is! Map) continue;
      if (node['class_type']?.toString() != 'CLIPSetLastLayer') continue;
      final inputs = _inputsOf(node);
      if (inputs == null || inputs['stop_at_clip_layer'] is! int) continue;
      return _NodeRef(inputs, 'stop_at_clip_layer');
    }
    return null;
  }

  // ── Field helpers ────────────────────────────────────────────────────────

  static String? _string(Map<String, dynamic>? inputs, String key) {
    final value = inputs?[key];
    if (value is String && value.isNotEmpty && !_isToken(value)) return value;
    return null;
  }

  static int? _int(Map<String, dynamic>? inputs, String key) {
    final value = inputs?[key];
    return value is num ? value.toInt() : null;
  }

  static double? _double(Map<String, dynamic>? inputs, String key) {
    final value = inputs?[key];
    return value is num ? value.toDouble() : null;
  }

  static void _writeString(
    Map<String, dynamic> inputs,
    String key,
    String value,
    bool hasToken,
  ) {
    if (hasToken || inputs[key] is! String) return;
    inputs[key] = value;
  }

  static void _writeInt(
    Map<String, dynamic> inputs,
    String key,
    int value,
    bool hasToken,
  ) {
    if (hasToken || inputs[key] is! num) return;
    inputs[key] = value;
  }

  static void _writeDouble(
    Map<String, dynamic> inputs,
    String key,
    double value,
    bool hasToken,
  ) {
    if (hasToken || inputs[key] is! num) return;
    inputs[key] = value;
  }

  static bool _isPresetSize(int width, int height) {
    for (final preset in A1111Constants.resolutionPresets) {
      if (preset.$2 == width && preset.$3 == height) return true;
    }
    return false;
  }

  static bool _isToken(Object? value) =>
      value is String &&
      value.length > 2 &&
      value.startsWith('%') &&
      value.endsWith('%');

  static Map<String, dynamic>? _inputsOf(Object? node) {
    if (node is! Map) return null;
    final inputs = node['inputs'];
    return inputs is Map ? inputs.cast<String, dynamic>() : null;
  }

  static void _addReference(Set<String> target, Object? reference) {
    if (reference is List && reference.isNotEmpty) {
      target.add(reference.first.toString());
    }
  }

  /// Sets the field matching [role] on [node]: `prompt` / `text` for the
  /// positive side, `negative_prompt` / `text` for the negative one.
  static bool _writePromptField(Object? node, String role, String value) {
    final inputs = _inputsOf(node);
    if (inputs == null) return false;
    final keys = role == 'negative'
        ? const ['negative_prompt', 'text']
        : const ['prompt', 'text'];
    for (final key in keys) {
      if (inputs[key] is String) {
        inputs[key] = value;
        return true;
      }
    }
    return false;
  }

  /// Writes whichever prompt fields [node] exposes; used when the graph has no
  /// sampler links. A lone `text` field counts as the positive prompt.
  static bool _writePromptNode(
    Object? node,
    String prompt,
    String negativePrompt,
  ) {
    final inputs = _inputsOf(node);
    if (inputs == null) return false;
    var wrote = false;
    if (inputs['prompt'] is String) {
      inputs['prompt'] = prompt;
      wrote = true;
    }
    if (inputs['negative_prompt'] is String) {
      inputs['negative_prompt'] = negativePrompt;
      wrote = true;
    }
    if (!wrote && inputs['text'] is String) {
      inputs['text'] = prompt;
      wrote = true;
    }
    return wrote;
  }
}

/// One node's mutable `inputs` map plus the field it stores a value under.
class _NodeRef {
  const _NodeRef(this.inputs, this.key);

  final Map<String, dynamic> inputs;
  final String key;
}
