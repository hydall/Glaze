import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Branch indices of the navbar tabs (order defined in `router.dart`'s
/// `StatefulShellRoute.branches` and mirrored by `GlassNavBar`'s items).
const int kDialogsBranchIndex = 0;
const int kCharactersBranchIndex = 1;
const int kToolsBranchIndex = 2;
const int kMenuBranchIndex = 3;

/// Signal emitted when the user taps a navbar tab whose branch is **already
/// active** (a "re-tap"). Each branch's root screen listens for its own
/// [branchIndex] and returns to the top of its main view; any pushed sub-routes
/// are already popped by `goBranch(initialLocation: true)` in the shell, so the
/// screens only need to scroll their main list to the top (Characters keeps its
/// extra Discover→My fallback).
///
/// [tick] makes every re-tap a distinct value even when the same tab is tapped
/// twice in a row, so `ref.listen` always fires.
class NavReTapSignal {
  final int branchIndex;
  final int tick;

  const NavReTapSignal(this.branchIndex, this.tick);
}

class NavReTapNotifier extends Notifier<NavReTapSignal> {
  @override
  NavReTapSignal build() => const NavReTapSignal(-1, 0);

  void reTap(int branchIndex) =>
      state = NavReTapSignal(branchIndex, state.tick + 1);
}

final navReTapProvider = NotifierProvider<NavReTapNotifier, NavReTapSignal>(
  NavReTapNotifier.new,
);
