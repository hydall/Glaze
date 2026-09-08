import '../../core/llm/prompt_builder.dart' show PromptPayload;
import '../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../core/models/chat_message.dart';

class ChatState {
  final ChatSession? session;
  final bool isGenerating;
  final bool isGeneratingImage;

  /// True while post-generation stages (cleaner, Ledger, ext-blocks, image
  /// tags) are running. Decoupled from [isGenerating]
  /// (which marks the streaming window) so the message-sync layer can
  /// settle the persisted assistant message into the DOM while the Stop
  /// button stays pressable through the post-gen window.
  final bool isPostGenRunning;
  final String? error;
  final String? lastRawResponse;
  final DateTime? generationStartTime;
  final int visibleStartIndex;
  final bool isLoadingOlder;

  final String? regenTargetId;

  /// Id of the assistant message a `continueMessage()` run is extending.
  /// Set while the continuation streams so the WebView appends the incoming
  /// text to that bubble instead of spawning a separate typing placeholder
  /// that would visibly collapse into it once the merge lands (INV-CM1).
  ///
  /// Null on every other generation path.
  final String? continuationTargetId;

  /// Transient snapshot of the prompt payload used for the last generation.
  /// Not persisted, not part of UI state — carried through the pipeline so the
  /// POST-cleaner's auditor can inspect the exact context the final agent saw
  /// without re-querying memory/lorebooks. Null on fallback/early-abort paths.
  final PromptPayload? promptPayload;
  final MainModelContextSnapshot? mainModelContextSnapshot;

  static const int initialPageSize = 20;
  static const int olderPageSize = 20;

  const ChatState({
    this.session,
    this.isGenerating = false,
    this.isGeneratingImage = false,
    this.isPostGenRunning = false,
    this.error,
    this.lastRawResponse,
    this.generationStartTime,
    this.visibleStartIndex = 0,
    this.isLoadingOlder = false,
    this.regenTargetId,
    this.continuationTargetId,
    this.promptPayload,
    this.mainModelContextSnapshot,
  });

  bool get hasMoreOlder => visibleStartIndex > 0;

  List<ChatMessage> get messages => session?.messages ?? [];

  List<ChatMessage> get visibleMessages {
    final all = messages;
    if (visibleStartIndex >= all.length) return all;
    return all.sublist(visibleStartIndex);
  }

  static const _unset = Object();

  ChatState copyWith({
    ChatSession? session,
    bool? isGenerating,
    bool? isGeneratingImage,
    bool? isPostGenRunning,
    Object? error = _unset,
    String? lastRawResponse,
    DateTime? generationStartTime,
    int? visibleStartIndex,
    bool? isLoadingOlder,
    Object? regenTargetId = _unset,
    Object? continuationTargetId = _unset,
    PromptPayload? promptPayload,
    MainModelContextSnapshot? mainModelContextSnapshot,
  }) {
    return ChatState(
      session: session ?? this.session,
      isGenerating: isGenerating ?? this.isGenerating,
      isGeneratingImage: isGeneratingImage ?? this.isGeneratingImage,
      isPostGenRunning: isPostGenRunning ?? this.isPostGenRunning,
      error: error == _unset ? this.error : error as String?,
      lastRawResponse: lastRawResponse ?? this.lastRawResponse,
      generationStartTime: generationStartTime ?? this.generationStartTime,
      visibleStartIndex: visibleStartIndex ?? this.visibleStartIndex,
      isLoadingOlder: isLoadingOlder ?? this.isLoadingOlder,
      regenTargetId: regenTargetId == _unset
          ? this.regenTargetId
          : regenTargetId as String?,
      continuationTargetId: continuationTargetId == _unset
          ? this.continuationTargetId
          : continuationTargetId as String?,
      promptPayload: promptPayload ?? this.promptPayload,
      mainModelContextSnapshot:
          mainModelContextSnapshot ?? this.mainModelContextSnapshot,
    );
  }
}

class StreamingState {
  final String text;
  final String? reasoning;

  /// When set, the streaming text replaces the content of the existing
  /// message with this id in the WebView (instead of creating a new virtual
  /// `streamingId` message). Used by the POST-cleaner to stream its rewrite
  /// into the last assistant message.
  ///
  /// Null = normal generation path (new virtual streaming message).
  final String? targetMessageId;

  const StreamingState({this.text = '', this.reasoning, this.targetMessageId});
}
