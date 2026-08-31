import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../widgets/glass_nav_bar.dart';
import '../widgets/glaze_background.dart';
import '../widgets/glaze_scaffold.dart' show GlazeAppBar;
import '../widgets/glaze_toast.dart';
import 'animated_header_below.dart';
import 'nav_bar_suppression_provider.dart';
import 'nav_height_provider.dart';
import 'shell_header_provider.dart';
import 'shell_navigation_provider.dart';
import 'desktop/desktop_layout_provider.dart';

class ShellScreen extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;
  const ShellScreen({super.key, required this.navigationShell});

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen> {
  int _lastBackPress = 0;
  int? _lastBranchIndex;

  /// Reveals the header of a branch the moment it becomes active. Branch state
  /// (including each list's scroll offset) is preserved by the shell, and the
  /// hidden flag is branch-scoped, so a tab left scrolled down would otherwise
  /// come back with its header still slid off-screen and no way to recover it
  /// but scrolling up. Screens keep their own hide-on-scroll tracker in sync by
  /// watching [shellHeaderHiddenProvider].
  void _revealHeaderOnBranchChange(int currentIndex) {
    if (_lastBranchIndex == currentIndex) return;
    _lastBranchIndex = currentIndex;
    // Deferred: this runs during build, where mutating a provider is forbidden.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(
        shellHeaderHiddenProvider(currentIndex).notifier,
      );
      if (notifier.state) notifier.state = false;
    });
  }

  /// Screens pad their bodies by [navHeightProvider], which [GlassNavBar]
  /// publishes once on mount and never clears. A suppressed bar — or the
  /// desktop layout, where the bar does not exist at all — would leave that
  /// stale height behind as an empty strip, so zero it while the bar is gone;
  /// it re-measures when it comes back.
  void _clearNavHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(navHeightProvider.notifier);
      if (notifier.state != 0) notifier.state = 0;
    });
  }

  /// Publishes the shell so widgets outside it (the desktop sidebars) can
  /// drive branch navigation. Deferred: mutating a provider during build is
  /// forbidden.
  void _publishShell() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(shellNavigationProvider.notifier);
      if (!identical(notifier.state, widget.navigationShell)) {
        notifier.state = widget.navigationShell;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = widget.navigationShell.currentIndex;
    _publishShell();
    _revealHeaderOnBranchChange(currentIndex);
    final location = GoRouterState.of(context).uri.toString();
    final isDesktop = isDesktopLayout(context);

    // The branch cross-fade is owned entirely by [FadeBranchContainer] (the
    // shell's navigatorContainerBuilder). Do NOT wrap navigationShell in a
    // second FadeTransition here: stacking a shorter outer fade over the inner
    // cross-fade un-dims the still-fading-out previous branch the instant the
    // outer fade completes, flashing a frame of the previous screen at the end
    // of the transition (most visible on iOS).
    if (isDesktop) {
      // [GlassNavBar] never mounts here, but it may have published its height
      // before the layout switched (the desktop layout can be entered at
      // runtime by turning "force mobile layout" off). That stale value is
      // read by every screen's bottom padding and by [SheetView], so it would
      // reserve an empty strip along the bottom of the desktop layout until
      // the app restarts. Zero it for as long as the desktop layout is live.
      _clearNavHeight();
      return widget.navigationShell;
    }

    final isIosLikeTargetPlatform =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final hideNavBarRoutes = <String>{
      '/menu/about',
      '/menu/settings',
      '/menu/themes',
    };
    // A full-height editor can claim the bar away while it is open (see
    // [NavBarSuppressor]); route-based hiding alone cannot see it, because such
    // an editor lives inline inside a sheet rather than on its own route.
    final navSuppressed = ref.watch(navBarSuppressionProvider).isNotEmpty;
    if (navSuppressed) _clearNavHeight();
    final showNavBar =
        !navSuppressed &&
        !location.startsWith('/chat/') &&
        !hideNavBarRoutes.any((r) => location.startsWith(r));
    return GlazeBackground(
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (isIosLikeTargetPlatform) return;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastBackPress < 2000) {
            SystemNavigator.pop();
          } else {
            _lastBackPress = now;
            GlazeToast.show(context, 'nav_press_again_to_exit'.tr());
          }
        },
        child: Scaffold(
          extendBody: true,
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Positioned.fill(child: widget.navigationShell),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _PersistentHeader(branchIndex: currentIndex),
              ),
            ],
          ),
          bottomNavigationBar: showNavBar
              ? GlassNavBar(
                  currentIndex: currentIndex,
                  onTap: (index) => widget.navigationShell.goBranch(
                    index,
                    initialLocation: index == currentIndex,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

/// The shell's single persistent header. Stays mounted across tab switches and
/// pushed sub-screens; only its content cross-fades, driven by whichever screen
/// of [branchIndex] currently owns the header (see [shellHeaderProvider]).
class _PersistentHeader extends ConsumerWidget {
  final int branchIndex;
  const _PersistentHeader({required this.branchIndex});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(
      shellHeaderProvider.select((e) => resolveShellHeader(e, branchIndex)),
    );
    // Slides/fades the whole header out of view while the branch's list scrolls
    // down, in step with any chrome the screen pins beneath it (e.g. the
    // character list's tabs row), mirroring the chat header's hide-on-scroll.
    final hidden = ref.watch(shellHeaderHiddenProvider(branchIndex));

    // Only the app-bar row cross-fades on a screen switch; the `below` slot is
    // hoisted out below so it animates on its own (see [AnimatedHeaderBelow]).
    final appBar = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      // Default layoutBuilder stacks children with Alignment.center; top-align
      // instead so the app-bar rows stay flush with the header's top edge
      // throughout the cross-fade rather than snapping when one is disposed.
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        children: [...previousChildren, ?currentChild],
      ),
      child: entry == null || entry.config.hidden
          ? const SizedBox.shrink(key: ValueKey('shell-header-empty'))
          : KeyedSubtree(
              key: ObjectKey(entry.key),
              child: GlazeAppBar(
                title: entry.config.title,
                titleWidget: entry.config.titleWidget,
                actions: entry.config.actions,
                showBack: entry.config.showBack,
                onBack: entry.config.onBack,
              ),
            ),
    );

    final content = SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            appBar,
            // Decoupled from the app bar's cross-fade so that switching to a
            // screen without a segmented control slides the control up and out
            // on its own, instead of plain-fading with the rest of the header.
            AnimatedHeaderBelow(
              below: entry == null || entry.config.hidden
                  ? null
                  : entry.config.below,
            ),
          ],
        ),
      ),
    );

    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedSlide(
        offset: hidden ? const Offset(0, -1.4) : Offset.zero,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: hidden ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          child: content,
        ),
      ),
    );
  }
}

/// Cross-fade branch container, ported from the Vue `<Transition name="fade">`
/// used in `src/App.vue`. While switching branches both old and new are
/// visible — old fades 1 → 0 and new fades 0 → 1 simultaneously over 200ms
/// with a CSS `ease` curve.
class FadeBranchContainer extends StatefulWidget {
  final int currentIndex;
  final List<Widget> children;

  const FadeBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  @override
  State<FadeBranchContainer> createState() => _FadeBranchContainerState();
}

class _FadeBranchContainerState extends State<FadeBranchContainer>
    with SingleTickerProviderStateMixin {
  // CSS `ease` ≈ cubic-bezier(0.25, 0.1, 0.25, 1.0)
  static const _curve = Cubic(0.25, 0.1, 0.25, 1.0);
  static const _duration = Duration(milliseconds: 200);

  late final AnimationController _controller;
  late int _displayIndex;
  late int _previousIndex;

  @override
  void initState() {
    super.initState();
    _displayIndex = widget.currentIndex;
    _previousIndex = widget.currentIndex;
    _controller = AnimationController(
      vsync: this,
      duration: _duration,
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(FadeBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex != _displayIndex) {
      _previousIndex = _displayIndex;
      _displayIndex = widget.currentIndex;
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _curve.transform(_controller.value);
        final animating = _controller.status == AnimationStatus.forward;
        return Stack(
          fit: StackFit.expand,
          children: [
            for (int i = 0; i < widget.children.length; i++)
              _buildBranch(i, widget.children[i], t, animating),
          ],
        );
      },
    );
  }

  Widget _buildBranch(int i, Widget child, double t, bool animating) {
    final isCurrent = i == _displayIndex;
    final isPrevious = i == _previousIndex && _previousIndex != _displayIndex;
    final involved = isCurrent || isPrevious;

    final opacity = isCurrent ? t : (isPrevious ? (1.0 - t) : 0.0);

    // Detach the branch (state is preserved by the shell) when it is not part
    // of the active cross-fade, or once the outgoing branch's fade-out has
    // fully settled. Detaching only after the animation completes — from an
    // already-faded state — avoids a one-frame full-opacity blink of native
    // platform views (the chat WebView) that snapping to Offstage mid-fade
    // produced.
    final offstage = !involved || (isPrevious && !animating);

    // A single, stable widget structure for every state (only the booleans
    // change) so the InAppWebView element is never re-parented as a branch
    // moves between idle / fading / detached — re-parenting re-attaches the
    // native surface and flashes a stale frame.
    return IgnorePointer(
      ignoring: !isCurrent || animating,
      child: Offstage(
        offstage: offstage,
        child: TickerMode(
          enabled: involved,
          child: Opacity(opacity: opacity, child: child),
        ),
      ),
    );
  }
}
