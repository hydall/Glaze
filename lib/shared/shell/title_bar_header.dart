import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'shell_header_provider.dart';

/// Height of the title row a screen keeps clear at the top of the desktop
/// middle column — the flush `GlazeAppBar` the shell paints there.
const double kTitleBarHiddenHeaderHeight = 56;

/// Pseudo-branch for the header of a page outside the shell branches (chat,
/// the character editor) while the app's title bar draws it. Clear of the
/// sheet windows' (-2 to -501), the glossary's (-900) and the floating
/// windows' (-1001 down).
const int kTitleBarPageHeaderBranch = -800;

/// Marks the desktop middle column while the app's own title bar draws the
/// header of the screen in it, Discord-style (Windows, custom title bar).
///
/// Screens there keep laying out as if their title row were in place — the
/// column hides that strip under the title bar — but they do not paint it:
/// they publish the title, back button and actions under
/// [titleBarHeaderBranchFor] and the title bar shows them.
class TitleBarHeaderScope extends InheritedWidget {
  const TitleBarHeaderScope({super.key, required super.child});

  /// Whether [context] sits in the middle column under the title bar.
  ///
  /// A dependency, not a lookup: the window narrowing to the mobile layout
  /// moves the column's screens out from under the scope with their state
  /// kept, and they have to hear about it to take their own header back.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TitleBarHeaderScope>() != null;

  @override
  bool updateShouldNotify(TitleBarHeaderScope oldWidget) => false;
}

/// The branch a page at [context] publishes its header under for the title
/// bar: the shell branch its location belongs to, so it takes over that
/// branch's header the way a pushed sub-screen does, or
/// [kTitleBarPageHeaderBranch] for a page outside the branches.
int titleBarHeaderBranchFor(BuildContext context) {
  try {
    final location = GoRouterState.of(context).uri.toString();
    return shellBranchForLocation(location) ?? kTitleBarPageHeaderBranch;
  } on GoError {
    // Pushed with a plain Navigator and no GoRouterState above it.
    return kTitleBarPageHeaderBranch;
  }
}

/// The branch whose header the title bar shows while the router is at
/// [location].
int titleBarHeaderBranchForLocation(String location) =>
    shellBranchForLocation(location) ?? kTitleBarPageHeaderBranch;
