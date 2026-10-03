import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import '../../../core/navigation/router.dart';
import '../../theme/app_colors.dart';
import '../shell_header_provider.dart';
import '../title_bar_header.dart';

/// Widest the screen's title may grow in the title bar, so some empty bar is
/// always left to drag the window by.
const double _kMaxTitleWidth = 720;

/// The header of the screen in the desktop middle column, drawn inside the
/// app's title bar (see [TitleBarHeaderScope]): the app [logo] — or a back
/// button in its place — on the left, the title centred on the window, the
/// screen's actions on the right, and empty bar around them that drags the
/// window.
///
/// Follows the router, the way the shell's own header did: the header shown is
/// the one published under the branch the current location belongs to, or a
/// page's own outside the branches.
class TitleBarScreenHeader extends ConsumerWidget {
  final Widget logo;

  /// The title shown when the screen publishes no header.
  final Widget fallback;

  /// How far the bar runs on past this header's right edge (the caption
  /// buttons), so the title centres on the whole window rather than on the
  /// header alone.
  final double endInset;

  const TitleBarScreenHeader({
    super.key,
    required this.logo,
    required this.fallback,
    this.endInset = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return ListenableBuilder(
      listenable: router.routerDelegate,
      builder: (context, _) => _BranchHeader(
        branch: titleBarHeaderBranchForLocation(
          router.routerDelegate.currentConfiguration.uri.toString(),
        ),
        router: router,
        logo: logo,
        fallback: fallback,
        endInset: endInset,
      ),
    );
  }
}

class _BranchHeader extends ConsumerWidget {
  final int branch;
  final GoRouter router;
  final Widget logo;
  final Widget fallback;
  final double endInset;

  const _BranchHeader({
    required this.branch,
    required this.router,
    required this.logo,
    required this.fallback,
    required this.endInset,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(
      shellHeaderProvider.select((e) => resolveShellHeader(e, branch)),
    );
    final config = entry?.config;

    // Cross-fades on a screen switch only, like the shell header: a screen
    // updating its own title keeps the same key.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      child: config == null || config.hidden
          ? _TitleBarRow(
              key: const ValueKey('title-bar-empty'),
              leading: logo,
              middle: IgnorePointer(child: fallback),
              endInset: endInset,
            )
          : KeyedSubtree(
              key: ObjectKey(entry!.key),
              child: _HeaderRow(
                config: config,
                router: router,
                logo: logo,
                endInset: endInset,
              ),
            ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final ShellHeaderConfig config;
  final GoRouter router;
  final Widget logo;
  final double endInset;

  const _HeaderRow({
    required this.config,
    required this.router,
    required this.logo,
    required this.endInset,
  });

  @override
  Widget build(BuildContext context) {
    final title =
        config.titleWidget ??
        (config.title != null
            // Lets a drag on the text through to the bar behind it.
            ? IgnorePointer(
                child: Text(
                  config.title!,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.cs.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            : null);

    return _TitleBarRow(
      // Back, else the screen's own leading widget, else the logo — the same
      // slot the shell header's app bar filled.
      leading: config.showBack
          ? IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
              color: context.cs.primary,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed:
                  config.onBack ??
                  () {
                    if (router.canPop()) router.pop();
                  },
            )
          : config.leading ?? logo,
      middle: title,
      trailing: config.actions == null || config.actions!.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: config.actions!),
      endInset: endInset,
    );
  }
}

enum _Slot { leading, middle, trailing }

/// [leading] on the left, [trailing] on the right and [middle] centred on the
/// window, over empty bar that drags the window: a press only lands there when
/// none of the three takes it.
class _TitleBarRow extends StatelessWidget {
  final Widget leading;
  final Widget? middle;
  final Widget? trailing;
  final double endInset;

  const _TitleBarRow({
    super.key,
    required this.leading,
    this.middle,
    this.trailing,
    required this.endInset,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: DragToMoveArea(child: SizedBox.expand())),
        Positioned.fill(
          child: CustomMultiChildLayout(
            delegate: _CenteredTitleLayout(endInset),
            children: [
              LayoutId(id: _Slot.leading, child: leading),
              if (middle != null) LayoutId(id: _Slot.middle, child: middle!),
              if (trailing != null)
                LayoutId(id: _Slot.trailing, child: trailing!),
            ],
          ),
        ),
      ],
    );
  }
}

/// Centres the middle slot on the box plus [endInset] past its right edge —
/// the whole window — and slides it aside only as far as it takes to clear
/// the leading and trailing slots, the way [NavigationToolbar] does.
class _CenteredTitleLayout extends MultiChildLayoutDelegate {
  final double endInset;

  _CenteredTitleLayout(this.endInset);

  /// Space kept clear between the title and its neighbours.
  static const double _gap = 12;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    double centreY(Size child) => (size.height - child.height) / 2;

    final leading = layoutChild(_Slot.leading, loose);
    positionChild(_Slot.leading, Offset(0, centreY(leading)));

    var trailingWidth = 0.0;
    if (hasChild(_Slot.trailing)) {
      final trailing = layoutChild(_Slot.trailing, loose);
      trailingWidth = trailing.width;
      positionChild(
        _Slot.trailing,
        Offset(size.width - trailing.width, centreY(trailing)),
      );
    }

    if (hasChild(_Slot.middle)) {
      final start = leading.width + _gap;
      final end = size.width - trailingWidth - _gap;
      final available = math.max(0.0, end - start);
      final middle = layoutChild(
        _Slot.middle,
        BoxConstraints(
          maxWidth: math.min(available, _kMaxTitleWidth),
          maxHeight: size.height,
        ),
      );
      final centred = (size.width + endInset - middle.width) / 2;
      final x = centred
          .clamp(start, math.max(start, end - middle.width))
          .toDouble();
      positionChild(_Slot.middle, Offset(x, centreY(middle)));
    }
  }

  @override
  bool shouldRelayout(_CenteredTitleLayout oldDelegate) =>
      oldDelegate.endInset != endInset;
}
