import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/api_config.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/utils/time_helpers.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../image_gen/image_gen_provider.dart';
import '../../settings/api_list_provider.dart';
import '../../image_gen/services/image_tag_markup.dart';
import '../chat_session_service.dart';
import '../chat_state.dart';

class ImageGenProcessor {
  final Ref _ref;
  final String _charId;
  final CancelToken? _cancelToken;
  final bool Function()? isCurrentOperation;
  final void Function(ChatState) _onStateUpdate;

  ImageGenProcessor({
    required this._ref,
    required this._charId,
    this._cancelToken,
    this.isCurrentOperation,
    required this._onStateUpdate,
  });

  Future<void> process(
    ChatState currentState, {
    String? targetMessageId,
  }) async {
    final session = currentState.session;
    if (session == null) return;

    final imgGenSettingsAsync = _ref.read(imageGenSettingsProvider);
    if (imgGenSettingsAsync.isLoading) {
      final imgGenSettings = await _ref.read(imageGenSettingsProvider.future);
      if (!imgGenSettings.enabled) return;
    } else {
      final imgGenSettings = imgGenSettingsAsync.value;
      if (imgGenSettings == null || !imgGenSettings.enabled) return;
    }
    final imgGenSettings = await _ref.read(imageGenSettingsProvider.future);

    final targetIdx = targetMessageId == null
        ? session.messages.length - 1
        : session.messages.indexWhere(
            (message) => message.id == targetMessageId,
          );
    if (targetIdx < 0) return;
    final targetMsg = session.messages[targetIdx];
    final stableTargetMessageId = targetMsg.id;
    final targetSwipeId = targetMsg.swipeId;
    final targetAgentSwipeId = targetMsg.agentSwipeId;
    if (targetMsg.role != 'assistant') return;

    final notifier = _ref.read(imageGenSettingsProvider.notifier);
    final service = await notifier.getServiceAsync();
    if (!ImageTagMarkup.hasImageGenTags(targetMsg.content)) return;

    final apiConfigSync = _ref.read(activeApiConfigProvider);
    final ApiConfig apiConfig;
    if (apiConfigSync != null) {
      apiConfig = apiConfigSync;
    } else {
      final apiList = await _ref.read(apiListProvider.future);
      if (apiList.isEmpty) return;
      final activeId = _ref.read(activeApiPresetIdProvider);
      apiConfig = activeId != null
          ? apiList.firstWhere(
              (c) => c.id == activeId,
              orElse: () => apiList.first,
            )
          : apiList.first;
    }

    final charRepo = _ref.read(characterRepoProvider);
    final character = await charRepo.getById(_charId);

    final personaRepo = _ref.read(personaRepoProvider);
    final personas = await personaRepo.getAll();
    final connections = _ref.read(personaConnectionsProvider);
    final activePersonaId = _ref.read(activePersonaIdProvider);
    final persona = getEffectivePersona(
      personas,
      _charId,
      session.id,
      activePersonaId,
      connections,
    );

    final recentContexts = _collectRecentImageContexts(session.messages);
    var latestSession = session;
    if (!_ownsOperation) return;

    debugPrint('[IMGGEN] → setting isGeneratingImage=true');
    _onStateUpdate(
      currentState.copyWith(session: latestSession, isGeneratingImage: true),
    );

    try {
      final updatedContent = await service.processMessageImages(
        text: targetMsg.content,
        settings: imgGenSettings,
        llmEndpoint: apiConfig.endpoint,
        llmApiKey: apiConfig.apiKey,
        llmModel: apiConfig.model,
        character: character,
        persona: persona,
        recentImageContexts: recentContexts,
        cancelToken: _cancelToken,
        onUpdate: (updatedText) {
          // A cancellation may race an image provider's progress callback.
          // Ownership checks at the caller prevent callbacks from an old
          // operation from reaching a replacement generation.
          if (!_ownsOperation) return;
          latestSession = _replaceMessage(
            latestSession,
            stableTargetMessageId,
            targetSwipeId,
            targetAgentSwipeId,
            updatedText,
          );
          _onStateUpdate(
            currentState.copyWith(
              session: latestSession,
              isGeneratingImage: true,
            ),
          );
        },
        onError: (error) {
          debugPrint('[IMGGEN] onError: $error');
          GlazeToast.showWithoutContext(
            'Image gen: $error',
            isError: true,
            duration: 4000,
          );
        },
      );

      if (!_ownsOperation) return;

      if (_cancelToken?.isCancelled == true) {
        var cancelContent = updatedContent;
        while (ImageTagMarkup.hasImageGenTags(cancelContent)) {
          final replaced = ImageTagMarkup.replaceTagWithError(
            cancelContent,
            0,
            'Cancelled by user',
          );
          if (replaced == cancelContent) break;
          cancelContent = replaced;
        }
        latestSession = _replaceMessage(
          latestSession,
          stableTargetMessageId,
          targetSwipeId,
          targetAgentSwipeId,
          cancelContent,
        );
        final durable = await _persistMessageContent(
          session.id,
          stableTargetMessageId,
          targetSwipeId,
          targetAgentSwipeId,
          cancelContent,
        );
        if (durable != null) {
          latestSession = durable;
          ChatSessionService.updateCache(durable);
        }
        return;
      }

      latestSession = _replaceMessage(
        latestSession,
        stableTargetMessageId,
        targetSwipeId,
        targetAgentSwipeId,
        updatedContent,
      );
      final durable = await _persistMessageContent(
        session.id,
        stableTargetMessageId,
        targetSwipeId,
        targetAgentSwipeId,
        updatedContent,
      );
      if (durable != null) {
        latestSession = durable;
        ChatSessionService.updateCache(durable);
      }
    } on DioException catch (e) {
      if (!CancelToken.isCancel(e)) rethrow;
    } finally {
      // This must run even when the final repository write fails. The caller
      // accepts this update only while the originating operation still owns
      // the active generation/session.
      if (_ownsOperation) {
        _onStateUpdate(
          currentState.copyWith(
            session: latestSession,
            isGeneratingImage: false,
          ),
        );
      }
    }
  }

  static ChatState? mergeOwnedStateUpdate({
    required ChatState? liveState,
    required ChatState update,
    required String sessionId,
    required String targetMessageId,
    required bool ownsOperation,
  }) {
    if (!ownsOperation ||
        liveState == null ||
        liveState.session?.id != sessionId ||
        update.session?.id != sessionId) {
      return null;
    }

    final liveSession = liveState.session!;
    final updatedMessage = update.session!.messages
        .where((message) => message.id == targetMessageId)
        .firstOrNull;
    final liveIndex = liveSession.messages.indexWhere(
      (message) => message.id == targetMessageId,
    );
    final mergedSession = updatedMessage == null || liveIndex < 0
        ? liveSession
        : liveSession.copyWith(
            messages: List<ChatMessage>.from(liveSession.messages)
              ..[liveIndex] = updatedMessage,
            updatedAt: update.session!.updatedAt,
          );

    return liveState.copyWith(
      session: mergedSession,
      isGeneratingImage: update.isGeneratingImage,
    );
  }

  ChatSession _replaceMessage(
    ChatSession session,
    String messageId,
    int swipeId,
    int agentSwipeId,
    String content,
  ) {
    final messageIndex = session.messages.indexWhere(
      (message) => message.id == messageId,
    );
    if (messageIndex < 0) return session;
    final newMessages = List<ChatMessage>.from(session.messages);
    newMessages[messageIndex] = replaceImageContentAt(
      newMessages[messageIndex],
      content,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    return session.copyWith(
      messages: newMessages,
      updatedAt: currentTimestampSeconds(),
    );
  }

  Future<ChatSession?> _persistMessageContent(
    String sessionId,
    String messageId,
    int swipeId,
    int agentSwipeId,
    String content,
  ) {
    return _ref
        .read(chatRepoProvider)
        .mutateMessage(
          sessionId: sessionId,
          messageId: messageId,
          updatedAt: currentTimestampSeconds(),
          mutate: (message) => replaceImageContentAt(
            message,
            content,
            swipeId: swipeId,
            agentSwipeId: agentSwipeId,
          ),
        );
  }

  static ChatMessage appendImageRegenerationSwipe(
    ChatMessage message,
    String pendingContent,
  ) {
    final swipes = message.swipes.isEmpty
        ? <String>[message.content]
        : List<String>.from(message.swipes);
    final activeSwipeId = message.swipeId.clamp(0, swipes.length - 1);
    final meta = List<Map<String, dynamic>>.generate(
      swipes.length,
      (index) => index < message.swipesMeta.length
          ? Map<String, dynamic>.from(message.swipesMeta[index])
          : <String, dynamic>{},
    );
    final activeAgentSwipes = message.agentSwipes.isEmpty
        ? <AgentSwipe>[
            AgentSwipe(
              content: message.content,
              reasoning: message.reasoning,
              genTime: message.genTime,
              tokens: message.tokens,
              studioOutputs: message.studioOutputs,
            ),
          ]
        : List<AgentSwipe>.from(message.agentSwipes);
    final activeAgentSwipeId = message.agentSwipeId.clamp(
      0,
      activeAgentSwipes.length - 1,
    );
    meta[activeSwipeId] = {
      ...meta[activeSwipeId],
      'agentSwipes': activeAgentSwipes.map((swipe) => swipe.toJson()).toList(),
      'agentSwipeId': activeAgentSwipeId,
    };

    final candidateAgentSwipes = List<AgentSwipe>.from(activeAgentSwipes);
    candidateAgentSwipes[activeAgentSwipeId] =
        candidateAgentSwipes[activeAgentSwipeId].copyWith(
          content: pendingContent,
        );
    final candidateMeta = Map<String, dynamic>.from(meta[activeSwipeId])
      ..remove('isError')
      ..['agentSwipes'] = candidateAgentSwipes
          .map((swipe) => swipe.toJson())
          .toList()
      ..['agentSwipeId'] = activeAgentSwipeId;
    swipes.add(pendingContent);
    meta.add(candidateMeta);

    return message.copyWith(
      content: pendingContent,
      swipes: swipes,
      swipeId: swipes.length - 1,
      swipesMeta: meta,
      agentSwipes: candidateAgentSwipes,
      agentSwipeId: activeAgentSwipeId,
      isError: false,
    );
  }

  static ChatMessage replaceActiveImageContent(
    ChatMessage message,
    String content,
  ) => replaceImageContentAt(
    message,
    content,
    swipeId: message.swipeId,
    agentSwipeId: message.agentSwipeId,
  );

  static ChatMessage replaceImageContentAt(
    ChatMessage message,
    String content, {
    required int swipeId,
    required int agentSwipeId,
  }) {
    final swipes = List<String>.from(message.swipes);
    if (swipeId >= 0 && swipeId < swipes.length) {
      swipes[swipeId] = content;
    }

    final meta = List<Map<String, dynamic>>.generate(
      swipes.length,
      (index) => index < message.swipesMeta.length
          ? Map<String, dynamic>.from(message.swipesMeta[index])
          : <String, dynamic>{},
    );
    final isActiveSwipe = message.swipeId == swipeId;
    var agentSwipes = isActiveSwipe
        ? List<AgentSwipe>.from(message.agentSwipes)
        : <AgentSwipe>[];
    if (!isActiveSwipe && swipeId >= 0 && swipeId < meta.length) {
      final stored = meta[swipeId]['agentSwipes'];
      if (stored is List) {
        agentSwipes = stored
            .whereType<Map<Object?, Object?>>()
            .map(
              (value) => AgentSwipe.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList();
      }
    }
    if (agentSwipes.isEmpty && swipes.isNotEmpty) {
      agentSwipes = [
        AgentSwipe(
          content: content,
          reasoning: message.reasoning,
          genTime: message.genTime,
          tokens: message.tokens,
          studioOutputs: message.studioOutputs,
        ),
      ];
    } else if (agentSwipeId >= 0 && agentSwipeId < agentSwipes.length) {
      agentSwipes[agentSwipeId] = agentSwipes[agentSwipeId].copyWith(
        content: content,
      );
    }
    if (swipeId >= 0 && swipeId < meta.length) {
      meta[swipeId] = {
        ...meta[swipeId],
        if (agentSwipes.isNotEmpty)
          'agentSwipes': agentSwipes.map((swipe) => swipe.toJson()).toList(),
        if (agentSwipes.isNotEmpty) 'agentSwipeId': agentSwipeId,
      };
    }

    return message.copyWith(
      content: isActiveSwipe ? content : message.content,
      swipes: swipes,
      swipesMeta: meta,
      agentSwipes: isActiveSwipe ? agentSwipes : message.agentSwipes,
    );
  }

  bool get _ownsOperation =>
      isCurrentOperation?.call() ?? !(_cancelToken?.isCancelled ?? false);

  List<String> _collectRecentImageContexts(List<ChatMessage> messages) {
    final contexts = <String>[];
    for (int i = messages.length - 1; i >= 0 && contexts.length < 3; i--) {
      final paths = ImageTagMarkup.extractImageResultPaths(messages[i].content);
      contexts.addAll(paths);
    }
    return contexts;
  }
}
