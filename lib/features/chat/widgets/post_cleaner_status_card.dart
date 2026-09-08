import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/post_cleaner_state_provider.dart';
import '../state/studio_cycle_state_provider.dart';
import 'chat_status_card_shell.dart';

/// Floating card shown at the top of the chat while the POST-cleaner is
/// running, and for a brief moment after it finishes (done/error).
///
/// Live status card shown over the chat while the POST-cleaner runs.
/// Auto-dismisses 2.5s after the cleaner finishes.
///
/// When the Studio tracker-cycle is active, the cleaner phase is surfaced
/// as the `3/3 - Cleaning` step inside [StudioStatusCard] instead, and this
/// card hides itself to avoid duplication.
class PostCleanerStatusCard extends ConsumerStatefulWidget {
  const PostCleanerStatusCard({super.key});

  @override
  ConsumerState<PostCleanerStatusCard> createState() =>
      _PostCleanerStatusCardState();
}

class _PostCleanerStatusCardState extends ConsumerState<PostCleanerStatusCard> {
  PostCleanerPhase? _lastSeenPhase;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(postCleanerStateProvider);
    final studioState = ref.watch(studioCycleStateProvider);
    final cs = Theme.of(context).colorScheme;

    // Track phase transitions to trigger auto-dismiss.
    if (_lastSeenPhase != state.phase) {
      _lastSeenPhase = state.phase;
      if (state.phase == PostCleanerPhase.done ||
          state.phase == PostCleanerPhase.skipped ||
          state.phase == PostCleanerPhase.error) {
        _scheduleAutoDismiss();
      }
    }

    if (state.phase == PostCleanerPhase.idle) return const SizedBox.shrink();

    // When the Studio cycle is active (running/writingFinal/done/cleaning),
    // the cleaner phase is shown as 3/3 inside StudioStatusCard — hide this
    // card to avoid duplication.
    if (studioState.isActive || studioState.phase == StudioCyclePhase.done) {
      return const SizedBox.shrink();
    }

    final isFactChecking = state.phase == PostCleanerPhase.factChecking;
    final isRunning = state.phase == PostCleanerPhase.running;
    final isError = state.phase == PostCleanerPhase.error;

    final String label;
    final IconData icon;
    final Color accent;

    if (isFactChecking) {
      label = 'Fact checking…';
      icon = Icons.fact_check_outlined;
      accent = cs.primary;
    } else if (isRunning) {
      label = 'Cleaning…';
      icon = Icons.cleaning_services_outlined;
      accent = cs.primary;
    } else if (state.phase == PostCleanerPhase.done) {
      final delta = state.charDelta;
      label = delta != null
          ? 'Cleaned (${delta >= 0 ? '+' : ''}$delta chars)'
          : 'Cleaned';
      icon = Icons.check_circle_outline;
      accent = Colors.green;
    } else if (isError) {
      label = 'Cleaner failed';
      icon = Icons.error_outline;
      accent = Colors.orange;
    } else {
      label = 'Cleaner skipped';
      icon = Icons.skip_next_outlined;
      accent = Colors.grey;
    }

    return ChatStatusCardShell(
      label: label,
      icon: icon,
      accent: accent,
      showSpinner: isFactChecking || isRunning,
      action: isFactChecking || isRunning
          ? IconButton(
              onPressed: () {
                final token = ref.read(cleanerCancelTokenProvider);
                if (token != null && !token.isCancelled) {
                  token.cancel('User aborted post-cleaner');
                }
              },
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              tooltip: 'Stop cleaner',
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(foregroundColor: cs.error),
            )
          : null,
    );
  }

  void _scheduleAutoDismiss() {
    Future<void>.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      final current = ref.read(postCleanerStateProvider);
      // Only auto-clear if we're still in the same done/error/skipped phase
      // (i.e. a new cleaner run hasn't started in the meantime).
      if (current.phase != PostCleanerPhase.factChecking &&
          current.phase != PostCleanerPhase.running &&
          current.phase != PostCleanerPhase.idle) {
        ref.read(postCleanerStateProvider.notifier).state =
            const PostCleanerState.idle();
      }
    });
  }
}
