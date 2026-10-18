import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../image_gen_models.dart';
import 'image_gen_http.dart';

/// TensorArt / Tusi OpenAPI client.
///
/// TensorArt exposes generation as tasks over a catalog of tools rather than
/// as a fixed model endpoint:
///
/// 1. `POST /tool/list` describes the tools and their positional inputs;
/// 2. `POST /task` submits `{toolName, inputs}` and returns a task id;
/// 3. `POST /task/query` is polled until the task is terminal;
/// 4. the returned file URL is downloaded.
///
/// References are uploaded through `POST /file/upload` and then PUT to the
/// presigned URL the response carries.
class TensorArtImageProvider {
  TensorArtImageProvider({
    this.pollInterval = const Duration(seconds: 3),
    this.pollTimeout = const Duration(minutes: 10),
  });

  final ImageGenHttp _http = ImageGenHttp();
  final Duration pollInterval;
  final Duration pollTimeout;

  /// Loads the image-output tools of the catalog. `tool/list` is public, so
  /// this also works before an access key has been entered.
  Future<List<TensorArtTool>> fetchTools({
    required String accessKey,
    String endpoint = '',
    CancelToken? cancelToken,
  }) async {
    final base = TensorArtConstants.resolveEndpoint(endpoint, accessKey);
    final json = await _http.post(
      url: '$base/tool/list',
      body: const {},
      extraHeaders: _authHeaders(accessKey),
      cancelToken: cancelToken,
    );
    _ensureOk(json);

    final data = json['data'];
    final rawTools = data is Map ? data['tools'] : null;
    if (rawTools is! List) return const [];

    final tools = <TensorArtTool>[];
    for (final raw in rawTools) {
      if (raw is! Map) continue;
      final tool = _parseTool(Map<String, dynamic>.from(raw));
      if (tool != null) tools.add(tool);
    }
    return tools;
  }

  /// Validates the key with an empty task query — `tool/list` does not check
  /// authentication, `task/query` does.
  Future<void> checkConnection({
    required String accessKey,
    String endpoint = '',
    CancelToken? cancelToken,
  }) async {
    final key = accessKey.trim();
    if (key.isEmpty) {
      throw StateError('Tensor Art access key not configured');
    }
    final base = TensorArtConstants.resolveEndpoint(endpoint, key);
    final json = await _http.post(
      url: '$base/task/query',
      body: const {'taskIds': <String>[]},
      extraHeaders: _authHeaders(key),
      cancelToken: cancelToken,
    );
    _ensureOk(json);
  }

  Future<Uint8List> generate({
    required TensorArtImageSettings settings,
    required String prompt,
    required List<Map<String, String>> references,
    CancelToken? cancelToken,
  }) async {
    final key = settings.accessKey.trim();
    if (key.isEmpty) {
      throw StateError('Tensor Art access key not configured');
    }
    final base = TensorArtConstants.resolveEndpoint(settings.endpoint, key);
    final auth = _authHeaders(key);

    final tool = await _resolveTool(settings, base, auth, cancelToken);
    final uploader = _TensorArtUploader(
      http: _http,
      base: base,
      auth: auth,
      cancelToken: cancelToken,
    );
    final inputs = await _buildInputs(
      tool: tool,
      settings: settings,
      prompt: prompt,
      references: references,
      uploader: uploader,
    );

    final created = await _http.post(
      url: '$base/task',
      body: {'toolName': tool.name, 'inputs': inputs},
      extraHeaders: auth,
      cancelToken: cancelToken,
    );
    _ensureOk(created);

    final data = created['data'];
    final task = data is Map ? data['task'] : null;
    final taskId = task is Map ? (task['id'] ?? '').toString() : '';
    if (taskId.isEmpty) {
      throw Exception('Tensor Art did not return a task id');
    }

    final finished = await _poll(
      base: base,
      taskId: taskId,
      auth: auth,
      cancelToken: cancelToken,
    );
    final url = _extractOutputUrl(finished);
    if (url == null) {
      throw Exception('Tensor Art returned no output file');
    }
    return ImageGenHttp.downloadImage(url, cancelToken: cancelToken);
  }

  Future<TensorArtTool> _resolveTool(
    TensorArtImageSettings settings,
    String base,
    Map<String, String> auth,
    CancelToken? cancelToken,
  ) async {
    final stored = settings.selectedTool;
    if (stored != null) return stored;

    final tools = await fetchTools(
      accessKey: settings.accessKey,
      endpoint: base,
      cancelToken: cancelToken,
    );
    for (final tool in tools) {
      if (tool.name == settings.toolName) return tool;
    }
    throw Exception(
      'Tensor Art tool "${settings.toolName}" is not in the catalog',
    );
  }

  Future<List<dynamic>> _buildInputs({
    required TensorArtTool tool,
    required TensorArtImageSettings settings,
    required String prompt,
    required List<Map<String, String>> references,
    required _TensorArtUploader uploader,
  }) async {
    final images = references
        .where((ref) => (ref['image'] ?? '').isNotEmpty)
        .toList();
    final inputs = <dynamic>[];

    for (final input in tool.inputs) {
      if (input.isPrompt) {
        inputs.add(prompt);
        continue;
      }
      if (input.isAspectRatio) {
        inputs.add(settings.aspectRatio);
        continue;
      }
      if (input.isImageSize) {
        inputs.add(settings.imageSize);
        continue;
      }
      if (input.isWidth) {
        inputs.add(settings.width);
        continue;
      }
      if (input.isHeight) {
        inputs.add(settings.height);
        continue;
      }
      if (input.isCount) {
        inputs.add(settings.count.clamp(1, 4));
        continue;
      }
      if (input.isString) {
        final description = input.description.toLowerCase();
        if (description.contains('quality')) {
          inputs.add('standard');
        } else if (description.contains('duration')) {
          inputs.add('5');
        } else {
          inputs.add(_firstQuotedValue(input.description));
        }
        continue;
      }
      if (input.isInteger) {
        inputs.add(1);
        continue;
      }
      if (input.isFile) {
        if (images.isEmpty) {
          throw Exception(
            'Tensor Art tool "${tool.name}" requires a reference image',
          );
        }
        final uploaded = await uploader.upload(images.first, 0);
        inputs.add(uploaded.url);
        continue;
      }
      if (input.isArray) {
        if (images.isEmpty) {
          throw Exception(
            'Tensor Art tool "${tool.name}" requires a reference image',
          );
        }
        final values = <Map<String, dynamic>>[];
        for (var i = 0; i < images.length; i++) {
          final uploaded = await uploader.upload(images[i], i);
          values.add(
            input.requiresAssetFields
                ? uploaded.toAssetObject()
                : uploaded.toUrlObject(),
          );
        }
        inputs.add(values);
        continue;
      }
      inputs.add(null);
    }

    return inputs;
  }

  Future<Map<String, dynamic>> _poll({
    required String base,
    required String taskId,
    required Map<String, String> auth,
    CancelToken? cancelToken,
  }) async {
    final deadline = DateTime.now().add(pollTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      if (cancelToken?.isCancelled ?? false) {
        throw Exception('Tensor Art generation cancelled');
      }
      final json = await _http.post(
        url: '$base/task/query',
        body: {
          'taskIds': [taskId],
        },
        extraHeaders: auth,
        cancelToken: cancelToken,
      );
      _ensureOk(json);

      final data = json['data'];
      final tasks = data is Map ? data['tasks'] : null;
      if (tasks is! List || tasks.isEmpty) continue;
      final task = tasks.first;
      if (task is! Map) continue;
      final map = Map<String, dynamic>.from(task);
      final status = (map['status'] ?? '').toString().toUpperCase();

      if (status == 'FINISH') return map;
      if (status == 'EXCEPTION' || status == 'CANCELED') {
        final reason = map['message'] ?? map['error'] ?? map['status'];
        throw Exception('Tensor Art generation failed: $reason');
      }
    }
    throw Exception(
      'Tensor Art polling timed out after ${pollTimeout.inSeconds}s',
    );
  }

  static TensorArtTool? _parseTool(Map<String, dynamic> raw) {
    final name = (raw['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;

    final outputs = raw['outputs'];
    final imageOutput =
        outputs is List &&
        outputs.whereType<Map<Object?, Object?>>().any((output) {
          final format = (output['format'] ?? '').toString().toLowerCase();
          final description = (output['description'] ?? '')
              .toString()
              .toLowerCase();
          return format.contains('image') ||
              description.contains('image') ||
              description.contains('图片');
        });
    if (!imageOutput) return null;

    final rawInputs = raw['inputs'];
    final inputs = <TensorArtToolInput>[];
    if (rawInputs is List) {
      for (final entry in rawInputs) {
        if (entry is! Map) continue;
        final input = Map<String, dynamic>.from(entry);
        final type = (input['type'] ?? '').toString().trim();
        if (type.isEmpty) continue;
        inputs.add(
          TensorArtToolInput(
            type: type,
            description: (input['description'] ?? '').toString(),
            format: (input['format'] ?? '').toString(),
            requiresAssetFields: _requiresAssetFields(input['schema']),
          ),
        );
      }
    }

    return TensorArtTool(
      name: name,
      description: (raw['description'] ?? '').toString(),
      taskType: (raw['taskType'] ?? '').toString(),
      estimatedCost: (raw['estimatedCost'] ?? '').toString(),
      inputs: inputs,
      imageOutput: true,
    );
  }

  static bool _requiresAssetFields(dynamic schema) {
    if (schema is! Map) return false;
    final items = schema['items'];
    if (items is! Map) return false;
    final required = items['required'];
    if (required is! List) return false;
    return required.any(
      (field) => field == 'assetId' || field == 'assetUri' || field == 'type',
    );
  }

  static Map<String, String> _authHeaders(String accessKey) {
    final key = accessKey.trim();
    if (key.isEmpty) return const {};
    return {'Echo-Access-Key': key};
  }

  static void _ensureOk(Map<String, dynamic> json) {
    final code = json['code'];
    if (code == null || code == 0 || code == '0') return;
    final message =
        json['message'] ?? json['msg'] ?? 'Unknown Tensor Art error';
    throw Exception('Tensor Art: $message (code $code)');
  }

  static String _firstQuotedValue(String description) {
    final match = RegExp(r'"([^"]+)"').firstMatch(description);
    return match?.group(1) ?? '';
  }

  static String? _extractOutputUrl(Map<String, dynamic> task) {
    final urls = <String>[];
    void walk(dynamic node) {
      if (node is String) {
        if (node.startsWith('http://') || node.startsWith('https://')) {
          urls.add(node);
        }
        return;
      }
      if (node is List) {
        for (final value in node) {
          walk(value);
        }
        return;
      }
      if (node is Map) {
        for (final value in node.values) {
          walk(value);
        }
      }
    }

    walk(task['outputs'] ?? task);
    for (final url in urls) {
      if (_looksLikeImageUrl(url)) return url;
    }
    return urls.isEmpty ? null : urls.first;
  }

  static bool _looksLikeImageUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return const [
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.gif',
      '.avif',
    ].any(path.endsWith);
  }
}

class _TensorArtUploadedFile {
  const _TensorArtUploadedFile({
    required this.url,
    required this.mimeType,
    required this.data,
  });

  final String url;
  final String mimeType;
  final Map<String, dynamic> data;

  Map<String, dynamic> toUrlObject() => {'url': url, 'mimeType': mimeType};

  Map<String, dynamic> toAssetObject() {
    final assetId = (data['assetId'] ?? '').toString();
    final assetUri = (data['assetUri'] ?? '').toString();
    final type = (data['type'] ?? '').toString();
    if (assetId.isEmpty || assetUri.isEmpty || type.isEmpty) {
      throw Exception(
        'Tensor Art did not return asset metadata for the uploaded reference',
      );
    }
    return {
      'url': url,
      'mimeType': mimeType,
      'assetId': assetId,
      'type': type,
      'assetUri': assetUri,
    };
  }
}

class _TensorArtUploader {
  const _TensorArtUploader({
    required this.http,
    required this.base,
    required this.auth,
    required this.cancelToken,
  });

  final ImageGenHttp http;
  final String base;
  final Map<String, String> auth;
  final CancelToken? cancelToken;

  Future<_TensorArtUploadedFile> upload(
    Map<String, String> reference,
    int index,
  ) async {
    final image = reference['image'] ?? '';
    final mime = reference['mime'] ?? 'image/png';
    if (image.isEmpty) {
      throw Exception('Tensor Art reference image is empty');
    }
    final bytes = ImageGenHttp.base64ToBytes(
      ImageGenHttp.stripBase64Prefix(image),
    );

    final json = await http.post(
      url: '$base/file/upload',
      body: {'filename': 'reference-$index${_extension(mime)}'},
      extraHeaders: auth,
      cancelToken: cancelToken,
    );
    TensorArtImageProvider._ensureOk(json);

    final data = json['data'];
    if (data is! Map) {
      throw Exception('Tensor Art did not return an upload URL');
    }
    final map = Map<String, dynamic>.from(data);
    final uploadUrl = (map['uploadUrl'] ?? '').toString();
    if (uploadUrl.isEmpty) {
      throw Exception('Tensor Art did not return an upload URL');
    }

    await http.putBytes(
      url: uploadUrl,
      bytes: bytes,
      contentType: mime,
      cancelToken: cancelToken,
    );

    final displayUrl = (map['displayUrl'] ?? '').toString();
    final accessUrl = (map['accessUrl'] ?? '').toString();
    final url = displayUrl.isNotEmpty ? displayUrl : accessUrl;
    if (url.isEmpty) {
      throw Exception('Tensor Art did not return an uploaded file URL');
    }
    return _TensorArtUploadedFile(url: url, mimeType: mime, data: map);
  }

  static String _extension(String mime) => switch (mime.toLowerCase()) {
    'image/jpeg' => '.jpg',
    'image/webp' => '.webp',
    'image/gif' => '.gif',
    'image/avif' => '.avif',
    _ => '.png',
  };
}
