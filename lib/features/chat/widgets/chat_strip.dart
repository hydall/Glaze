import 'package:flutter/widgets.dart';

import '../../../shared/shell/phone_landscape.dart';
import '../../../shared/widgets/glass_nav_bar.dart';

/// The composer's strip on a phone held sideways: a full-height column down
/// one side of the screen, the same size and place as the app's tab rail
/// ([GlassNavRail]), holding the composer's pinned buttons — and, while the
/// drawer is open, the drawer in their place.
///
/// The page draws it (`assets/chat_webview/chrome/strip.js`); this works out
/// where it goes and hands it over in the chrome layout's `strip`. The chat
/// column keeps clear of it ([reserve], see `ChatColumnWidth`).
@immutable
class ChatStrip {
  /// Along the left edge instead of the right — the side the tab rail is on.
  final bool left;

  /// From the strip's side of the screen to the strip: that side's safe-area
  /// inset (a notch or camera cutout) plus the rail's margin.
  final double edge;

  /// Width of the strip.
  final double width;

  const ChatStrip({required this.left, required this.edge, required this.width});

  /// How far in from its side of the screen the strip reaches: what the chat
  /// column has to stay clear of on that side.
  double get reserve => edge + width;

  /// The strip for the current screen, or null when there is none (anything
  /// but a phone held sideways).
  static ChatStrip? of(BuildContext context, {required bool railLeft}) {
    if (!isPhoneLandscape(context)) return null;
    final padding = MediaQuery.paddingOf(context);
    return ChatStrip(
      left: railLeft,
      edge: (railLeft ? padding.left : padding.right) + kGlassNavRailMargin,
      width: kGlassNavRailWidth,
    );
  }

  Map<String, Object> toJson() => {
    'side': left ? 'left' : 'right',
    'edge': edge,
    'width': width,
  };
}
