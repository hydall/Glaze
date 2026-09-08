import 'package:dio/dio.dart';
import 'package:flutter_riverpod/legacy.dart';

/// Live state of the POST-cleaner, surfaced to the chat UI so the user can
/// see when the cleaner is running (a floating card appears at the top of the
/// chat), and when it finishes (the card auto-dismisses after a short delay).
class PostCleanerState {
  final String? sessionId;
  final String? messageId;
  final PostCleanerPhase phase;
  final int? originalChars;
  final int? cleanedChars;
  final bool factCheckEnabled;

  const PostCleanerState({
    this.sessionId,
    this.messageId,
    this.phase = PostCleanerPhase.idle,
    this.originalChars,
    this.cleanedChars,
    this.factCheckEnabled = false,
  });

  bool get isActive =>
      phase == PostCleanerPhase.factChecking ||
      phase == PostCleanerPhase.running;
  bool get isDone =>
      phase == PostCleanerPhase.done || phase == PostCleanerPhase.skipped;
  bool get isError => phase == PostCleanerPhase.error;

  int? get charDelta => (originalChars != null && cleanedChars != null)
      ? cleanedChars! - originalChars!
      : null;

  const PostCleanerState.idle()
    : sessionId = null,
      messageId = null,
      phase = PostCleanerPhase.idle,
      originalChars = null,
      cleanedChars = null,
      factCheckEnabled = false;

  const PostCleanerState.running({
    required this.sessionId,
    required this.messageId,
    required this.originalChars,
    this.factCheckEnabled = false,
  }) : phase = PostCleanerPhase.running,
       cleanedChars = null;

  const PostCleanerState.factChecking({
    required this.sessionId,
    required this.messageId,
    required this.originalChars,
  }) : phase = PostCleanerPhase.factChecking,
       cleanedChars = null,
       factCheckEnabled = true;

  const PostCleanerState.done({
    required this.sessionId,
    required this.messageId,
    required this.originalChars,
    required this.cleanedChars,
  }) : phase = PostCleanerPhase.done,
       factCheckEnabled = false;

  const PostCleanerState.skipped({
    required this.sessionId,
    required this.messageId,
  }) : phase = PostCleanerPhase.skipped,
       originalChars = null,
       cleanedChars = null,
       factCheckEnabled = false;

  const PostCleanerState.error({
    required this.sessionId,
    required this.messageId,
  }) : phase = PostCleanerPhase.error,
       originalChars = null,
       cleanedChars = null,
       factCheckEnabled = false;
}

enum PostCleanerPhase { idle, factChecking, running, done, skipped, error }

/// Global POST-cleaner live state. Set by [CleanerStage.run]
/// and watched by [PostCleanerStatusCard] in the chat UI.
final postCleanerStateProvider = StateProvider<PostCleanerState>(
  (_) => const PostCleanerState.idle(),
);

/// Cancel token for the in-flight POST-cleaner LLM call. Set by
/// `CleanerStage.run` when the cleaner starts, cleared in
/// its `finally` block. The Stop button in [PostCleanerStatusCard] reads
/// this and cancels it.
final cleanerCancelTokenProvider = StateProvider<CancelToken?>((_) => null);
