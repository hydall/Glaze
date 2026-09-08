import 'package:flutter_riverpod/legacy.dart';

/// Live state for post-generation tasks (Ledger and extension blocks).
/// Surfaced to the chat UI as a floating card so the user can see what's
/// happening after the main generation + cleaner complete.
class PostGenStatusState {
  final String? sessionId;
  final PostGenTask task;
  final PostGenTaskPhase phase;
  final String? detail;

  const PostGenStatusState({
    this.sessionId,
    this.task = PostGenTask.none,
    this.phase = PostGenTaskPhase.idle,
    this.detail,
  });

  bool get isActive => phase == PostGenTaskPhase.running;
  bool get isDone => phase == PostGenTaskPhase.done;
  bool get isError => phase == PostGenTaskPhase.error;

  const PostGenStatusState.idle()
    : sessionId = null,
      task = PostGenTask.none,
      phase = PostGenTaskPhase.idle,
      detail = null;

  const PostGenStatusState.running({
    required this.sessionId,
    required this.task,
    this.detail,
  }) : phase = PostGenTaskPhase.running;

  const PostGenStatusState.done({
    required this.sessionId,
    required this.task,
    this.detail,
  }) : phase = PostGenTaskPhase.done;

  const PostGenStatusState.error({
    required this.sessionId,
    required this.task,
    this.detail,
  }) : phase = PostGenTaskPhase.error;
}

enum PostGenTask { none, ledgerReconciliation, ledger, extBlocks }

enum PostGenTaskPhase { idle, running, done, error }

final postGenStatusProvider = StateProvider<PostGenStatusState>(
  (_) => const PostGenStatusState.idle(),
);
