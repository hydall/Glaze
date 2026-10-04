import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

/// The live [StatefulNavigationShell], published by [ShellScreen] so widgets
/// that sit *outside* the shell can still drive branch navigation.
///
/// The desktop sidebars are built by `DesktopShell`, which wraps the shell
/// route rather than living inside it, so `StatefulNavigationShell.of(context)`
/// finds nothing there. Without this they had to fall back to
/// `context.go('/characters')`, which jumps to a branch's *root* instead of
/// restoring where that branch was left — the desktop left sidebar replaces the
/// bottom nav bar, so it should switch branches the same way the bar does.
final shellNavigationProvider = StateProvider<StatefulNavigationShell?>(
  (ref) => null,
);

/// Switches to [branchIndex] the way [GlassNavBar] does: restore the branch's
/// last location, or reset it to the branch root when it is already current.
///
/// Falls back to [fallbackLocation] when the shell has not published itself yet
/// (the very first frame, or a test that mounts a screen standalone).
void goShellBranch(
  BuildContext context,
  WidgetRef ref,
  int branchIndex, {
  required String fallbackLocation,
}) {
  final shell = ref.read(shellNavigationProvider);
  if (shell == null) {
    context.go(fallbackLocation);
    return;
  }
  shell.goBranch(
    branchIndex,
    initialLocation: branchIndex == shell.currentIndex,
  );
}
