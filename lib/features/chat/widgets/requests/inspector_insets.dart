import 'package:flutter/widgets.dart';

/// Bottom-inset plumbing for the Prompt Inspector's scroll surfaces.
///
/// `SheetView` does not pad its body against the Android nav bar. It publishes
/// the inset through `MediaQuery.padding.bottom` and expects the body to
/// consume it, deliberately: a scroll surface that treats the inset as *content*
/// padding keeps its viewport reaching the sheet's bottom edge, so rows stay
/// visible scrolling behind the nav bar while the last row still rests above
/// it. An outer `Padding` instead shrinks the viewport and leaves a dead strip.
///
/// A scroll view only picks the inset up when it is left to derive its own
/// padding. Passing an explicit `padding` replaces the MediaQuery-derived one
/// outright — the inset is not added to it, it is *discarded* — and every
/// scroll surface in the inspector passes its own padding, which is why each
/// one has to add the inset back by hand. Without it the last row, and the
/// buttons that sit on it, end up under the nav bar.
double inspectorBottomInset(BuildContext context) =>
    MediaQuery.paddingOf(context).bottom;

/// [base] with the sheet's bottom inset added to the bottom padding it already
/// carries. The base stays the layout's own breathing room; the inset is the
/// part that depends on the device.
EdgeInsets withInspectorBottomInset(BuildContext context, EdgeInsets base) =>
    base.copyWith(bottom: base.bottom + inspectorBottomInset(context));
