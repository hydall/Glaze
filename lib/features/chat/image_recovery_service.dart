import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/image_gen_patterns.dart';
import '../../core/models/chat_message.dart';
import '../../core/state/db_provider.dart';
import '../../core/utils/platform_paths.dart';
import '../../core/utils/time_helpers.dart';
import '../image_gen/services/image_tag_markup.dart';
import 'services/image_gen_processor.dart';
import 'chat_generation_service.dart';
import 'chat_session_service.dart';
import 'chat_state.dart';

class ImageRecoveryService {
  final Ref _ref;
  final String _charId;
  final void Function(CancelToken?) _setImgGenCancelToken;
  final CancelToken? Function() getImgGenCancelToken;
  final int Function() startImageOperation;
  final bool Function(int genId) isCurrentGeneration;
  final void Function(AsyncValue<ChatState>) _setState;
  final AsyncValue<ChatState> Function() _getState;

  ImageRecoveryService({
    required this._ref,
    required this._charId,
    required this._setImgGenCancelToken,
    required this.getImgGenCancelToken,
    required this.startImageOperation,
    required this.isCurrentGeneration,
    required this._setState,
    required this._getState,
  });

  static ChatSession fixupSwipesWithImageResults(ChatSession session) {
    bool changed = false;
    final messages = List<ChatMessage>.from(session.messages);
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      var currentMsg = msg;

      if (msg.swipes.isNotEmpty) {
        final swipeIdx = msg.swipeId;
        if (swipeIdx >= 0 &&
            swipeIdx < msg.swipes.length &&
            msg.content != msg.swipes[swipeIdx]) {
          final fixedSwipes = List<String>.from(msg.swipes);
          fixedSwipes[swipeIdx] = msg.content;
          currentMsg = msg.copyWith(swipes: fixedSwipes);
          changed = true;
        }
      }

      final cleanedContent = cleanStuckImgGenTags(currentMsg.content);
      if (cleanedContent != currentMsg.content) {
        currentMsg = currentMsg.copyWith(content: cleanedContent);
        changed = true;
      }

      if (currentMsg.swipes.isNotEmpty) {
        final fixedSwipes = List<String>.from(currentMsg.swipes);
        bool swipesChanged = false;
        for (int s = 0; s < fixedSwipes.length; s++) {
          final cleaned = cleanStuckImgGenTags(fixedSwipes[s]);
          if (cleaned != fixedSwipes[s]) {
            fixedSwipes[s] = cleaned;
            swipesChanged = true;
          }
        }
        if (swipesChanged) {
          currentMsg = currentMsg.copyWith(swipes: fixedSwipes);
          changed = true;
        }
      }

      final alignedMsg = ImageGenProcessor.replaceActiveImageContent(
        currentMsg,
        currentMsg.content,
      );
      if (jsonEncode(alignedMsg.toJson()) != jsonEncode(currentMsg.toJson())) {
        currentMsg = alignedMsg;
        changed = true;
      }

      final cleanedAgentSwipes = currentMsg.agentSwipes
          .map(
            (swipe) =>
                swipe.copyWith(content: cleanStuckImgGenTags(swipe.content)),
          )
          .toList();
      final cleanedMeta = currentMsg.swipesMeta.map((entry) {
        final meta = Map<String, dynamic>.from(entry);
        final stored = meta['agentSwipes'];
        if (stored is List) {
          meta['agentSwipes'] = stored.map((value) {
            if (value is! Map) return value;
            final swipe = Map<String, dynamic>.from(value);
            final content = swipe['content'];
            if (content is String) {
              swipe['content'] = cleanStuckImgGenTags(content);
            }
            return swipe;
          }).toList();
        }
        return meta;
      }).toList();
      if (!_agentSwipeListsEqual(cleanedAgentSwipes, currentMsg.agentSwipes) ||
          !_metaListsEqual(cleanedMeta, currentMsg.swipesMeta)) {
        currentMsg = currentMsg.copyWith(
          agentSwipes: cleanedAgentSwipes,
          swipesMeta: cleanedMeta,
        );
        changed = true;
      }

      messages[i] = currentMsg;
    }
    if (!changed) return session;
    return session.copyWith(messages: messages);
  }

  static bool _agentSwipeListsEqual(List<AgentSwipe> a, List<AgentSwipe> b) =>
      jsonEncode(a.map((swipe) => swipe.toJson()).toList()) ==
      jsonEncode(b.map((swipe) => swipe.toJson()).toList());

  static bool _metaListsEqual(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) => jsonEncode(a) == jsonEncode(b);

  static String cleanStuckImgGenTags(String text) {
    if (!ImgGenPatterns.imgGenRegex.hasMatch(text) &&
        !ImgGenPatterns.htmlIigTagRegex.hasMatch(text) &&
        !ImgGenPatterns.htmlIigTagDoubleRegex.hasMatch(text) &&
        !ImgGenPatterns.imgSrcGenRegex.hasMatch(text)) {
      return text;
    }
    var result = text;
    result = result.replaceAll(
      ImgGenPatterns.imgSrcGenRegex,
      '[IMG:ERROR:${jsonEncode({'error': 'Generation interrupted'})}]',
    );
    // Only elements still waiting for a picture; the same element with an
    // image in its `src` is a finished block, which an interrupted generation
    // must never turn into an error card.
    String interrupted(Match m) {
      if (!ImgGenPatterns.isPendingIigElement(m.group(0)!)) return m.group(0)!;
      final errorJson = jsonEncode({
        'error': 'Generation interrupted',
        'instruction': m.group(1) ?? '',
      });
      return '[IMG:ERROR:$errorJson]';
    }

    result = result.replaceAllMapped(
      ImgGenPatterns.htmlIigTagRegex,
      interrupted,
    );
    result = result.replaceAllMapped(
      ImgGenPatterns.htmlIigTagDoubleRegex,
      interrupted,
    );
    result = result.replaceAllMapped(ImgGenPatterns.imgGenRegex, (m) {
      final instruction = m.group(1) ?? '';
      final errorJson = instruction.isNotEmpty
          ? jsonEncode({
              'error': 'Generation interrupted',
              'instruction': instruction,
            })
          : jsonEncode({'error': 'Generation interrupted'});
      return '[IMG:ERROR:$errorJson]';
    });
    return result;
  }

  static String replaceFirstImgErrorOrGen(String text, String resultPath) {
    final replacement = ImageTagMarkup.encodeResultElement(
      ImageBlockPayload(paths: [resultPath]),
    );
    if (ImgGenPatterns.imgErrorRegex.hasMatch(text)) {
      return text.replaceFirst(ImgGenPatterns.imgErrorRegex, replacement);
    }
    if (ImgGenPatterns.imgGenHtmlRegex.hasMatch(text)) {
      return text.replaceFirst(ImgGenPatterns.imgGenHtmlRegex, replacement);
    }
    if (text.contains('[IMG:GEN]')) {
      return text.replaceFirst('[IMG:GEN]', replacement);
    }
    if (ImgGenPatterns.imgGenRegex.hasMatch(text)) {
      return text.replaceFirst(ImgGenPatterns.imgGenRegex, replacement);
    }
    return text;
  }

  /// Turns only the failed blocks back into pending tags, leaving the images
  /// that did arrive in place. This is what the error card's regenerate button
  /// runs: retrying one block must not throw away its finished siblings.
  /// Only the failed blocks go back to pending; finished images stay.
  static String resetImgErrorTagsToGen(String text) =>
      ImageTagMarkup.resetImageErrorTags(text);

  /// Every block of the message goes back to pending, keeping its prompt and
  /// the images it already holds.
  static String resetImgTagsToGen(String text) =>
      ImageTagMarkup.resetErrorTags(text);

  /// A regeneration carries forward only the images that are still on disk.
  ///
  /// A path that names no file can do nothing but render as a broken picture
  /// and pad the block's switcher, and a regeneration is the one moment the
  /// block is rewritten anyway — so this is where such a path is dropped
  /// instead of being carried through yet another attempt.
  static String dropMissingImages(String text) =>
      ImageTagMarkup.dropCarriedImages(text, imageFileExists);

  /// Whether an image a block carries can still be shown. Only local files can
  /// go missing; a data URL or a remote picture is taken at its word.
  static bool imageFileExists(String path) {
    if (path.isEmpty) return false;
    if (path.startsWith('data:') ||
        path.startsWith('http://') ||
        path.startsWith('https://')) {
      return true;
    }
    return File(resolveGlazeFilePath(path) ?? path).existsSync();
  }

  /// Puts another image of one block on screen — the block-level counterpart
  /// of a message swipe.
  ///
  /// The page has already swapped the picture when this arrives, so the write
  /// only has to make the choice durable: the active swipe of the message is
  /// rewritten in place, exactly like a regeneration does, and no swipe is
  /// added for it.
  Future<void> selectImageVariant(
    String messageId,
    int blockIndex,
    int variantIndex,
  ) async {
    final current = _getState().value;
    final session = current?.session;
    if (current == null || session == null) return;

    final message = session.messages.firstWhereOrNull((m) => m.id == messageId);
    if (message == null || message.role != 'assistant') return;
    if (ImageTagMarkup.setImageBlockVariant(
          message.content,
          blockIndex,
          variantIndex,
        ) ==
        message.content) {
      return;
    }

    final updated = await _ref
        .read(chatRepoProvider)
        .mutateMessage(
          sessionId: session.id,
          messageId: messageId,
          updatedAt: currentTimestampSeconds(),
          mutate: (stored) {
            if (stored.role != 'assistant') return null;
            final content = ImageTagMarkup.setImageBlockVariant(
              stored.content,
              blockIndex,
              variantIndex,
            );
            if (content == stored.content) return null;
            return ImageGenProcessor.replaceActiveImageContent(stored, content);
          },
        );
    if (updated == null) return;
    ChatSessionService.updateCache(updated);
    final liveState = _getState().value;
    if (liveState == null || liveState.session?.id != updated.id) return;
    _setState(AsyncData(liveState.copyWith(session: updated)));
  }

  Future<void> retryImageGeneration() async {
    final current = _getState().value;
    if (current == null ||
        current.session == null ||
        current.isGenerating ||
        current.isPostGenRunning ||
        current.isGeneratingImage) {
      return;
    }

    final session = current.session!;
    final lastIdx = session.messages.length - 1;
    if (lastIdx < 0) return;
    final lastMsg = session.messages[lastIdx];
    if (lastMsg.role != 'assistant') return;

    final hasRetryableContent =
        ImageTagMarkup.hasImageGenTags(lastMsg.content) ||
        lastMsg.content.contains('[IMG:ERROR:') ||
        lastMsg.content.contains('[IMG:RESULT:') ||
        ImageTagMarkup.scanResultElements(lastMsg.content).isNotEmpty;
    if (!hasRetryableContent) return;

    final resetContent = dropMissingImages(resetImgTagsToGen(lastMsg.content));
    if (resetContent == lastMsg.content &&
        !ImageTagMarkup.hasImageGenTags(resetContent)) {
      return;
    }

    final resetSession = await _ref
        .read(chatRepoProvider)
        .mutateMessage(
          sessionId: session.id,
          messageId: lastMsg.id,
          updatedAt: currentTimestampSeconds(),
          mutate: (message) {
            if (message.role != 'assistant') return null;
            final content = dropMissingImages(
              resetImgTagsToGen(message.content),
            );
            if (content == message.content &&
                !ImageTagMarkup.hasImageGenTags(content)) {
              return null;
            }
            return ImageGenProcessor.resetImageContentInPlace(
              message,
              content,
            );
          },
        );
    if (resetSession == null) return;
    ChatSessionService.updateCache(resetSession);
    final liveState = _getState().value;
    if (liveState?.session?.id != resetSession.id) return;
    final genId = startImageOperation();
    final imgCancelToken = CancelToken();
    _setImgGenCancelToken(imgCancelToken);
    _setState(
      AsyncData(
        liveState!.copyWith(session: resetSession, isGeneratingImage: true),
      ),
    );

    final sessionId = resetSession.id;
    bool ownsOperation() =>
        isCurrentGeneration(genId) &&
        identical(getImgGenCancelToken(), imgCancelToken);
    void mergeUpdate(ChatState update) {
      final merged = ImageGenProcessor.mergeOwnedStateUpdate(
        liveState: _getState().value,
        update: update,
        sessionId: sessionId,
        targetMessageId: lastMsg.id,
        ownsOperation: ownsOperation(),
      );
      if (merged != null) _setState(AsyncData(merged));
    }

    try {
      final genService = _ref.read(chatGenerationServiceProvider);
      await genService.processImageTags(
        currentState: current.copyWith(
          session: resetSession,
          isGeneratingImage: true,
        ),
        charId: _charId,
        targetMessageId: lastMsg.id,
        cancelToken: imgCancelToken,
        isCurrentOperation: ownsOperation,
        onStateUpdate: mergeUpdate,
      );
    } finally {
      final wasOwner = ownsOperation();
      if (identical(getImgGenCancelToken(), imgCancelToken)) {
        _setImgGenCancelToken(null);
      }
      final liveState = _getState().value;
      if (wasOwner && liveState != null) {
        _setState(AsyncData(liveState.copyWith(isGeneratingImage: false)));
      }
    }
  }

  /// Regenerates the image blocks of [messageId].
  ///
  /// [blockIndex] narrows the work to a single image — the block the user
  /// tapped — leaving every other image of the message alone. Without it,
  /// [failedOnly] still restricts the reset to the blocks that failed, and
  /// with neither the whole message is generated again.
  Future<void> retryImageGenerationForMessage(
    String messageId, {
    bool failedOnly = false,
    int? blockIndex,
  }) async {
    String reset(String content) {
      final pending = blockIndex != null
          ? ImageTagMarkup.resetImageBlockAt(content, blockIndex)
          : failedOnly
          ? resetImgErrorTagsToGen(content)
          : resetImgTagsToGen(content);
      // An unchanged text is the caller's "nothing to do" signal, so the
      // pruning below must not be what makes this look like a change.
      if (pending == content) return content;
      return dropMissingImages(pending);
    }

    var current = _getState().value;
    if (current == null || current.session == null || current.isGenerating) {
      return;
    }

    // The error card appears before the originating post-gen operation has
    // fully unwound. Queue an immediate tap instead of silently dropping it.
    final originalSessionId = current.session!.id;
    while (current != null &&
        current.session?.id == originalSessionId &&
        (current.isGeneratingImage || current.isPostGenRunning)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      current = _getState().value;
      if (current?.isGenerating == true) return;
    }
    if (current == null ||
        current.session == null ||
        current.session!.id != originalSessionId ||
        current.isGenerating ||
        current.isPostGenRunning ||
        current.isGeneratingImage) {
      return;
    }
    final messageIndex = current.messages.indexWhere((m) => m.id == messageId);
    if (messageIndex < 0 || messageIndex >= current.messages.length) return;

    final msg = current.messages[messageIndex];
    if (msg.role != 'assistant') return;

    final resetContent = reset(msg.content);
    if (resetContent == msg.content) return;

    final resetSession = await _ref
        .read(chatRepoProvider)
        .mutateMessage(
          sessionId: current.session!.id,
          messageId: msg.id,
          updatedAt: currentTimestampSeconds(),
          mutate: (message) {
            if (message.role != 'assistant') return null;
            final content = reset(message.content);
            if (content == message.content) return null;
            return ImageGenProcessor.resetImageContentInPlace(
              message,
              content,
            );
          },
        );
    if (resetSession == null) return;
    ChatSessionService.updateCache(resetSession);
    final liveState = _getState().value;
    if (liveState?.session?.id != resetSession.id) return;

    final genId = startImageOperation();
    final imgCancelToken = CancelToken();
    _setImgGenCancelToken(imgCancelToken);
    _setState(
      AsyncData(
        liveState!.copyWith(session: resetSession, isGeneratingImage: true),
      ),
    );

    final sessionId = resetSession.id;
    bool ownsOperation() =>
        isCurrentGeneration(genId) &&
        identical(getImgGenCancelToken(), imgCancelToken);
    void mergeUpdate(ChatState update) {
      final merged = ImageGenProcessor.mergeOwnedStateUpdate(
        liveState: _getState().value,
        update: update,
        sessionId: sessionId,
        targetMessageId: msg.id,
        ownsOperation: ownsOperation(),
      );
      if (merged != null) _setState(AsyncData(merged));
    }

    try {
      final genService = _ref.read(chatGenerationServiceProvider);
      await genService.processImageTags(
        currentState: current.copyWith(
          session: resetSession,
          isGeneratingImage: true,
        ),
        charId: _charId,
        targetMessageId: msg.id,
        cancelToken: imgCancelToken,
        isCurrentOperation: ownsOperation,
        onStateUpdate: mergeUpdate,
      );
    } finally {
      final wasOwner = ownsOperation();
      if (identical(getImgGenCancelToken(), imgCancelToken)) {
        _setImgGenCancelToken(null);
      }
      final liveState = _getState().value;
      if (wasOwner && liveState != null) {
        _setState(AsyncData(liveState.copyWith(isGeneratingImage: false)));
      }
    }
  }

  /// Attaches an orphaned file from the generated folder to a block that has
  /// no image. [blockIndex] targets the block the user tapped; without it the
  /// first block still waiting for an image is used.
  Future<void> findImageOnDisk(
    String messageId,
    String instruction, {
    int? blockIndex,
  }) async {
    String attach(String content, String path) => blockIndex != null
        ? ImageTagMarkup.replaceImageBlockWithResult(content, blockIndex, path)
        : replaceFirstImgErrorOrGen(content, path);

    final current = _getState().value;
    if (current == null || current.session == null) return;

    final msgIdx = current.messages.indexWhere((m) => m.id == messageId);
    if (msgIdx < 0) return;

    final imageStorage = await _ref.read(imageStorageProvider.future);
    final generatedDir = Directory(p.join(imageStorage.baseDir, 'generated'));
    if (!await generatedDir.exists()) return;

    final files = await generatedDir
        .list()
        .where((f) => f is File && p.extension(f.path).toLowerCase() == '.png')
        .cast<File>()
        .toList();

    if (files.isEmpty) return;

    final msg = current.messages[msgIdx];
    final targetSwipeId = msg.swipeId;
    final targetAgentSwipeId = msg.agentSwipeId;
    final Set<String> claimedPaths = {};
    for (final m in current.messages) {
      claimedPaths.addAll(ImageTagMarkup.extractImageResultPaths(m.content));
      for (final s in m.swipes) {
        claimedPaths.addAll(ImageTagMarkup.extractImageResultPaths(s));
      }
      for (final swipe in m.agentSwipes) {
        claimedPaths.addAll(
          ImageTagMarkup.extractImageResultPaths(swipe.content),
        );
      }
      for (final meta in m.swipesMeta) {
        final stored = meta['agentSwipes'];
        if (stored is! List) continue;
        for (final value in stored) {
          if (value is! Map) continue;
          final content = value['content'];
          if (content is String) {
            claimedPaths.addAll(
              ImageTagMarkup.extractImageResultPaths(content),
            );
          }
        }
      }
    }

    // Stored paths are relative to the Glaze data root while the directory
    // listing is absolute, so both sides are compared on the resolved path —
    // without that every file reads as unclaimed and an image already shown in
    // the message can be attached to a second block.
    final claimedAbsolute = claimedPaths
        .map((path) => resolveGlazeFilePath(path) ?? path)
        .toSet();
    final unclaimed =
        files.where((f) => !claimedAbsolute.contains(f.path)).toList()..sort(
          (a, b) => b.lastAccessedSync().compareTo(a.lastAccessedSync()),
        );

    final candidates = unclaimed.length > 20
        ? unclaimed.sublist(0, 20)
        : unclaimed;

    if (candidates.isEmpty) return;

    final msgTimestamp = msg.timestamp ?? 0;
    File? bestMatch;
    int bestDiff = 0x7FFFFFFFFFFFFFFF;
    for (final f in candidates) {
      final stat = await f.stat();
      final fileMs = stat.modified.millisecondsSinceEpoch;
      final diff = (fileMs - msgTimestamp * 1000).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestMatch = f;
      }
    }

    if (bestMatch == null) return;

    // Stored relative to the data root, like every other image path.
    final foundPath = relativeGlazeFilePath(bestMatch.path);

    final updatedContent = attach(msg.content, foundPath);
    if (updatedContent == msg.content) return;

    final sessionId = current.session!.id;
    final updatedSession = await _ref
        .read(chatRepoProvider)
        .mutateMessage(
          sessionId: sessionId,
          messageId: messageId,
          updatedAt: currentTimestampSeconds(),
          mutate: (message) {
            final content = attach(message.content, foundPath);
            if (content == message.content) return null;
            return ImageGenProcessor.replaceImageContentAt(
              message,
              content,
              swipeId: targetSwipeId,
              agentSwipeId: targetAgentSwipeId,
            );
          },
        );
    if (updatedSession == null) return;
    ChatSessionService.updateCache(updatedSession);
    final liveState = _getState().value;
    final merged = ImageGenProcessor.mergeOwnedStateUpdate(
      liveState: liveState,
      update: current.copyWith(session: updatedSession),
      sessionId: sessionId,
      targetMessageId: messageId,
      ownsOperation: liveState?.session?.id == sessionId,
    );
    if (merged != null) _setState(AsyncData(merged));
  }
}
