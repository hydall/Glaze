import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../image_gen_models.dart';
import 'image_gen_http.dart';

/// Naistera image client.
///
/// Mirrors the reference extension (https://github.com/0xl0cal/sillyimages,
/// `NaisteraProvider`): `POST {base}/api/generate` with a JSON body, answered
/// either synchronously with `data_url` or with a `job_id` that is polled on
/// `GET {base}/api/generate/jobs/{id}`. The route Glaze used before
/// (`/prompt/api/img`, `images: [base64]`) is retired and answers
/// 405 Method Not Allowed.
class NaisteraImageProvider {
  NaisteraImageProvider({
    this.baseUrl = NaisteraConstants.baseUrl,
    this.pollInterval = const Duration(seconds: 3),
    this.pollTimeout = const Duration(minutes: 10),
  });

  final ImageGenHttp _http = ImageGenHttp();
  final String baseUrl;
  final Duration pollInterval;
  final Duration pollTimeout;

  Future<Uint8List> generate({
    required String apiKey,
    required String model,
    required String prompt,
    required String aspectRatio,
    List<Map<String, String>>? references,
    // Whether the selected model round-trips reference images: decided by the
    // caller from the fetched catalog rather than by the shipped deny-list.
    bool supportsReferences = true,
    // Already resolved by the caller (library entry or provider field) and
    // gated on the catalog's `negative_prompt` flag; empty sends nothing.
    String negativePrompt = '',
    CancelToken? cancelToken,
  }) async {
    final normalizedModel = NaisteraConstants.normalizeModel(model);
    final body = <String, dynamic>{
      'prompt': prompt,
      'aspect_ratio': aspectRatio,
      'model': normalizedModel,
    };
    final negative = negativePrompt.trim();
    if (negative.isNotEmpty) body['negative_prompt'] = negative;
    final referenceObjects = supportsReferences
        ? _referenceObjects(references)
        : const <Map<String, String>>[];
    if (referenceObjects.isNotEmpty) {
      body['reference_objects'] = referenceObjects;
    }

    var json = await _http.post(
      url: _generateUrl,
      apiKey: apiKey,
      body: body,
      cancelToken: cancelToken,
    );

    final rawJobId = json['job_id'];
    final jobId = rawJobId is String ? rawJobId : '';
    if (json['data_url'] is! String && jobId.isNotEmpty) {
      json = await _pollJob(jobId, apiKey: apiKey, cancelToken: cancelToken);
    }

    return _bytesFrom(json, cancelToken: cancelToken);
  }

  String get _generateUrl {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return base.endsWith('/api/generate') ? base : '$base/api/generate';
  }

  /// Naistera takes references as `{image, description}` pairs where `image`
  /// is a full data URL — the collector hands over bare base64 plus its mime.
  static List<Map<String, String>> _referenceObjects(
    List<Map<String, String>>? references,
  ) {
    if (references == null || references.isEmpty) return const [];
    final objects = <Map<String, String>>[];
    for (final ref in references) {
      final image = ref['image'] ?? '';
      if (image.isEmpty) continue;
      final mime = ref['mime'] ?? 'image/png';
      objects.add({
        'image': image.startsWith('data:') ? image : 'data:$mime;base64,$image',
        'description': ref['description'] ?? '',
      });
    }
    return objects;
  }

  /// Loads the model catalog from `GET {base}/api/models`.
  ///
  /// Ported from https://github.com/0xl0cal/sillyimages
  /// (`NaisteraProvider.fetchModels`): the token decides which tier of models
  /// comes back, hidden and deprecated entries are dropped, and reference
  /// support is read off each entry instead of a hardcoded deny-list. When the
  /// authenticated request cannot be made at all, the public catalog is tried
  /// once without the token.
  Future<List<NaisteraModelInfo>> fetchModels({
    required String apiKey,
    CancelToken? cancelToken,
  }) async {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final url = '$base/api/models';

    Map<String, dynamic> payload;
    try {
      payload = await _http.getJson(
        url: url,
        apiKey: apiKey,
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      if (apiKey.isEmpty ||
          CancelToken.isCancel(error) ||
          error.response != null) {
        rethrow;
      }
      // No response at all (connection refused, TLS, CORS-style block) — the
      // public catalog still tells us which models exist.
      payload = await _http.getJson(url: url, cancelToken: cancelToken);
    }

    final models = payload['models'];
    if (models is! List) return const [];
    final catalog = <NaisteraModelInfo>[];
    for (final raw in models) {
      if (raw is! Map) continue;
      final model = Map<String, dynamic>.from(raw);
      final id = (model['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      if (model['visible'] == false || model['deprecated'] == true) continue;
      catalog.add(
        NaisteraModelInfo(
          id: id,
          name: (model['name'] ?? id).toString(),
          references: model['references'] != false,
          negativePrompt: model['negative_prompt'] == true,
        ),
      );
    }
    return catalog;
  }

  Future<Map<String, dynamic>> _pollJob(
    String jobId, {
    required String apiKey,
    CancelToken? cancelToken,
  }) async {
    final base = _generateUrl;
    final url = '$base/jobs/${Uri.encodeComponent(jobId)}';
    final deadline = DateTime.now().add(pollTimeout);

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      if (cancelToken?.isCancelled ?? false) {
        throw Exception('Naistera generation cancelled');
      }
      final json = await _http.getJson(
        url: url,
        apiKey: apiKey,
        cancelToken: cancelToken,
      );
      final rawStatus = json['status'];
      final status = (rawStatus is String ? rawStatus : '').toLowerCase();
      if (json['data_url'] is String || status == 'completed') return json;
      if (status == 'failed' || json['error'] != null) {
        final detail = json['detail'] ?? json['error'] ?? 'Unknown error';
        throw Exception('Naistera generation failed: $detail');
      }
    }
    throw Exception(
      'Naistera polling timed out after ${pollTimeout.inSeconds}s',
    );
  }

  Future<Uint8List> _bytesFrom(
    Map<String, dynamic> json, {
    CancelToken? cancelToken,
  }) async {
    final raw = json['data_url'];
    final dataUrl = raw is String ? raw : '';
    if (dataUrl.isEmpty) {
      throw Exception('No data_url in Naistera response');
    }
    if (dataUrl.startsWith('http://') || dataUrl.startsWith('https://')) {
      return ImageGenHttp.downloadImage(dataUrl, cancelToken: cancelToken);
    }
    return ImageGenHttp.base64ToBytes(ImageGenHttp.stripBase64Prefix(dataUrl));
  }
}
