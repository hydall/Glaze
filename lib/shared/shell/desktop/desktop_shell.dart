import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/shared_prefs_provider.dart';
import '../../widgets/glaze_background.dart';
import '../../widgets/glaze_scaffold.dart' show GlazeAppBar;
import '../animated_header_below.dart';
import '../shell_header_provider.dart';
import 'desktop_file_drop.dart';
import 'desktop_floating_provider.dart';
import 'desktop_glossary_popup.dart';
import 'desktop_layout_provider.dart';
import 'desktop_left_sidebar.dart';
import 'desktop_right_sidebar.dart';
import 'desktop_window_view.dart';
import 'sidebar_resizer.dart';
import 'sidebar_sheet_provider.dart';

class DesktopShell extends ConsumerStatefulWidget {
  final Widget child;

  const DesktopShell({super.key, required this.child});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  late LeftSidebarController _leftController;
  late RightSidebarController _rightController;

  @override
  void initState() {
    super.initState();
    // Prefs are usually already resolved by the time the first frame builds, so
    // read them synchronously when we can: awaiting here rendered a frame of
    // the *phone* layout before the sidebars appeared, which read as a jump on
    // every cold start. When they are genuinely not ready yet, start from the
    // defaults and adopt the stored widths as soon as they land.
    final cached = ref.read(sharedPreferencesProvider).value;
    _leftController = LeftSidebarController.fromPrefs(cached);
    _rightController = RightSidebarController.fromPrefs(cached);
    if (cached == null) _adoptStoredWidths();
  }

  Future<void> _adoptStoredWidths() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    setState(() {
      _leftController.applyPrefs(prefs);
      _rightController.applyPrefs(prefs);
    });
  }

  /// On desktop the `/` branch (chat history) is already the left sidebar, so a
  /// window that grows past the breakpoint — or a user turning "force mobile
  /// layout" off — would be left staring at a duplicate list in the middle
  /// column. The router's redirect only fires on navigation, so migrate here
  /// too, exactly as the Vue app's `checkDesktop()` did.
  void _migrateRootRoute(BuildContext context) {
    if (GoRouterState.of(context).uri.path != '/') return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (GoRouterState.of(context).uri.path != '/') return;
      context.go('/characters');
    });
  }

  @override
  Widget build(BuildContext context) {
    final forceMobile = ref.watch(forceMobileLayoutProvider);
    // Watched here, not inside the LayoutBuilder: that builder runs during
    // layout rather than build, where `ref.watch` does not register a
    // dependency and the layout would not react to the panel opening.
    final hasPanel = ref.watch(rightSidebarPanelProvider) != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isDesktop = width >= kDesktopWidthBreakpoint && !forceMobile;

        if (!isDesktop) {
          return DesktopScope(isDesktop: false, child: widget.child);
        }

        _migrateRootRoute(context);

        return DesktopScope(
          isDesktop: true,
          child: ProviderScope(
            overrides: [
              leftSidebarControllerProvider.overrideWithValue(_leftController),
              rightSidebarControllerProvider.overrideWithValue(
                _rightController,
              ),
            ],
            child: _buildDesktopLayout(context, width, hasPanel),
          ),
        );
      },
    );
  }

  /// Which sidebar entry should read as active, derived from the route (plus
  /// the floating-window state, which does not change the route).
  String _currentView(BuildContext context) {
    if (ref.watch(desktopFloatingStackProvider).isNotEmpty) return 'menu';
    final segments = GoRouterState.of(context).uri.pathSegments;
    if (segments.isEmpty) return 'dialogs';
    switch (segments.first) {
      case 'characters':
        return 'characters';
      case 'chat':
        return 'chat';
      case 'tools':
        return 'tools';
      case 'menu':
        return 'menu';
      default:
        return '';
    }
  }

  /// Escape closes the topmost desktop overlay, innermost first.
  ///
  /// Flutter's default `DismissIntent` only pops modal *routes*; the floating
  /// window, the glossary popup and the sidebar panel are all plain widgets in
  /// this stack, so Escape did nothing for them. Mirrors the Vue app's
  /// hierarchical Escape handler.
  KeyEventResult _handleEscape(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (ref.read(desktopFloatingStackProvider).isNotEmpty) {
      ref.read(desktopFloatingProvider).pop();
      return KeyEventResult.handled;
    }
    if (ref.read(glossaryPopupVisibleProvider)) {
      ref.read(glossaryPopupVisibleProvider.notifier).state = false;
      return KeyEventResult.handled;
    }
    if (ref.read(rightSidebarPanelProvider) != null) {
      ref.read(rightSidebarPanelProvider.notifier).state = null;
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Minimum the middle column must keep before a sidebar gives up width.
  static const double _middleMinWidth = 420;

  /// Fits both sidebars into [total], shrinking them to their icon strips when
  /// the window cannot afford the widths the user dragged them to.
  ///
  /// The breakpoint is 768px (as in the Vue app), but two 280/300px sidebars
  /// leave barely 200px of content there — the character grid's header row
  /// overflowed outright. The right sidebar yields first, then the left.
  ({double left, double right}) _fitSidebars(double total, bool hasPanel) {
    double snap(double value) =>
        value < kSidebarCollapseThreshold ? kSidebarCollapsedWidth : value;

    var left = _leftController.width;
    // A mounted tool panel needs a floor, whatever width the sidebar was
    // dragged to (Vue auto-expanded the sidebar when a sheet opened in it).
    var right = hasPanel
        ? math.max(
            _rightController.width,
            RightSidebarController.widthWithPanel,
          )
        : _rightController.width;
    if (total - left - right >= _middleMinWidth) {
      return (left: left, right: right);
    }

    right = snap(
      math.max(
        kSidebarCollapsedWidth,
        math.min(right, total - _middleMinWidth - left),
      ),
    );
    if (total - left - right >= _middleMinWidth) {
      return (left: left, right: right);
    }

    left = snap(
      math.max(
        kSidebarCollapsedWidth,
        math.min(left, total - _middleMinWidth - right),
      ),
    );
    return (left: left, right: right);
  }

  Widget _buildDesktopLayout(
    BuildContext context,
    double availableWidth,
    bool hasPanel,
  ) {
    final widths = _fitSidebars(availableWidth, hasPanel);
    return Focus(
      autofocus: true,
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleEscape,
      child: DesktopFileDrop(
        child: GlazeBackground(
          child: Stack(
            children: [
              Row(
                children: [
                  DesktopLeftSidebar(
                    currentView: _currentView(context),
                    width: widths.left,
                  ),
                  Expanded(
                    child: RepaintBoundary(
                      child: Stack(
                        children: [
                          widget.child,
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: _DesktopHeader(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  DesktopRightSidebar(width: widths.right),
                ],
              ),
              // Floating window overlay
              const DesktopWindowView(),
              // Glossary corner popup
              const DesktopGlossaryPopup(),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopHeader extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.toString();

    final branchIndex = shellBranchForLocation(location);
    if (branchIndex == null) return const SizedBox.shrink();

    final entry = ref.watch(
      shellHeaderProvider.select((e) => resolveShellHeader(e, branchIndex)),
    );

    // Only the app-bar row cross-fades on a screen switch; the `below` slot is
    // hoisted out below so it animates on its own (see [AnimatedHeaderBelow]).
    final appBar = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      // See _PersistentHeader in shell_screen.dart: top-align so the app-bar
      // rows stay flush with the header's top edge during the cross-fade.
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        children: [...previousChildren, ?currentChild],
      ),
      child: entry == null || entry.config.hidden
          ? const SizedBox.shrink(key: ValueKey('desktop-header-empty'))
          : KeyedSubtree(
              key: ObjectKey(entry.key),
              child: GlazeAppBar(
                title: entry.config.title,
                titleWidget: entry.config.titleWidget,
                actions: entry.config.actions,
                showBack: entry.config.showBack,
                onBack: entry.config.onBack,
                borderRadius: BorderRadius.zero,
              ),
            ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        appBar,
        // Decoupled from the app bar's cross-fade so that switching to a screen
        // without a segmented control slides the control up and out on its own,
        // instead of plain-fading with the rest of the header.
        AnimatedHeaderBelow(
          below: entry == null || entry.config.hidden
              ? null
              : entry.config.below,
        ),
      ],
    );
  }
}
