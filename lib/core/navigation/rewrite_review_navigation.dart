import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/repositories/card_evolution_repo.dart';
import '../services/generation_notification_service.dart';

/// A one-shot request for the app shell to open an automatically-created
/// rewrite proposal. [sequence] makes repeated requests monotonic even when
/// they happen to target the same job.
@immutable
class RewriteReviewNavigationIntent {
  const RewriteReviewNavigationIntent({
    required this.sequence,
    required this.charId,
    required this.sessionId,
    required this.jobId,
    required this.authorityRevision,
  });

  final int sequence;
  final String charId;
  final String sessionId;
  final String jobId;
  final int authorityRevision;

  String get location =>
      '/${Uri(pathSegments: ['character', charId, 'rewrite', jobId])}';
}

class RewriteReviewNavigationIntentNotifier
    extends Notifier<RewriteReviewNavigationIntent?> {
  int _sequence = 0;

  @override
  RewriteReviewNavigationIntent? build() => null;

  void emit({
    required String charId,
    required String sessionId,
    required String jobId,
    required int authorityRevision,
  }) {
    state = RewriteReviewNavigationIntent(
      sequence: ++_sequence,
      charId: charId,
      sessionId: sessionId,
      jobId: jobId,
      authorityRevision: authorityRevision,
    );
  }
}

final rewriteReviewNavigationIntentProvider =
    NotifierProvider<
      RewriteReviewNavigationIntentNotifier,
      RewriteReviewNavigationIntent?
    >(RewriteReviewNavigationIntentNotifier.new);

/// Pure authorization policy for automatic review navigation.
///
/// Navigation is allowed only for the job returned by the exact `persisted`
/// finalize result, and only while the same foreground chat authority
/// (including its revision) remains current.
class AutomaticRewriteReviewNavigationPolicy {
  const AutomaticRewriteReviewNavigationPolicy();

  RewriteReviewNavigationTarget? resolve({
    required CardEvolutionFinalizeOutcome outcome,
    required ActiveChatContext? capturedAuthority,
    required ActiveChatContext? currentAuthority,
  }) {
    if (outcome.kind != 'persisted') return null;
    final job = outcome.job;
    if (job == null ||
        job.id.isEmpty ||
        job.characterId.isEmpty ||
        capturedAuthority == null ||
        currentAuthority == null) {
      return null;
    }
    if (capturedAuthority.charId != job.characterId ||
        capturedAuthority.sessionId != job.chatSessionId ||
        currentAuthority.charId != capturedAuthority.charId ||
        currentAuthority.sessionId != capturedAuthority.sessionId ||
        currentAuthority.revision != capturedAuthority.revision) {
      return null;
    }
    return RewriteReviewNavigationTarget(
      charId: job.characterId,
      sessionId: job.chatSessionId,
      jobId: job.id,
      authorityRevision: capturedAuthority.revision,
    );
  }
}

@immutable
class RewriteReviewNavigationTarget {
  const RewriteReviewNavigationTarget({
    required this.charId,
    required this.sessionId,
    required this.jobId,
    required this.authorityRevision,
  });

  final String charId;
  final String sessionId;
  final String jobId;
  final int authorityRevision;
}

/// Captures authority immediately before automatic rewrite work starts.
/// Returns null unless the requested session is the focused foreground chat.
ActiveChatContext? captureAutomaticRewriteReviewAuthority({
  required String charId,
  required String sessionId,
  GenerationNotificationService? notificationService,
}) {
  final authority =
      (notificationService ?? GenerationNotificationService.instance)
          .activeChatContext;
  if (authority?.charId != charId || authority?.sessionId != sessionId) {
    return null;
  }
  return authority;
}

/// Emits the app-level navigation intent after an automatic rewrite finishes.
///
/// The caller must pass the authority captured before starting the async work.
/// A changed lifecycle, character, session, or revision suppresses navigation.
bool emitAutomaticRewriteReviewIntent(
  Ref ref, {
  required CardEvolutionFinalizeOutcome outcome,
  required ActiveChatContext? capturedAuthority,
  GenerationNotificationService? notificationService,
}) {
  if (!ref.mounted) return false;
  final service = notificationService ?? GenerationNotificationService.instance;
  final target = const AutomaticRewriteReviewNavigationPolicy().resolve(
    outcome: outcome,
    capturedAuthority: capturedAuthority,
    currentAuthority: service.activeChatContext,
  );
  if (target == null) return false;
  ref
      .read(rewriteReviewNavigationIntentProvider.notifier)
      .emit(
        charId: target.charId,
        sessionId: target.sessionId,
        jobId: target.jobId,
        authorityRevision: target.authorityRevision,
      );
  return true;
}
