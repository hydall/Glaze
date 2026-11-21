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

  /// True from the moment a send is painted optimistically until the run it
  /// starts publishes [isGenerating] (or the send is rolled back).
  ///
  /// The user's bubble is on screen during that window but nothing is
  /// generating yet, so the WebView would otherwise stamp a Regenerate button
  /// under a message whose reply is already on its way. Every consumer treats
  /// this as "busy" exactly the way it treats [isGenerating]; nothing in the
  /// generation path branches on it, so a leaked `true` can only withhold that
  /// one button, never block a run.
  final bool isSendPending;

  /// True while a stop is being made durable after the UI already shows the
  /// run as stopped.
  ///
  /// A stop is optimistic: [isGenerating] and friends drop the moment the user
  /// taps it, and the partial reply (or the restored variation) is painted
  /// straight away. Saving that result still takes a DB write, and the
  /// message-mutating actions (edit, swipe, plugin writes) treat this flag as
  /// busy so they cannot race it. New runs wait for the stop to settle instead
  /// (`AbortHandler.settled`), so a send tapped right after Stop is queued,
  /// not refused.
  final bool isStopping;

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
    this.isSendPending = false,
    this.isStopping = false,
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
    bool? isSendPending,
    bool? isStopping,
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
      isSendPending: isSendPending ?? this.isSendPending,
      isStopping: isStopping ?? this.isStopping,
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
