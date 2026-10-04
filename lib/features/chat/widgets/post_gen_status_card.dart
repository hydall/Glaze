import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/post_gen_status_provider.dart';
import 'chat_status_card_shell.dart';

/// Longest a post-generation task may advertise itself as running.
///
/// Every stage clears its own status, but each of those paths needs a mounted
/// ref. When the owning ref goes away mid-run nobody is left to write the
/// terminal state and the card would spin forever. The bound is generous on
/// purpose: an aux call may retry three times against a three-minute timeout,
/// so anything past this window is a stranded indicator, not slow work.
const Duration kPostGenRunningWatchdog = Duration(minutes: 12);

/// Floating card shown at the top of the chat while post-generation tasks
/// (Ledger, Card Rewriter, and extension blocks) are running. Auto-dismisses
/// 2.5s after the last task completes, and can always be dismissed by hand
/// while running so a stranded indicator never blocks the chat header.
class PostGenStatusCard extends ConsumerStatefulWidget {
  const PostGenStatusCard({super.key, required this.sessionId});

  final String? sessionId;

  @override
  ConsumerState<PostGenStatusCard> createState() => _PostGenStatusCardState();
}

class _PostGenStatusCardState extends ConsumerState<PostGenStatusCard> {
  PostGenTaskPhase? _lastSeenPhase;
  PostGenTask? _lastSeenTask;
  Timer? _watchdog;

  @override
  void dispose() {
    _watchdog?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch<PostGenStatusState>(postGenStatusProvider);
    final cs = Theme.of(context).colorScheme;

    if (state.phase == PostGenTaskPhase.idle ||
        state.task == PostGenTask.none ||
        state.sessionId != widget.sessionId) {
      _lastSeenPhase = null;
      _lastSeenTask = null;
      _watchdog?.cancel();
      _watchdog = null;
      return const SizedBox.shrink();
    }

    // Detect transitions: when either the phase or the task changes we
    // may need to (re)schedule the auto-dismiss.  Without tracking the
    // task, completing a second post-gen task while the card still shows the
    // first task's `done` phase would skip the dismiss timer — leaving the
    // later completion card stuck.
    if (_lastSeenPhase != state.phase || _lastSeenTask != state.task) {
      _lastSeenPhase = state.phase;
      _lastSeenTask = state.task;
      if (state.phase == PostGenTaskPhase.done ||
          state.phase == PostGenTaskPhase.error) {
        _scheduleAutoDismiss(state);
      } else if (state.phase == PostGenTaskPhase.running) {
        _scheduleWatchdog(state);
      }
    }

    final String label;
    final IconData icon;
    final Color accent;
    final bool showSpinner;

    switch (state.task) {
      case PostGenTask.ledgerReconciliation:
        if (state.phase == PostGenTaskPhase.running) {
          label = 'Ledger reconciliation running...';
          icon = Icons.fact_check_outlined;
          accent = cs.primary;
          showSpinner = true;
        } else if (state.phase == PostGenTaskPhase.done) {
          label = state.detail ?? 'Ledger reconciliation done';
          icon = Icons.check_circle_outline;
          accent = Colors.green;
          showSpinner = false;
        } else {
          label = state.detail ?? 'Ledger reconciliation failed';
          icon = Icons.error_outline;
          accent = Colors.redAccent;
          showSpinner = false;
        }
      case PostGenTask.ledger:
        if (state.phase == PostGenTaskPhase.running) {
          label = state.detail ?? 'Ledger running...';
          icon = Icons.menu_book_outlined;
          accent = cs.primary;
          showSpinner = true;
        } else if (state.phase == PostGenTaskPhase.done) {
          label = state.detail ?? 'Ledger done';
          icon = Icons.check_circle_outline;
          accent = Colors.green;
          showSpinner = false;
        } else {
          label = state.detail ?? 'Ledger failed';
          icon = Icons.error_outline;
          accent = Colors.redAccent;
          showSpinner = false;
        }
      case PostGenTask.cardEvolutionObservation:
        if (state.phase == PostGenTaskPhase.running) {
          label = 'Card evolution observations running...';
          icon = Icons.manage_search_outlined;
          accent = cs.primary;
          showSpinner = true;
        } else if (state.phase == PostGenTaskPhase.done) {
          label = state.detail ?? 'Card evolution observations done';
          icon = Icons.check_circle_outline;
          accent = Colors.green;
          showSpinner = false;
        } else {
          label = state.detail ?? 'Card evolution observations failed';
          icon = Icons.error_outline;
          accent = Colors.redAccent;
          showSpinner = false;
        }
      case PostGenTask.cardRewriter:
        if (state.phase == PostGenTaskPhase.running) {
          label = 'Card Rewriter running...';
          icon = Icons.auto_fix_high_outlined;
          accent = cs.primary;
          showSpinner = true;
        } else if (state.phase == PostGenTaskPhase.done) {
          label = state.detail ?? 'Card Rewriter done';
          icon = Icons.check_circle_outline;
          accent = Colors.green;
          showSpinner = false;
        } else {
          label = state.detail ?? 'Card Rewriter failed';
          icon = Icons.error_outline;
          accent = Colors.redAccent;
          showSpinner = false;
        }
      case PostGenTask.extBlocks:
        if (state.phase == PostGenTaskPhase.running) {
          label = 'Extension blocks running...';
          icon = Icons.extension_outlined;
          accent = cs.primary;
          showSpinner = true;
        } else if (state.phase == PostGenTaskPhase.done) {
          label = state.detail ?? 'Extension blocks done';
          icon = Icons.check_circle_outline;
          accent = Colors.green;
          showSpinner = false;
        } else {
          label = 'Extension blocks failed';
          icon = Icons.error_outline;
          accent = Colors.redAccent;
          showSpinner = false;
        }
      case PostGenTask.none:
        return const SizedBox.shrink();
    }

    return ChatStatusCardShell(
      label: label,
      icon: icon,
      accent: accent,
      showSpinner: showSpinner,
      action: showSpinner
          ? IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: 'Hide status',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              // Hides the indicator only. The underlying task keeps running and
              // is cancelled from its own control, so this can never leave the
              // pipeline in a half-stopped state.
              onPressed: _dismissRunning,
            )
          : null,
    );
  }

  void _scheduleAutoDismiss(PostGenStatusState expected) {
    _watchdog?.cancel();
    _watchdog = null;
    Future<void>.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      final current = ref.read(postGenStatusProvider);
      if (identical(current, expected)) {
        ref.read(postGenStatusProvider.notifier).state =
            const PostGenStatusState.idle();
      }
    });
  }

  /// Clears a running status that nobody is left to finish.
  ///
  /// Compares logically rather than by identity: the stranded state is the very
  /// object we saw, but an equal-valued replacement is just as stuck, and the
  /// point of the watchdog is that its owner is already gone.
  void _scheduleWatchdog(PostGenStatusState expected) {
    _watchdog?.cancel();
    _watchdog = Timer(kPostGenRunningWatchdog, () {
      if (!mounted) return;
      final current = ref.read(postGenStatusProvider);
      if (current.phase != PostGenTaskPhase.running ||
          current.sessionId != expected.sessionId ||
          current.task != expected.task) {
        return;
      }
      debugPrint(
        '[PostGenStatus] watchdog cleared stranded ${expected.task.name} '
        'session=${expected.sessionId}',
      );
      ref.read(postGenStatusProvider.notifier).state =
          const PostGenStatusState.idle();
    });
  }

  void _dismissRunning() {
    _watchdog?.cancel();
    _watchdog = null;
    ref.read(postGenStatusProvider.notifier).state =
        const PostGenStatusState.idle();
  }
}
