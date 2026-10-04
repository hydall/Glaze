import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/post_cleaner_state_provider.dart';
import '../state/studio_cycle_state_provider.dart';
import 'chat_status_card_shell.dart';

/// Floating card shown at the top of the chat while the Studio controller-cycle
/// is running, and for a brief moment after it finishes (done/agentErrors/
/// error).
///
/// Unifies the three Studio phases into a single `n/3` progress indicator:
///   1/3 — Controllers Gen (intermediate agents)
///   2/3 — Main agent (final generator streaming)
///   3/3 — Cleaning (POST-cleaner rewrite, only when Studio was active)
///
/// The cleaning phase is detected by watching [postCleanerStateProvider]:
/// when the cleaner starts running while the Studio cycle is still active
/// (writingFinal/done), the card transitions to 3/3. This avoids coupling
/// the cleaner pipeline to the Studio state provider — the card simply
/// observes both.
///
/// Auto-dismisses 2.5s after the cycle finishes.
class StudioStatusCard extends ConsumerStatefulWidget {
  const StudioStatusCard({super.key});

  @override
  ConsumerState<StudioStatusCard> createState() => _StudioStatusCardState();
}

class _StudioStatusCardState extends ConsumerState<StudioStatusCard> {
  StudioCyclePhase? _lastSeenPhase;
  PostCleanerPhase? _lastSeenCleanerPhase;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(studioCycleStateProvider);
    final cleanerState = ref.watch(postCleanerStateProvider);
    final cs = Theme.of(context).colorScheme;
    const totalSteps = 4;

    // Detect cleaning phase: cleaner running while Studio was active.
    // Studio "was active" = phase is writingFinal or done (i.e. the cycle
    // has not yet auto-dismissed to idle). When the cleaner starts in that
    // window, we transition to the cleaning sub-phase.
    final cleanerRunning =
        cleanerState.phase == PostCleanerPhase.factChecking ||
        cleanerState.phase == PostCleanerPhase.running;
    final studioInFinalWindow =
        state.phase == StudioCyclePhase.writingFinal ||
        state.phase == StudioCyclePhase.done ||
        state.phase == StudioCyclePhase.agentErrors;
    final showCleaning = cleanerRunning && studioInFinalWindow;

    // Track phase transitions to trigger auto-dismiss.
    if (_lastSeenPhase != state.phase) {
      _lastSeenPhase = state.phase;
      if (state.phase == StudioCyclePhase.done ||
          state.phase == StudioCyclePhase.agentErrors ||
          state.phase == StudioCyclePhase.error) {
        _scheduleAutoDismiss();
      }
    }
    if (_lastSeenCleanerPhase != cleanerState.phase) {
      _lastSeenCleanerPhase = cleanerState.phase;
      // When the cleaner finishes during the Studio window, schedule a
      // re-evaluation so the card can transition from 3/3 back to done.
      if (cleanerState.phase == PostCleanerPhase.done ||
          cleanerState.phase == PostCleanerPhase.skipped ||
          cleanerState.phase == PostCleanerPhase.error) {
        _scheduleAutoDismiss();
      }
    }

    if (state.phase == StudioCyclePhase.idle) return const SizedBox.shrink();

    final String label;
    final IconData icon;
    final Color accent;
    final bool showSpinner;

    if (state.phase == StudioCyclePhase.running) {
      label = '1/$totalSteps - Controllers Gen';
      icon = Icons.auto_awesome_outlined;
      accent = cs.primary;
      showSpinner = true;
    } else if (state.phase == StudioCyclePhase.writingFinal) {
      if (showCleaning) {
        label = cleanerLabel(cleanerState);
        icon = Icons.cleaning_services_outlined;
        accent = cs.primary;
        showSpinner = true;
      } else {
        label = '2/$totalSteps - Main agent';
        icon = Icons.edit_note;
        accent = cs.primary;
        showSpinner = true;
      }
    } else if (state.phase == StudioCyclePhase.cleaning) {
      label = cleanerLabel(cleanerState);
      icon = Icons.cleaning_services_outlined;
      accent = cs.primary;
      showSpinner = true;
    } else if (state.phase == StudioCyclePhase.done) {
      if (showCleaning) {
        label = cleanerLabel(cleanerState);
        icon = Icons.cleaning_services_outlined;
        accent = cs.primary;
        showSpinner = true;
      } else {
        final failed = state.failedAgents;
        label = failed > 0
            ? 'Studio done ($failed failed)'
            : 'Studio done (${state.totalAgents})';
        icon = Icons.check_circle_outline;
        accent = Colors.green;
        showSpinner = false;
      }
    } else if (state.phase == StudioCyclePhase.agentErrors) {
      if (showCleaning) {
        label = cleanerLabel(cleanerState);
        icon = Icons.cleaning_services_outlined;
        accent = cs.primary;
        showSpinner = true;
      } else {
        final names = state.failedAgentNames.join(', ');
        label = 'Controllers failed: $names';
        icon = Icons.warning_amber_outlined;
        accent = Colors.orange;
        showSpinner = false;
      }
    } else {
      // error
      label = 'Studio failed';
      icon = Icons.error_outline;
      accent = Colors.redAccent;
      showSpinner = false;
    }

    return ChatStatusCardShell(
      label: label,
      icon: icon,
      accent: accent,
      showSpinner: showSpinner,
    );
  }

  String cleanerLabel(PostCleanerState cleanerState) {
    if (cleanerState.phase == PostCleanerPhase.factChecking) {
      return '3/4 - Fact checking';
    }
    if (cleanerState.factCheckEnabled) {
      return '4/4 - Cleaning';
    }
    return '3/4 - Cleaning';
  }

  void _scheduleAutoDismiss() {
    Future<void>.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      final current = ref.read(studioCycleStateProvider);
      final cleaner = ref.read(postCleanerStateProvider);
      // Only auto-clear if we're still in the same done/agentErrors/error
      // phase (i.e. a new cycle hasn't started in the meantime) AND the
      // cleaner is not running (otherwise the 3/3 card must stay visible).
      if (current.phase != StudioCyclePhase.running &&
          current.phase != StudioCyclePhase.writingFinal &&
          current.phase != StudioCyclePhase.cleaning &&
          current.phase != StudioCyclePhase.idle &&
          cleaner.phase != PostCleanerPhase.factChecking &&
          cleaner.phase != PostCleanerPhase.running) {
        ref.read(studioCycleStateProvider.notifier).state =
            const StudioCycleState.idle();
      }
    });
  }
}
