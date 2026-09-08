import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/image_gen_patterns.dart';
import '../../core/models/chat_message.dart';
import '../../core/state/db_provider.dart';
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
    result = result.replaceAllMapped(ImgGenPatterns.htmlIigTagRegex, (m) {
      final instruction = m.group(1) ?? '';
      final errorJson = jsonEncode({
        'error': 'Generation interrupted',
        'instruction': instruction,
      });
      return '[IMG:ERROR:$errorJson]';
    });
    result = result.replaceAllMapped(ImgGenPatterns.htmlIigTagDoubleRegex, (m) {
      final instruction = m.group(1) ?? '';
      final errorJson = jsonEncode({
        'error': 'Generation interrupted',
        'instruction': instruction,
      });
      return '[IMG:ERROR:$errorJson]';
    });
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
    if (ImgGenPatterns.imgErrorRegex.hasMatch(text)) {
      return text.replaceFirst(
        ImgGenPatterns.imgErrorRegex,
        '[IMG:RESULT:$resultPath]',
      );
    }
    if (ImgGenPatterns.imgGenHtmlRegex.hasMatch(text)) {
      return text.replaceFirst(
        ImgGenPatterns.imgGenHtmlRegex,
        '[IMG:RESULT:$resultPath]',
      );
    }
    if (text.contains('[IMG:GEN]')) {
      return text.replaceFirst('[IMG:GEN]', '[IMG:RESULT:$resultPath]');
    }
    if (ImgGenPatterns.imgGenRegex.hasMatch(text)) {
      return text.replaceFirst(
        ImgGenPatterns.imgGenRegex,
        '[IMG:RESULT:$resultPath]',
      );
    }
    return text;
  }

  static String resetImgTagsToGen(String text) {
    var result = text;
    result = result.replaceAllMapped(ImgGenPatterns.imgErrorRegex, (m) {
      final data = m.group(1) ?? '';
      String instruction = '';
      try {
        final parsed = jsonDecode(data);
        instruction = (parsed['instruction'] ?? '') as String;
      } catch (_) {}
      if (instruction.isNotEmpty) {
        return '[IMG:GEN:$instruction]';
      }
      return '[IMG:GEN]';
    });
    result = result.replaceAllMapped(ImgGenPatterns.imgResultRegex, (m) {
      final raw = m.group(1) ?? '';
      final pipeIdx = raw.indexOf('|');
      final instr = pipeIdx != -1 ? raw.substring(pipeIdx + 1) : '';
      if (instr.isNotEmpty) {
        return '[IMG:GEN:$instr]';
      }
      return '[IMG:GEN]';
    });
    return result;
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
        lastMsg.content.contains('[IMG:RESULT:');
    if (!hasRetryableContent) return;

    final resetContent = resetImgTagsToGen(lastMsg.content);
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
            final content = resetImgTagsToGen(message.content);
            if (content == message.content &&
                !ImageTagMarkup.hasImageGenTags(content)) {
              return null;
            }
            return ImageGenProcessor.appendImageRegenerationSwipe(
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

  Future<void> retryImageGenerationForMessage(String messageId) async {
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

    var resetContent = resetImgTagsToGen(msg.content);
    if (resetContent == msg.content) return;

    final resetSession = await _ref
        .read(chatRepoProvider)
        .mutateMessage(
          sessionId: current.session!.id,
          messageId: msg.id,
          updatedAt: currentTimestampSeconds(),
          mutate: (message) {
            if (message.role != 'assistant') return null;
            final content = resetImgTagsToGen(message.content);
            if (content == message.content) return null;
            return ImageGenProcessor.appendImageRegenerationSwipe(
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

  Future<void> findImageOnDisk(String messageId, String instruction) async {
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

    final unclaimed =
        files.where((f) => !claimedPaths.contains(f.path)).toList()..sort(
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

    final foundPath = bestMatch.path;

    var updatedContent = msg.content;
    updatedContent = replaceFirstImgErrorOrGen(updatedContent, foundPath);

    if (updatedContent == msg.content) return;

    final sessionId = current.session!.id;
    final updatedSession = await _ref
        .read(chatRepoProvider)
        .mutateMessage(
          sessionId: sessionId,
          messageId: messageId,
          updatedAt: currentTimestampSeconds(),
          mutate: (message) {
            final content = replaceFirstImgErrorOrGen(
              message.content,
              foundPath,
            );
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
