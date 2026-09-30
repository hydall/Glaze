import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/backup/backup_screen.dart';
import '../../../features/cloud_sync/widgets/sync_sheet.dart';
import '../../../features/menu/about_screen.dart';
import '../../../features/menu/menu_screen.dart';
import '../../../features/settings/app_settings_screen.dart';
import '../../../features/settings/theme_preset_screen.dart';
import '../../theme/app_colors.dart';
import '../../widgets/glass_surface.dart';
import '../shell_header_provider.dart';
import 'desktop_floating_provider.dart';
import 'desktop_window_geometry.dart';

/// Size a floating window opens at — Vue's `WindowView`: 620px wide, 82% of
/// the window tall (capped by [defaultWindowRect]).
Size _preferredWindowSize(Size bounds) => Size(620, bounds.height * 0.82);

/// The desktop floating windows — Vue's `WindowView` in "panel" mode, grown
/// into a small window manager.
///
/// Hosts the Menu and everything reachable from it on top of the three-column
/// layout. Windows are not modal: each can be moved by its title bar, resized
/// from its edges, minimized, maximized and raised by clicking it, and several
/// can be open at once. A dock at the bottom switches between them once there
/// is more than one (or one is minimized).
class DesktopWindowView extends ConsumerWidget {
  const DesktopWindowView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windows = ref.watch(desktopWindowsProvider);
    if (windows.isEmpty) return const SizedBox.shrink();
    final focusedId = ref.read(desktopWindowsProvider.notifier).focused?.id;
    final showDock = windows.length > 1 || windows.any((w) => w.minimized);

    return LayoutBuilder(
      builder: (context, constraints) {
        final bounds = constraints.biggest;
        return Stack(
          children: [
            // Keyed and kept mounted while minimized, so raising a window or
            // restoring it keeps its screen's state (scroll, search, …).
            for (final window in windows)
              Positioned.fill(
                key: ValueKey(window.id),
                child: Offstage(
                  offstage: window.minimized,
                  child: TickerMode(
                    enabled: !window.minimized,
                    child: Stack(
                      children: [
                        _DesktopWindow(
                          window: window,
                          bounds: bounds,
                          focused: window.id == focusedId,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (showDock)
              Positioned(
                left: 0,
                right: 0,
                bottom: 12,
                child: Center(
                  child: _WindowDock(windows: windows, focusedId: focusedId),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DesktopWindow extends ConsumerWidget {
  final DesktopWindow window;
  final Size bounds;
  final bool focused;

  const _DesktopWindow({
    required this.window,
    required this.bounds,
    required this.focused,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windows = ref.read(desktopWindowsProvider.notifier);
    final id = window.id;
    final rect = window.maximized
        ? Offset.zero & bounds
        : clampWindowRect(
            window.rect ??
                defaultWindowRect(
                  bounds,
                  _preferredWindowSize(bounds),
                  cascade: window.cascade,
                ),
            bounds,
          );

    return DesktopWindowGeometry(
      rect: rect,
      bounds: bounds,
      movable: !window.maximized,
      resizable: !window.maximized,
      onChanged: (rect) => windows.setRect(id, rect),
      onToggleMaximize: () => windows.toggleMaximize(id),
      child: Listener(
        // Raise on any press inside, before the press does anything else —
        // a Listener takes no part in the gesture arena, so the tap still
        // reaches whatever it landed on.
        onPointerDown: (_) => windows.focus(id),
        child: DesktopWindowScope(
          windowId: id,
          child: _OpenAnimation(
            child: _WindowFrame(
              window: window,
              focused: focused,
              maximized: window.maximized,
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades and lifts a window in the first time it is built.
class _OpenAnimation extends StatelessWidget {
  final Widget child;

  const _OpenAnimation({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 16),
          child: child,
        ),
      ),
    );
  }
}

class _WindowFrame extends ConsumerWidget {
  final DesktopWindow window;
  final bool focused;
  final bool maximized;

  const _WindowFrame({
    required this.window,
    required this.focused,
    required this.maximized,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windows = ref.read(desktopWindowsProvider.notifier);
    final id = window.id;
    final viewId = window.activeView;
    // Everything hosted here publishes its header under this window's own
    // pseudo-branch (see [DetachedShellHost.headerBranch]), so the title bar
    // shows this window's screen even with other windows open.
    final branch = desktopWindowHeaderBranch(id);
    final entry = ref.watch(
      shellHeaderProvider.select((e) => resolveShellHeader(e, branch)),
    );
    final radius = BorderRadius.circular(maximized ? 0 : 16);

    return GlassSurface(
      borderRadius: radius,
      border: Border.all(
        color: focused
            ? context.cs.outlineVariant
            : context.cs.outlineVariant.withValues(alpha: 0.5),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: focused ? 0.5 : 0.3),
          blurRadius: focused ? 40 : 24,
          spreadRadius: focused ? 4 : 0,
        ),
      ],
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          children: [
            DesktopWindowMoveArea(
              child: _TitleBar(
                title: entry?.config.title ?? desktopWindowTitle(viewId),
                titleWidget: entry?.config.titleWidget,
                actions: entry?.config.actions ?? const [],
                focused: focused,
                maximized: maximized,
                onBack: window.canGoBack ? () => windows.pop(id) : null,
                onDetach: window.canGoBack ? () => windows.detach(id) : null,
                onMinimize: () => windows.minimize(id),
                onToggleMaximize: () => windows.toggleMaximize(id),
                onClose: () => windows.close(id),
              ),
            ),
            Divider(height: 1, color: context.cs.outlineVariant),
            Expanded(
              child: DetachedShellHost(
                hasChrome: true,
                headerBranch: branch,
                // Keyed by depth and view, so stepping back rebuilds the
                // screen underneath instead of reusing the one popped off.
                child: KeyedSubtree(
                  key: ValueKey('${window.stack.length}:$viewId'),
                  child: desktopWindowContent(viewId),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Title of [viewId] for when its screen has not published a header (yet) —
/// also what the dock labels a window with.
String desktopWindowTitle(String viewId) => switch (viewId) {
  'menu' => 'menu_menu_title'.tr(),
  'settings' => 'menu_app_settings'.tr(),
  'theme-settings' => 'theme_presets'.tr(),
  'about' => 'menu_about'.tr(),
  'sync' => 'menu_cloud_sync'.tr(),
  'backup' => 'menu_backup'.tr(),
  _ => '',
};

IconData _windowIcon(String viewId) => switch (viewId) {
  'menu' => Icons.menu_rounded,
  'settings' => Icons.settings_rounded,
  'theme-settings' => Icons.palette_rounded,
  'about' => Icons.info_outline_rounded,
  'sync' => Icons.cloud_sync_rounded,
  'backup' => Icons.backup_rounded,
  _ => Icons.web_asset_rounded,
};

/// The screen a floating window shows for [viewId]. Every id in
/// [desktopFloatingViews] must resolve here.
Widget desktopWindowContent(String viewId) => switch (viewId) {
  'menu' => const MenuScreen(),
  'settings' => const AppSettingsScreen(),
  'theme-settings' => const ThemePresetScreen(),
  'about' => const AboutScreen(),
  'sync' => const SyncSheet(),
  'backup' => const BackupScreen(),
  _ => const SizedBox.shrink(),
};

class _TitleBar extends StatelessWidget {
  final String title;
  final Widget? titleWidget;
  final List<Widget> actions;
  final bool focused;
  final bool maximized;
  final VoidCallback? onBack;
  final VoidCallback? onDetach;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;

  const _TitleBar({
    required this.title,
    required this.titleWidget,
    required this.actions,
    required this.focused,
    required this.maximized,
    required this.onBack,
    required this.onDetach,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final chromeColor = focused
        ? context.cs.onSurfaceVariant
        : context.cs.onSurfaceVariant.withValues(alpha: 0.6);

    Widget chromeButton(
      IconData icon,
      String tooltip,
      VoidCallback onPressed, {
      double size = 18,
    }) => IconButton(
      icon: Icon(icon, size: size),
      color: chromeColor,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );

    return SizedBox(
      height: kDesktopWindowTitleBarHeight + 4,
      child: Row(
        children: [
          const SizedBox(width: 4),
          if (onBack != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onBack,
            )
          else
            const SizedBox(width: 12),
          Expanded(
            child:
                titleWidget ??
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: focused
                        ? context.cs.onSurface
                        : context.cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
          ),
          ...actions,
          if (onDetach != null)
            chromeButton(
              Icons.open_in_new_rounded,
              'desktop_window_detach'.tr(),
              onDetach!,
            ),
          chromeButton(
            Icons.minimize_rounded,
            'desktop_window_minimize'.tr(),
            onMinimize,
          ),
          chromeButton(
            maximized ? Icons.fullscreen_exit_rounded : Icons.crop_square_rounded,
            maximized
                ? 'desktop_window_restore'.tr()
                : 'desktop_window_maximize'.tr(),
            onToggleMaximize,
          ),
          chromeButton(
            Icons.close_rounded,
            MaterialLocalizations.of(context).closeButtonTooltip,
            onClose,
            size: 20,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// The strip that switches between floating windows: one entry per window,
/// the focused one highlighted. Clicking an entry raises (or restores) its
/// window; clicking the focused one minimizes it, as a taskbar does.
class _WindowDock extends ConsumerWidget {
  final List<DesktopWindow> windows;
  final int? focusedId;

  const _WindowDock({required this.windows, required this.focusedId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Listed in the order the windows were opened, not by stacking order, so
    // raising a window does not shuffle the dock under the cursor.
    final ordered = [...windows]..sort((a, b) => a.id.compareTo(b.id));
    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: context.cs.outlineVariant),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 24,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final window in ordered)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _DockEntry(
                  window: window,
                  focused: window.id == focusedId,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DockEntry extends ConsumerWidget {
  final DesktopWindow window;
  final bool focused;

  const _DockEntry({required this.window, required this.focused});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windows = ref.read(desktopWindowsProvider.notifier);
    final viewId = window.activeView;
    final headerTitle = ref.watch(
      shellHeaderProvider.select(
        (e) => resolveShellHeader(
          e,
          desktopWindowHeaderBranch(window.id),
        )?.config.title,
      ),
    );
    final title = headerTitle ?? desktopWindowTitle(viewId);
    final color = focused
        ? context.cs.primary
        : context.cs.onSurface.withValues(
            alpha: window.minimized ? 0.55 : 0.85,
          );

    return Tooltip(
      message: title,
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => focused
              ? windows.minimize(window.id)
              : windows.focus(window.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            constraints: const BoxConstraints(maxWidth: 200),
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            decoration: BoxDecoration(
              color: focused
                  ? context.cs.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_windowIcon(viewId), size: 16, color: color),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: focused ? FontWeight.w600 : FontWeight.w500,
                      color: color,
                      fontStyle: window.minimized ? FontStyle.italic : null,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                SizedBox.square(
                  dimension: 24,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 14,
                    icon: const Icon(Icons.close_rounded),
                    color: context.cs.onSurfaceVariant,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => windows.close(window.id),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
