import 'package:flutter/widgets.dart';

import 'desktop/desktop_layout_provider.dart';

/// Whether a viewport of [size] is a phone held sideways: wider than tall, and
/// too short to count as a tablet.
///
/// Such a screen keeps the phone layout (see `isDesktopViewportSize`), but its
/// height is the scarce side, so the shell moves the tab bar from the bottom to
/// a rail along the side and the chat keeps its column to a readable width.
bool isPhoneLandscapeSize(Size size) =>
    size.width > size.height &&
    size.shortestSide < kTabletShortestSideBreakpoint;

/// [isPhoneLandscapeSize] for the current screen, and only while the phone
/// layout is active — a desktop window that happens to be short and wide keeps
/// its desktop layout.
bool isPhoneLandscape(BuildContext context) =>
    !isDesktopLayout(context) && isPhoneLandscapeSize(MediaQuery.sizeOf(context));

/// Widest the chat column grows on a phone held sideways. A full 900-pixel line
/// runs past 120 characters, about twice a comfortable reading length.
const double kPhoneLandscapeChatMaxWidth = 720;
