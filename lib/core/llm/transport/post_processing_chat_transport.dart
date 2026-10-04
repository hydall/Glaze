import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../converters/prompt_post_processing.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';

/// [ChatTransport] decorator that applies the connection's SillyTavern-style
/// prompt post-processing before the protocol converter ever sees the prompt.
///
/// It sits at the very outside of the transport chain — outside the request
/// dump — so the diagnostics file records exactly the conversation that goes
/// on the wire, and so provider-specific rewrites that happen *inside* a
/// transport (OpenRouter's cache markers, Anthropic's `system` lift) operate
/// on the final message list rather than being flattened by a later merge.
///
/// [ChatTransportRequest.previousMessages] is processed with the same mode.
/// It is a previous request's conversation, used to hash a stable cache
/// prefix; leaving it unprocessed would compare a merged prompt against an
/// unmerged one and invalidate every breakpoint.
class PostProcessingChatTransport implements ChatTransport {
  PostProcessingChatTransport(this._inner);

  final ChatTransport _inner;

  /// The wrapped transport. Exposed so tests can assert factory routing.
  @visibleForTesting
  ChatTransport get inner => _inner;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) {
    return _inner.stream(
      request: applyTo(request),
      cancelToken: cancelToken,
      onUpdate: onUpdate,
      onComplete: onComplete,
      onError: onError,
    );
  }

  /// Pure: the request a transport should actually execute. Exposed so the
  /// prompt preview can show the same body without going through a transport.
  static ChatTransportRequest applyTo(ChatTransportRequest request) {
    final mode = PromptPostProcessing.normalize(request.promptPostProcessing);
    if (mode == PromptPostProcessing.none) return request;
    return request.withMessages(
      postProcessPrompt(
        request.messages,
        mode,
        charName: request.charName,
        userName: request.userName,
      ),
      previousMessages: request.previousMessages == null
          ? null
          : postProcessPrompt(
              request.previousMessages!,
              mode,
              charName: request.charName,
              userName: request.userName,
            ),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) => _inner.fetchModels(endpoint: endpoint, apiKey: apiKey);
}
