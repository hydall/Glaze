import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../../core/services/image_storage_service.dart';
import '../../../core/utils/platform_paths.dart';
import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import 'image_tag_markup.dart';
import 'naistera_image_provider.dart';
import 'openai_image_provider.dart';
import 'gemini_image_provider.dart';
import 'routmy_image_provider.dart';
import '../image_gen_models.dart';

class ImageGenService {
  final ImageStorageService _imageStorage;

  ImageGenService(this._imageStorage);

  Future<String> processMessageImages({
    required String text,
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    CancelToken? cancelToken,
    void Function(String updatedText)? onUpdate,
    void Function(String error)? onError,
  }) async {
    if (!settings.enabled) return text;

    final instructions = ImageTagMarkup.extractImageGenInstructions(text);
    if (instructions.isEmpty) return text;

    String currentText = text;

    for (int i = 0; i < instructions.length; i++) {
      if (cancelToken?.isCancelled == true) break;

      final instruction = instructions[i];
      final rawPrompt = instruction['prompt'] as String? ?? '';

      if (rawPrompt.isEmpty) {
        currentText = ImageTagMarkup.replaceTagWithError(
          currentText,
          0,
          'Image prompt is empty',
        );
        onUpdate?.call(currentText);
        onError?.call('Image prompt is empty');
        continue;
      }

      final style = instruction['style'] as String? ?? '';
      var cleanPrompt = rawPrompt.replaceFirst(
        RegExp(r'^SCENE_PROMPT:\s*'),
        '',
      );
      final prompt = style.isNotEmpty ? '$style, $cleanPrompt' : cleanPrompt;
      final instructionAspectRatio = instruction['aspect_ratio'] as String?;
      final instructionImageSize = instruction['image_size'] as String?;

      try {
        final imageBytes = await generateImage(
          settings: settings,
          prompt: prompt,
          llmEndpoint: llmEndpoint,
          llmApiKey: llmApiKey,
          llmModel: llmModel,
          character: character,
          persona: persona,
          recentImageContexts: recentImageContexts,
          instructionAspectRatio: instructionAspectRatio,
          instructionImageSize: instructionImageSize,
          cancelToken: cancelToken,
        );
        if (cancelToken?.isCancelled == true) break;

        final filename = 'imggen_${DateTime.now().microsecondsSinceEpoch}.png';
        final savedPath = await _saveGeneratedImage(filename, imageBytes);
        if (cancelToken?.isCancelled == true) break;

        currentText = ImageTagMarkup.replaceTagWithResult(
          currentText,
          0,
          savedPath,
        );
        onUpdate?.call(currentText);
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) break;
        final errorMsg = _formatError(e);
        currentText = ImageTagMarkup.replaceTagWithError(
          currentText,
          0,
          errorMsg,
        );
        onUpdate?.call(currentText);
        onError?.call(errorMsg);
      } catch (e) {
        final errorMsg = _formatErrorString(e.toString());
        currentText = ImageTagMarkup.replaceTagWithError(
          currentText,
          0,
          errorMsg,
        );
        onUpdate?.call(currentText);
        onError?.call(errorMsg);
      }
    }

    return currentText;
  }

  String _formatError(DioException e) {
    final data = e.response?.data;
    String? responseMessage;
    if (data is Map) {
      final error = data['error'];
      if (error is Map) {
        responseMessage = error['message']?.toString();
      } else if (error != null) {
        responseMessage = error.toString();
      }
      responseMessage ??= data['message']?.toString();
      responseMessage ??= data['detail']?.toString();
    } else if (data != null) {
      responseMessage = data.toString();
    }
    final status = e.response?.statusCode;
    final msg = responseMessage?.trim().isNotEmpty == true
        ? [if (status != null) 'HTTP $status', responseMessage!].join(': ')
        : status != null
        ? [
            'HTTP $status',
            if (e.response?.statusMessage?.trim().isNotEmpty == true)
              e.response!.statusMessage!.trim(),
          ].join(': ')
        : e.message ?? e.toString();
    return _formatErrorString(msg);
  }

  String _formatErrorString(String msg) {
    if (msg.length > 200) msg = '${msg.substring(0, 197)}...';
    return msg;
  }

  Future<Uint8List> generateImage({
    required ImageGenSettings settings,
    required String prompt,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  }) async {
    final isRoutmy =
        settings.apiType == ImageGenApiType.routmy ||
        settings.apiType == ImageGenApiType.ruRoutmy;
    final refs = isRoutmy
        ? await _buildRoutmyRefs(
            settings: settings,
            prompt: prompt,
            character: character,
            persona: persona,
            recentImageContexts: recentImageContexts,
          )
        : _buildReferences(
            settings: settings,
            prompt: prompt,
            character: character,
            persona: persona,
            recentImageContexts: recentImageContexts,
          );
    final injectedRefs = refs.take(routmyMaxInjectedReferenceImages).toList();
    final referenceAwarePrompt = isRoutmy
        ? imagePromptWithReferenceLabels(prompt, injectedRefs)
        : prompt;
    switch (settings.apiType) {
      case ImageGenApiType.openai:
        return _generateOpenai(
          settings,
          prompt,
          llmEndpoint,
          llmApiKey,
          cancelToken,
        );
      case ImageGenApiType.gemini:
        return _generateGemini(
          settings,
          prompt,
          llmEndpoint,
          llmApiKey,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken,
        );
      case ImageGenApiType.naistera:
        return _generateNaistera(
          settings,
          prompt,
          refs,
          instructionAspectRatio,
          cancelToken,
        );
      case ImageGenApiType.routmy:
        return _generateRoutmy(
          settings,
          referenceAwarePrompt,
          injectedRefs,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken,
        );
      case ImageGenApiType.ruRoutmy:
        return _generateRuRoutmy(
          settings,
          referenceAwarePrompt,
          injectedRefs,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken,
        );
    }
  }

  Future<Uint8List> _generateOpenai(
    ImageGenSettings settings,
    String prompt,
    String llmEndpoint,
    String llmApiKey,
    CancelToken? cancelToken,
  ) async {
    final endpoint = settings.useSameEndpoint
        ? llmEndpoint
        : settings.customEndpoint;
    final apiKey = settings.useSameEndpoint ? llmApiKey : settings.customApiKey;
    final model = settings.useSameEndpoint
        ? 'dall-e-3'
        : (settings.customModel.isEmpty ? 'dall-e-3' : settings.customModel);

    return OpenaiImageProvider().generate(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
      prompt: prompt,
      size: settings.openaiSize,
      quality: settings.openaiQuality,
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _generateGemini(
    ImageGenSettings settings,
    String prompt,
    String llmEndpoint,
    String llmApiKey,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  ) async {
    final endpoint = settings.useSameEndpoint
        ? llmEndpoint
        : settings.customEndpoint;
    final apiKey = settings.useSameEndpoint ? llmApiKey : settings.customApiKey;
    final model = settings.useSameEndpoint
        ? 'imagen-3.0-generate-002'
        : (settings.customModel.isEmpty
              ? 'imagen-3.0-generate-002'
              : settings.customModel);

    return GeminiImageProvider().generate(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
      prompt: prompt,
      aspectRatio: _validOverride(
        instructionAspectRatio,
        GeminiConstants.aspectRatios,
        settings.geminiAspectRatio,
      ),
      imageSize: _validOverride(
        instructionImageSize,
        GeminiConstants.imageSizes,
        settings.geminiImageSize,
      ),
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _generateNaistera(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> refs,
    String? instructionAspectRatio,
    CancelToken? cancelToken,
  ) async {
    return NaisteraImageProvider().generate(
      apiKey: settings.naisteraApiKey,
      model: settings.naisteraModel,
      prompt: prompt,
      aspectRatio: _validOverride(
        instructionAspectRatio,
        NaisteraConstants.aspectRatios,
        settings.naisteraAspectRatio,
      ),
      references: refs.isNotEmpty ? refs : null,
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _generateRoutmy(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> refs,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  ) async {
    return RoutmyImageProvider(baseUrl: RoutMyConstants.baseUrl).generate(
      apiKey: settings.routmyApiKey,
      model: settings.routmyModel,
      prompt: prompt,
      aspectRatio: _validOverride(
        instructionAspectRatio,
        RoutMyConstants.aspectRatios,
        settings.routmyAspectRatio,
      ),
      imageSize: _validOverride(
        instructionImageSize,
        RoutMyConstants.imageSizes,
        settings.routmyImageSize,
      ),
      quality: settings.routmyQuality,
      referenceImages: refs.isNotEmpty
          ? refs.map((r) => r['image']!).where((s) => s.isNotEmpty).toList()
          : null,
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _generateRuRoutmy(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> refs,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  ) async {
    return RoutmyImageProvider(baseUrl: RuRoutMyConstants.baseUrl).generate(
      apiKey: settings.ruRoutmyApiKey,
      model: settings.ruRoutmyModel,
      prompt: prompt,
      aspectRatio: _validOverride(
        instructionAspectRatio,
        RuRoutMyConstants.aspectRatios,
        settings.ruRoutmyAspectRatio,
      ),
      imageSize: _validOverride(
        instructionImageSize,
        RuRoutMyConstants.imageSizes,
        settings.ruRoutmyImageSize,
      ),
      quality: settings.ruRoutmyQuality,
      referenceImages: refs.isNotEmpty
          ? refs.map((r) => r['image']!).where((s) => s.isNotEmpty).toList()
          : null,
      cancelToken: cancelToken,
    );
  }

  List<Map<String, String>> _buildReferences({
    required ImageGenSettings settings,
    required String prompt,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
  }) {
    final refs = <Map<String, String>>[];
    final promptLower = prompt.toLowerCase();

    if (settings.apiType == ImageGenApiType.naistera) {
      if (settings.naisteraSendCharAvatar && character?.avatarPath != null) {
        refs.add({
          'name': character!.name,
          'image': _fileToBase64(character.avatarPath!),
        });
      }
      if (settings.naisteraSendUserAvatar && persona?.avatarPath != null) {
        refs.add({
          'name': persona!.name,
          'image': _fileToBase64(persona.avatarPath!),
        });
      }
      for (final ref in settings.additionalReferences) {
        final name = ref.name.trim();
        final triggers = _referenceTriggers(name);
        if (ref.imageData.isNotEmpty &&
            (ref.matchMode == 'always' || triggers.any(promptLower.contains))) {
          refs.add({
            'name': name,
            'image': _extractBase64FromDataUrl(ref.imageData),
          });
        }
      }
    }

    // routmy / ruRoutmy refs are built asynchronously (resized) — see _buildRoutmyRefs

    if (settings.imageContextEnabled && recentImageContexts != null) {
      final count = settings.imageContextCount.clamp(1, 3);
      for (final ctx in recentImageContexts.take(count)) {
        final path = ImageTagMarkup.normalizeImageResultPayload(ctx);
        final encoded = _fileToBase64(path);
        if (encoded.isNotEmpty) {
          refs.add({'name': 'context', 'image': encoded});
        }
      }
    }

    return refs;
  }

  /// Async variant of [_buildReferences] for routmy/ruRoutmy.
  /// Resizes avatar/context images to 512px before base64-encoding so that
  /// the JSON payload stays within provider limits.
  Future<List<Map<String, String>>> _buildRoutmyRefs({
    required ImageGenSettings settings,
    required String prompt,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
  }) async {
    final refs = <Map<String, String>>[];
    final promptLower = prompt.toLowerCase();
    final isRu = settings.apiType == ImageGenApiType.ruRoutmy;

    final sendChar = isRu
        ? settings.ruRoutmySendCharAvatar
        : settings.routmySendCharAvatar;
    final sendUser = isRu
        ? settings.ruRoutmySendUserAvatar
        : settings.routmySendUserAvatar;

    if (sendChar && character?.avatarPath != null) {
      final img = await _fileToBase64Resized(character!.avatarPath!);
      if (img.isNotEmpty) refs.add({'name': character.name, 'image': img});
    }
    if (sendUser && persona?.avatarPath != null) {
      final img = await _fileToBase64Resized(persona!.avatarPath!);
      if (img.isNotEmpty) refs.add({'name': persona.name, 'image': img});
    }
    for (final ref in settings.routmyAdditionalRefs) {
      final name = ref.name.trim();
      final triggers = _referenceTriggers(name);
      if (ref.imageData.isNotEmpty &&
          (ref.matchMode == 'always' || triggers.any(promptLower.contains))) {
        final raw = _extractBase64FromDataUrl(ref.imageData);
        if (raw.isNotEmpty) refs.add({'name': name, 'image': raw});
      }
    }

    if (settings.imageContextEnabled && recentImageContexts != null) {
      final count = settings.imageContextCount.clamp(1, 3);
      for (final ctx in recentImageContexts.take(count)) {
        final path = ImageTagMarkup.normalizeImageResultPayload(ctx);
        final encoded = await _fileToBase64Resized(path);
        if (encoded.isNotEmpty) refs.add({'name': 'context', 'image': encoded});
      }
    }

    return refs;
  }

  List<String> _referenceTriggers(String value) => value
      .split(',')
      .map((trigger) => trigger.trim().toLowerCase())
      .where((trigger) => trigger.isNotEmpty)
      .toList();

  String _validOverride(
    String? override,
    List<String> allowed,
    String fallback,
  ) {
    final value = override?.trim();
    return value != null && allowed.contains(value) ? value : fallback;
  }

  String _fileToBase64(String path) {
    try {
      final resolved = resolveGlazeFilePath(path) ?? path;
      final file = File(resolved);
      if (!file.existsSync()) return '';
      return base64Encode(file.readAsBytesSync());
    } catch (_) {
      return '';
    }
  }

  /// Reads an image file, resizes so the longest side ≤ [maxSide] px,
  /// re-encodes as JPEG at [jpegQuality] (0–100), and returns bare base64.
  /// Falls back to the raw file bytes on any error.
  Future<String> _fileToBase64Resized(
    String path, {
    int maxSide = 512,
    int jpegQuality = 85,
  }) async {
    try {
      final resolved = resolveGlazeFilePath(path) ?? path;
      final file = File(resolved);
      if (!file.existsSync()) return '';
      final bytes = file.readAsBytesSync();

      final decoded = await compute(
        _decodeAndResizeJpeg,
        _ResizeArgs(bytes, maxSide, jpegQuality),
      );
      if (decoded == null) return base64Encode(bytes);
      return base64Encode(decoded);
    } catch (_) {
      return _fileToBase64(path);
    }
  }

  String _extractBase64FromDataUrl(String dataUrl) {
    final commaIndex = dataUrl.indexOf(',');
    if (commaIndex == -1) return dataUrl;
    return dataUrl.substring(commaIndex + 1);
  }

  Future<String> _saveGeneratedImage(String filename, Uint8List bytes) async {
    final dir = Directory(p.join(_imageStorage.baseDir, 'generated'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final extension = imageExtensionForBytes(bytes);
    final path = p.join(
      dir.path,
      '${p.basenameWithoutExtension(filename)}.$extension',
    );
    await File(path).writeAsBytes(bytes);
    return path;
  }
}

String imagePromptWithReferenceLabels(
  String prompt,
  List<Map<String, String>> references,
) {
  if (references.isEmpty) return prompt;
  final labels = <String>[];
  for (var i = 0; i < references.length; i++) {
    final rawName = references[i]['name']?.trim() ?? '';
    if (rawName.isEmpty || rawName == 'context') continue;
    final name = rawName
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .replaceAll('"', "'");
    labels.add('Reference image ${i + 1} shows "$name".');
  }
  if (labels.isEmpty) return prompt;
  return '${labels.join(' ')} Preserve these exact identities and assign each '
      'person the role and position stated in the prompt.\n\n$prompt';
}

// ─── Isolate helpers for JPEG resize ────────────────────────────────────────

class _ResizeArgs {
  const _ResizeArgs(this.bytes, this.maxSide, this.jpegQuality);
  final Uint8List bytes;
  final int maxSide;
  final int jpegQuality;
}

/// Runs in a separate isolate via [compute]. Decodes the image, resizes to fit
/// within [args.maxSide] px on the longest side, and encodes as JPEG.
/// Returns null on any error so the caller can fall back to the raw bytes.
Uint8List? _decodeAndResizeJpeg(_ResizeArgs args) {
  try {
    final src = img.decodeImage(args.bytes);
    if (src == null) return null;
    final resized = img.copyResize(
      src,
      width: src.width >= src.height ? args.maxSide : -1,
      height: src.height > src.width ? args.maxSide : -1,
      interpolation: img.Interpolation.linear,
    );
    return Uint8List.fromList(
      img.encodeJpg(resized, quality: args.jpegQuality),
    );
  } catch (_) {
    return null;
  }
}
