import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/llm/transport/llm_capture_context.dart';
import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/services/image_storage_service.dart';
import '../../../core/utils/error_format.dart';
import '../image_gen_models.dart';
import 'image_gen_dispatcher.dart';
import 'image_prompt_builder.dart';
import 'image_reference_collector.dart';
import 'image_tag_markup.dart';
import 'reference_matcher.dart';

/// Turns `[IMG:GEN]` tags in a message into generated images.
///
/// Prompt assembly (style block, reference descriptions, critical reference
/// instruction) lives in [image_prompt_builder], reference collection in
/// [ImageReferenceCollector] and the provider calls in [ImageGenDispatcher].
class ImageGenService {
  ImageGenService(this._imageStorage);

  final ImageStorageService _imageStorage;
  final ImageReferenceCollector _references = const ImageReferenceCollector();
  final ImageGenDispatcher _dispatcher = const ImageGenDispatcher();

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
    if (!settings.enabled) {
      final disabledText = ImageTagMarkup.replaceAllImageGenTagsWithDisabled(
        text,
      );
      if (disabledText != text) onUpdate?.call(disabledText);
      return disabledText;
    }

    final instructions = ImageTagMarkup.extractImageGenInstructions(text);
    if (instructions.isEmpty) return text;

    String currentText = text;
    // A tag is "resolved" once it carries a result or an error token, which
    // takes it out of the pending set the next replacement indexes into.
    final resolved = List<bool>.filled(instructions.length, false);

    // Writes an outcome into the tag its instruction came from. Only that one
    // tag is rewritten: a failure leaves the block in place as a retryable
    // error card instead of dropping it, and the tags of the still-running
    // images stay pending.
    void applyOutcome(int index, _ImageOutcome outcome) {
      var pendingIndex = 0;
      for (var i = 0; i < index; i++) {
        if (!resolved[i]) pendingIndex++;
      }
      final updated = outcome.error == null
          ? ImageTagMarkup.replaceTagWithResult(
              currentText,
              pendingIndex,
              outcome.imagePath!,
            )
          : ImageTagMarkup.replaceTagWithError(
              currentText,
              pendingIndex,
              outcome.error!,
            );
      resolved[index] = true;
      if (updated == currentText) return;
      currentText = updated;
      onUpdate?.call(currentText);
    }

    Future<_ImageOutcome> run(Map<String, dynamic> instruction) => _runOne(
      instruction: instruction,
      settings: settings,
      llmEndpoint: llmEndpoint,
      llmApiKey: llmApiKey,
      llmModel: llmModel,
      character: character,
      persona: persona,
      recentImageContexts: recentImageContexts,
      cancelToken: cancelToken,
    );

    if (settings.concurrentGeneration) {
      // Every request is already in flight; awaiting them in order only fixes
      // the order the finished images are written back in.
      final inFlight = instructions.map(run).toList();
      for (var i = 0; i < inFlight.length; i++) {
        final outcome = await inFlight[i];
        if (outcome.cancelled) continue;
        applyOutcome(i, outcome);
        if (outcome.error != null) onError?.call(outcome.error!);
      }
      return currentText;
    }

    for (var i = 0; i < instructions.length; i++) {
      if (cancelToken?.isCancelled == true) break;
      final outcome = await run(instructions[i]);
      if (outcome.cancelled) break;
      applyOutcome(i, outcome);
      if (outcome.error != null) onError?.call(outcome.error!);
    }

    return currentText;
  }

  /// Generates and persists the image for a single instruction.
  ///
  /// Never throws: every failure comes back as [_ImageOutcome.failure] so the
  /// caller can turn it into an error card and keep going.
  Future<_ImageOutcome> _runOne({
    required Map<String, dynamic> instruction,
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    CancelToken? cancelToken,
  }) async {
    final rawPrompt = instruction['prompt'] as String? ?? '';
    if (rawPrompt.isEmpty) {
      return _ImageOutcome.failure('Image prompt is empty');
    }

    final prompt = rawPrompt.replaceFirst(RegExp(r'^SCENE_PROMPT:\s*'), '');

    try {
      final imageBytes = await generateImage(
        settings: settings,
        prompt: prompt,
        tagStyle: instruction['style'] as String?,
        llmEndpoint: llmEndpoint,
        llmApiKey: llmApiKey,
        llmModel: llmModel,
        character: character,
        persona: persona,
        recentImageContexts: recentImageContexts,
        instructionAspectRatio: instruction['aspect_ratio'] as String?,
        instructionImageSize: instruction['image_size'] as String?,
        cancelToken: cancelToken,
      );
      if (cancelToken?.isCancelled == true) return _ImageOutcome.cancelled();
      if (imageBytes.isEmpty) {
        return _ImageOutcome.failure('Provider returned no image data');
      }

      final savedPath = await _saveGeneratedImage(imageBytes);
      if (cancelToken?.isCancelled == true) return _ImageOutcome.cancelled();
      return _ImageOutcome.success(savedPath);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return _ImageOutcome.cancelled();
      return _ImageOutcome.failure(_formatError(e));
    } catch (e) {
      return _ImageOutcome.failure(_formatErrorString(e.toString()));
    }
  }

  /// Generates a single image for [prompt].
  ///
  /// [tagStyle] is the `style` field of the image tag; the active style from
  /// the style library overrides it, and with "no style" selected it is used
  /// as written.
  Future<Uint8List> generateImage({
    required ImageGenSettings settings,
    required String prompt,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    String? tagStyle,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
  }) async {
    final collected = await _references.collect(
      settings: settings,
      prompt: prompt,
      character: character,
      persona: persona,
      recentImageContexts: recentImageContexts,
    );

    final isNaistera = settings.apiType == ImageGenApiType.naistera;
    final descriptionsMode = isNaistera
        ? settings.naisteraCharacterDescriptionsMode
        : CharacterDescriptionsMode.asIs;

    // Outside "as-is" the avatars travel without their caption: the
    // descriptions are carried by the prompt block instead, so leaving them on
    // the images would send each one twice.
    final references = descriptionsMode == CharacterDescriptionsMode.asIs
        ? collected
        : _withoutAvatarDescriptions(collected);

    var finalPrompt = buildFinalGenerationPrompt(
      prompt: prompt,
      tagStyle: tagStyle,
      settings: settings,
      references: references,
      // NovelAI parses the whole prompt as tags — the [STYLE: ...] wrapper
      // would reach the sampler verbatim.
      wrapStyle:
          !(isNaistera &&
              NaisteraConstants.isNovelAIModel(settings.naisteraModel)),
    );
    if (isNaistera && settings.sendRefDescriptions) {
      finalPrompt = appendPromptBlock(
        finalPrompt,
        buildCharacterDescriptionPromptBlock(
          mode: descriptionsMode,
          references: references,
          charDescription: _appearanceOf(character?.name, settings),
          userDescription: _appearanceOf(persona?.name, settings),
        ),
      );
    }
    finalPrompt = withReferenceInstruction(
      finalPrompt,
      settings,
      hasReferences: references.isNotEmpty,
    );

    return _dispatcher.generate(
      settings: settings,
      prompt: finalPrompt,
      references: references,
      llmEndpoint: llmEndpoint,
      llmApiKey: llmApiKey,
      instructionAspectRatio: instructionAspectRatio,
      instructionImageSize: instructionImageSize,
      cancelToken: cancelToken,
      captureContext: captureContext,
    );
  }

  /// Appearance blurb for a character or persona: the description of the
  /// reference-library entry whose aliases name them. Glaze has no separate
  /// appearance field, and a library entry is exactly where a user writes one.
  static String _appearanceOf(String? name, ImageGenSettings settings) {
    final target = normalizeTriggerText(name ?? '');
    if (target.isEmpty) return '';
    for (final ref in settings.references) {
      if (!ref.enabled) continue;
      if (!parseReferenceAliases(ref.name).contains(target)) continue;
      final description = ref.description.trim();
      if (description.isNotEmpty) return description;
    }
    return '';
  }

  static List<Map<String, String>> _withoutAvatarDescriptions(
    List<Map<String, String>> references,
  ) {
    return references.map((ref) {
      final source = ref['source'];
      if (source != 'char' && source != 'user') return ref;
      return {...ref, 'description': ''};
    }).toList();
  }

  /// Delegates to the shared [formatError] — the same helper the chat and the
  /// ext blocks use — so a failed image generation reads like every other
  /// provider failure (localized status line, provider message on its own
  /// line) instead of a Dio dump. The length cap stays: this string is
  /// rendered inline in the message card.
  String _formatError(DioException e) => _formatErrorString(formatError(e));

  String _formatErrorString(String msg) {
    if (msg.length > 200) msg = '${msg.substring(0, 197)}...';
    return msg;
  }

  Future<String> _saveGeneratedImage(Uint8List bytes) async {
    final dir = Directory(p.join(_imageStorage.baseDir, 'generated'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final extension = imageExtensionForBytes(bytes);
    // Concurrent generations can land inside the same microsecond, so the
    // counter — not the clock alone — is what keeps the names unique.
    final name = 'imggen_${DateTime.now().microsecondsSinceEpoch}_$_saveSeq';
    _saveSeq++;
    final path = p.join(dir.path, '$name.$extension');
    await File(path).writeAsBytes(bytes);
    // Stored relative to the Glaze data root, never as the absolute path it
    // was just written to: the root moves under an installed app (a new iOS
    // container UUID, a database carried between desktop build channels) and
    // an absolute path silently stops pointing at a file, while a relative one
    // is re-joined onto the current root by resolveGlazeFilePath.
    return p.url.join('generated', '$name.$extension');
  }

  static int _saveSeq = 0;
}

/// Result of one image request: a saved file, a message for the error card, or
/// a cancellation that leaves the tag pending for the caller to resolve.
class _ImageOutcome {
  const _ImageOutcome._({this.imagePath, this.error, this.cancelled = false});

  factory _ImageOutcome.success(String imagePath) =>
      _ImageOutcome._(imagePath: imagePath);
  factory _ImageOutcome.failure(String error) => _ImageOutcome._(error: error);
  factory _ImageOutcome.cancelled() => const _ImageOutcome._(cancelled: true);

  final String? imagePath;
  final String? error;
  final bool cancelled;
}
