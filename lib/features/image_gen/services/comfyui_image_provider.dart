import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../image_gen_models.dart';
import 'image_gen_http.dart';

/// ComfyUI image generation.
///
/// Ported from SillyTavern's stable-diffusion extension:
/// `generateComfyImageCommon` in
/// `public/scripts/extensions/stable-diffusion/index.js` and the `comfy` router
/// in `src/endpoints/stable-diffusion.js`.
///
/// ComfyUI has no fixed request shape, so the user supplies an API-format
/// workflow whose `%token%` string literals are substituted before the graph is
/// POSTed to `/prompt`. The server then runs the graph, `/history/{id}` is
/// polled until the prompt appears there, and the first output image is fetched
/// from `/view`.
class ComfyUiImageProvider {
  final ImageGenHttp _http = ImageGenHttp();

  Future<Uint8List> generate({
    required ComfyUiImageSettings settings,
    required String prompt,
    CancelToken? cancelToken,
  }) async {
    final base = _base(settings.endpoint);
    final headers = _authHeaders(settings.apiKey);
    final workflow = buildWorkflow(settings, prompt: prompt);

    final json = await _http.post(
      url: '$base/prompt',
      body: {'prompt': workflow},
      extraHeaders: headers,
      cancelToken: cancelToken,
    );
    final promptId = (json['prompt_id'] ?? '').toString();
    if (promptId.isEmpty) {
      throw Exception('ComfyUI did not return a prompt id');
    }

    final item = await _awaitHistory(
      base: base,
      promptId: promptId,
      headers: headers,
      cancelToken: cancelToken,
    );
    _throwIfFailed(item);

    final image = _firstImageInfo(item);
    if (image == null) {
      throw Exception('ComfyUI did not return any recognizable outputs');
    }

    final viewUrl = Uri.parse(
      '$base/view',
    ).replace(queryParameters: image.query).toString();
    final response = await _http.getRaw(
      viewUrl,
      extraHeaders: headers,
      cancelToken: cancelToken,
    );
    return response.data ?? Uint8List(0);
  }

  /// Checkpoint, UNet and GGUF loader entries offered by the server. Mirrors
  /// SillyTavern's `/api/sd/comfy/models`.
  Future<List<String>> fetchModels(ComfyUiImageSettings settings) async {
    final info = await _objectInfo(settings);
    return [
      ..._objectInfoValues(info, 'CheckpointLoaderSimple', 'ckpt_name'),
      ..._objectInfoValues(info, 'UNETLoader', 'unet_name'),
      ..._objectInfoValues(info, 'UnetLoaderGGUF', 'unet_name'),
    ];
  }

  /// `/system_stats` is the cheapest route that proves the server is up.
  Future<void> ping(ComfyUiImageSettings settings) async {
    await _http.getJson(
      url: '${_base(settings.endpoint)}/system_stats',
      extraHeaders: _authHeaders(settings.apiKey),
    );
  }

  Future<Map<String, dynamic>> _objectInfo(ComfyUiImageSettings settings) {
    return _http.getJson(
      url: '${_base(settings.endpoint)}/object_info',
      extraHeaders: _authHeaders(settings.apiKey),
    );
  }

  /// Substitutes the workflow's `%token%` literals and parses the result.
  ///
  /// Each token is replaced where SillyTavern replaces it — the quoted
  /// `"%token%"` form — with the JSON encoding of the value, so a numeric
  /// placeholder lands as a number and a string one stays quoted.
  ///
  /// A graph exported straight from ComfyUI carries a literal prompt and no
  /// `%prompt%` token, so substitution would be a no-op and every request would
  /// reuse that baked-in text. When the prompt token is absent, the prompt node
  /// the sampler is wired to is found and overwritten instead.
  static Map<String, dynamic> buildWorkflow(
    ComfyUiImageSettings settings, {
    required String prompt,
  }) {
    final raw = settings.activeWorkflowJson.isEmpty
        ? ComfyUiConstants.defaultWorkflow
        : settings.activeWorkflowJson;
    final seed = settings.seed >= 0 ? settings.seed : _randomSeed();

    final values = <String, Object>{
      'prompt': _composePrompt(settings.promptPrefix, prompt),
      'negative_prompt': settings.negativePrompt,
      'seed': seed,
      'denoise': settings.denoise,
      // ComfyUI's CLIPSetLastLayer takes the value negative.
      'clip_skip': -settings.clipSkip,
      'model': settings.model,
      'vae': settings.vae,
      'sampler': settings.sampler,
      'scheduler': settings.scheduler,
      'steps': settings.steps,
      'scale': settings.cfgScale,
      'width': settings.width,
      'height': settings.height,
    };

    var replaced = raw;
    for (final entry in values.entries) {
      replaced = replaced.replaceAll(
        '"%${entry.key}%"',
        jsonEncode(entry.value),
      );
    }

    final decoded = jsonDecode(replaced);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ComfyUI workflow must be a JSON object');
    }

    if (!raw.contains('"%prompt%"')) {
      _injectText(
        decoded,
        prompt: values['prompt']! as String,
        negativePrompt: values['negative_prompt']! as String,
      );
    }
    return decoded;
  }

  /// Writes [prompt] / [negativePrompt] into the text nodes a sampler is wired
  /// to, for graphs that carry no prompt token.
  ///
  /// The sampler's `positive` / `negative` links are the only reliable way to
  /// tell the conditioning nodes apart across the many encoder classes
  /// (`CLIPTextEncode`, `TextEncodeQwenImage21`, `T5TextEncode`, …). A combined
  /// node that carries both prompts (like `TextEncodeQwenImage21`) is reached
  /// for either role and gets its `prompt` / `negative_prompt` fields set.
  static void _injectText(
    Map<String, dynamic> workflow, {
    required String prompt,
    required String negativePrompt,
  }) {
    final positive = <String>{};
    final negative = <String>{};
    for (final node in workflow.values) {
      final inputs = _inputsOf(node);
      if (inputs == null) continue;
      _addReference(positive, inputs['positive']);
      _addReference(negative, inputs['negative']);
    }

    // No sampler wiring to follow — fall back to the first node that carries a
    // prompt field so a minimal graph still receives the scene.
    if (positive.isEmpty && negative.isEmpty) {
      for (final node in workflow.values) {
        if (_writePrompt(node, prompt, negativePrompt)) break;
      }
      return;
    }

    for (final id in positive) {
      _writeField(workflow[id], 'positive', prompt);
    }
    for (final id in negative) {
      _writeField(workflow[id], 'negative', negativePrompt);
    }
  }

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
  static bool _writeField(Object? node, String role, String value) {
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
  static bool _writePrompt(Object? node, String prompt, String negativePrompt) {
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

  Future<Map<String, dynamic>> _awaitHistory({
    required String base,
    required String promptId,
    required Map<String, String> headers,
    CancelToken? cancelToken,
  }) async {
    final historyUrl = '$base/history/$promptId';
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    try {
      while (true) {
        final history = await _http.getJson(
          url: historyUrl,
          extraHeaders: headers,
          cancelToken: cancelToken,
        );
        final item = history[promptId];
        if (item is Map) return item.cast<String, dynamic>();
        if (DateTime.now().isAfter(deadline)) {
          throw Exception('ComfyUI generation timed out');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) await _interrupt(base, headers);
      rethrow;
    }
  }

  /// Best-effort `/interrupt`: a cancelled generation should stop the server
  /// too, but a failure here must not mask the cancellation itself.
  Future<void> _interrupt(String base, Map<String, String> headers) async {
    try {
      await _http.post(
        url: '$base/interrupt',
        body: const {},
        extraHeaders: headers,
      );
    } catch (_) {}
  }

  static void _throwIfFailed(Map<String, dynamic> item) {
    final status = item['status'];
    if (status is! Map) return;
    if (status['status_str'] != 'error') return;

    final errors = <String>[];
    final messages = status['messages'];
    if (messages is List) {
      for (final message in messages) {
        if (message is! List || message.length < 2) continue;
        if (message[0] != 'execution_error') continue;
        final info = message[1];
        if (info is Map) {
          errors.add(
            '${info['node_type']} [${info['node_id']}] '
            '${info['exception_type']}: ${info['exception_message']}',
          );
        }
      }
    }
    throw Exception(
      errors.isEmpty ? 'ComfyUI generation did not succeed' : errors.join('\n'),
    );
  }

  static _ComfyImageInfo? _firstImageInfo(Map<String, dynamic> item) {
    final outputs = item['outputs'];
    if (outputs is! Map) return null;
    for (final output in outputs.values) {
      if (output is! Map) continue;
      for (final key in const ['images', 'gifs']) {
        final images = output[key];
        if (images is! List) continue;
        for (final image in images) {
          if (image is! Map) continue;
          final filename = (image['filename'] ?? '').toString();
          if (filename.isEmpty) continue;
          return _ComfyImageInfo(
            filename: filename,
            subfolder: (image['subfolder'] ?? '').toString(),
            type: (image['type'] ?? 'output').toString(),
          );
        }
      }
    }
    return null;
  }

  static List<String> _objectInfoValues(
    Map<String, dynamic> info,
    String node,
    String field,
  ) {
    final nodeInfo = info[node];
    if (nodeInfo is! Map) return const [];
    final input = nodeInfo['input'];
    if (input is! Map) return const [];
    final required = input['required'];
    if (required is! Map) return const [];
    final fieldInfo = required[field];
    if (fieldInfo is! List || fieldInfo.isEmpty) return const [];
    final values = fieldInfo.first;
    if (values is! List) return const [];
    return values
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  static String _composePrompt(String prefix, String prompt) {
    final head = prefix.trim();
    final body = prompt.trim();
    if (head.isEmpty) return body;
    if (body.isEmpty) return head;
    return '$head, $body';
  }

  static int _randomSeed() => Random().nextInt(0x7FFFFFFF);

  static Map<String, String> _authHeaders(String apiKey) {
    final key = apiKey.trim();
    if (key.isEmpty) return const {};
    return {'Authorization': 'Basic ${base64Encode(utf8.encode(key))}'};
  }

  static String _base(String endpoint) {
    final trimmed = endpoint.trim();
    return (trimmed.isEmpty ? ComfyUiConstants.defaultEndpoint : trimmed)
        .replaceFirst(RegExp(r'/+$'), '');
  }
}

class _ComfyImageInfo {
  const _ComfyImageInfo({
    required this.filename,
    required this.subfolder,
    required this.type,
  });

  final String filename;
  final String subfolder;
  final String type;

  Map<String, String> get query => {
    'filename': filename,
    'subfolder': subfolder,
    'type': type,
  };
}
