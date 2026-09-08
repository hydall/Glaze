import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/shared_prefs_provider.dart';
import '../../widgets/glaze_background.dart';
import '../../widgets/glaze_scaffold.dart' show GlazeAppBar;
import '../animated_header_below.dart';
import '../shell_header_provider.dart';
import 'desktop_floating_provider.dart';
import 'desktop_glossary_popup.dart';
import 'desktop_layout_provider.dart';
import 'desktop_left_sidebar.dart';
import 'desktop_right_sidebar.dart';
import 'desktop_window_view.dart';
import 'sidebar_resizer.dart';

class DesktopShell extends ConsumerStatefulWidget {
  final Widget child;

  const DesktopShell({super.key, required this.child});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  LeftSidebarController? _leftController;
  RightSidebarController? _rightController;
  bool _controllersLoaded = false;

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  Future<void> _initControllers() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    _leftController = LeftSidebarController.fromPrefs(prefs);
    _rightController = RightSidebarController.fromPrefs(prefs);
    setState(() => _controllersLoaded = true);
  }

  @override
  Widget build(BuildContext context) {
    final forceMobile = ref.watch(forceMobileLayoutProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isDesktop = width >= 768 && !forceMobile;

        if (!isDesktop || !_controllersLoaded || _leftController == null) {
          return DesktopScope(isDesktop: false, child: widget.child);
        }

        return DesktopScope(
          isDesktop: true,
          child: ProviderScope(
            overrides: [
              leftSidebarControllerProvider
                  .overrideWithValue(_leftController!),
              if (_rightController != null)
                rightSidebarControllerProvider
                    .overrideWithValue(_rightController!),
            ],
            child: _buildDesktopLayout(context),
          ),
        );
      },
    );
  }

  Widget _buildDesktopLayout(BuildContext context) {
    return GlazeBackground(
      child: Stack(
        children: [
          Row(
            children: [
              DesktopLeftSidebar(),
              const VerticalDivider(width: 1, color: Colors.white10),
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
              const VerticalDivider(width: 1, color: Colors.white10),
              DesktopRightSidebar(),
            ],
          ),
          // Floating window overlay
          DesktopWindowView(
            onClose: () {
              ref.read(desktopFloatingProvider).close();
            },
          ),
          // Glossary corner popup
          const DesktopGlossaryPopup(),
        ],
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
        children: [
          ...previousChildren,
          ?currentChild,
        ],
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
