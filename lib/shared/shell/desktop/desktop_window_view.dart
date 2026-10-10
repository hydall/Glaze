import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/backup/backup_screen.dart';
import '../../../features/catalog/widgets/third_party_providers_screen.dart';
import '../../../features/character_list/character_editor_screen.dart';
import '../../../features/cloud_sync/widgets/sync_sheet.dart';
import '../../../features/diagnostics/log_viewer_screen.dart';
import '../../../features/diagnostics/logs_screen.dart';
import '../../../features/menu/about_screen.dart';
import '../../../features/menu/hall_of_fame_screen.dart';
import '../../../features/lorebooks/lorebook_editor_screen.dart';
import '../../../features/menu/menu_screen.dart';
import '../../../features/personas/persona_list_screen.dart';
import '../../../features/presets/preset_editor_screen.dart';
import '../../../features/regex/regex_sheet.dart';
import '../../../features/settings/app_settings_screen.dart';
import '../../../features/settings/theme_editor_screen.dart';
import '../../../features/settings/theme_preset_screen.dart';
import '../../theme/app_colors.dart';
import '../../widgets/glass_surface.dart';
import '../shell_header_provider.dart';
import 'desktop_active_surface_provider.dart';
import 'desktop_floating_provider.dart';
import 'desktop_window_chrome.dart';
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
class DesktopWindowView extends ConsumerStatefulWidget {
  const DesktopWindowView({super.key});

  @override
  ConsumerState<DesktopWindowView> createState() => _DesktopWindowViewState();
}

class _DesktopWindowViewState extends ConsumerState<DesktopWindowView> {
  /// The windows of the last build, to tell which ones have just closed.
  List<DesktopWindow> _shown = const [];

  /// Windows already closed but still fading out, drawn as they last were.
  /// Their screens stay mounted for that, but take no more input.
  final List<DesktopWindow> _closing = [];

  @override
  Widget build(BuildContext context) {
    ref.listen(
      desktopWindowsProvider,
      (previous, next) => _syncActiveSurface(ref, previous ?? const [], next),
    );
    final windows = ref.watch(desktopWindowsProvider);
    for (final window in _shown) {
      if (!windows.any((w) => w.id == window.id)) _closing.add(window);
    }
    _shown = windows;
    if (windows.isEmpty && _closing.isEmpty) return const SizedBox.shrink();
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
              _buildWindow(window, bounds, closing: false),
            // On top: a window is closed from its own title bar or the dock,
            // so it is almost always the one in front anyway.
            for (final window in _closing)
              _buildWindow(window, bounds, closing: true),
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

  Widget _buildWindow(
    DesktopWindow window,
    Size bounds, {
    required bool closing,
  }) {
    return Positioned.fill(
      key: ValueKey(window.id),
      child: _WindowPresence(
        visible: !closing && !window.minimized,
        onHidden: closing
            ? () =>
                  setState(() => _closing.removeWhere((w) => w.id == window.id))
            : null,
        child: IgnorePointer(
          ignoring: closing,
          child: Stack(
            children: [_DesktopWindow(window: window, bounds: bounds)],
          ),
        ),
      ),
    );
  }

  /// Keeps the active window in step with the window list: a window raised
  /// any way other than a click (opened, cycled to, restored from the dock)
  /// becomes the active one, and a closed or minimized one stops being it.
  void _syncActiveSurface(
    WidgetRef ref,
    List<DesktopWindow> previous,
    List<DesktopWindow> next,
  ) {
    final surfaces = ref.read(desktopActiveSurfaceProvider.notifier);
    for (final window in previous) {
      final now = next.where((w) => w.id == window.id).firstOrNull;
      if (now == null || now.minimized) {
        surfaces.release(desktopWindowSurface(window.id));
      }
    }
    final raised = topmostVisibleWindow(next);
    if (raised != null && raised.id != topmostVisibleWindow(previous)?.id) {
      surfaces.activate(desktopWindowSurface(raised.id));
    }
  }
}

class _DesktopWindow extends ConsumerWidget {
  final DesktopWindow window;
  final Size bounds;

  const _DesktopWindow({required this.window, required this.bounds});

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
        onPointerDown: (_) {
          windows.focus(id);
          ref
              .read(desktopActiveSurfaceProvider.notifier)
              .activate(desktopWindowSurface(id));
        },
        child: DesktopWindowScope(
          windowId: id,
          child: _WindowFrame(window: window, maximized: window.maximized),
        ),
      ),
    );
  }
}

/// Fades and lifts a window in when it opens or is restored, and back out
/// when it is minimized or closed; [onHidden] runs once it is all the way out.
///
/// Out of sight the window goes offstage with its tickers paused, but stays
/// mounted, so restoring it keeps its screen's state.
class _WindowPresence extends StatefulWidget {
  final bool visible;
  final VoidCallback? onHidden;
  final Widget child;

  const _WindowPresence({
    required this.visible,
    this.onHidden,
    required this.child,
  });

  @override
  State<_WindowPresence> createState() => _WindowPresenceState();
}

class _WindowPresenceState extends State<_WindowPresence>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 150),
  )..addStatusListener(_onStatus);

  late final Animation<double> _t = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.visible) _ctrl.forward();
  }

  @override
  void didUpdateWidget(_WindowPresence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _ctrl.forward();
    } else if (_ctrl.isDismissed) {
      // Closed while minimized: already out, nothing to play. Deferred, as
      // the callback rebuilds the parent that is building this.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onHidden?.call();
      });
    } else {
      _ctrl.reverse();
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    setState(() {});
    widget.onHidden?.call();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hidden = !widget.visible && _ctrl.isDismissed;
    return Offstage(
      offstage: hidden,
      child: TickerMode(
        enabled: !hidden,
        child: AnimatedBuilder(
          animation: _t,
          child: widget.child,
          builder: (context, child) => Opacity(
            opacity: _t.value,
            child: Transform.translate(
              offset: Offset(0, (1 - _t.value) * 16),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowFrame extends ConsumerWidget {
  final DesktopWindow window;
  final bool maximized;

  const _WindowFrame({required this.window, required this.maximized});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windows = ref.read(desktopWindowsProvider.notifier);
    final id = window.id;
    final viewId = window.activeView;
    final active = ref.watch(
      desktopSurfaceActiveProvider(desktopWindowSurface(id)),
    );
    // Everything hosted here publishes its header under this window's own
    // pseudo-branch (see [DetachedShellHost.headerBranch]), so the title bar
    // shows this window's screen even with other windows open.
    final branch = desktopWindowHeaderBranch(id);
    final entry = ref.watch(
      shellHeaderProvider.select((e) => resolveShellHeader(e, branch)),
    );

    return DesktopWindowFrame(
      active: active,
      maximized: maximized,
      titleBar: DesktopWindowMoveArea(
        child: DesktopWindowTitleBar(
          title: entry?.config.title ?? desktopWindowTitle(viewId),
          titleWidget: entry?.config.titleWidget,
          actions: entry?.config.actions ?? const [],
          active: active,
          maximized: maximized,
          // A step back inside the screen (an entry editor to its list) comes
          // before stepping the window back.
          onBack:
              entry?.config.innerBack ??
              (window.canGoBack ? () => windows.pop(id) : null),
          onDetach: window.canGoBack ? () => windows.detach(id) : null,
          onMinimize: () => windows.minimize(id),
          onToggleMaximize: () => windows.toggleMaximize(id),
          onClose: () => windows.close(id),
        ),
      ),
      child: DetachedShellHost(
        hasChrome: true,
        headerBranch: branch,
        // Stepping to another view and back cross-fades, as the same step
        // does on a phone (the router's `_fadePage`). The incoming screen
        // claims the title bar last, so it wins it while both are mounted.
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          layoutBuilder: (current, previous) =>
              Stack(fit: StackFit.expand, children: [...previous, ?current]),
          // Keyed by depth and view, so stepping back rebuilds the screen
          // underneath instead of reusing the one popped off.
          child: KeyedSubtree(
            key: ValueKey('${window.stack.length}:$viewId'),
            child: desktopWindowContent(viewId),
          ),
        ),
      ),
    );
  }
}

/// Title of [viewId] for when its screen has not published a header (yet) —
/// also what the dock labels a window with.
String desktopWindowTitle(String viewId) => switch (desktopViewName(viewId)) {
  'menu' => 'menu_menu_title'.tr(),
  'settings' => 'menu_app_settings'.tr(),
  'theme-settings' => 'theme_presets'.tr(),
  'theme-editor' => 'theme_edit_theme'.tr(),
  'third-party-providers' => 'third_party_providers_title'.tr(),
  'character-editor' => 'action_edit_character'.tr(),
  'preset-block' => 'section_prompt_blocks'.tr(),
  'persona-editor' => 'tab_personas'.tr(),
  'lorebook-editor' => 'menu_lorebooks'.tr(),
  'regex-editor' => 'regex_editor'.tr(),
  'about' => 'menu_about'.tr(),
  'hall-of-fame' => 'about_hall_of_fame'.tr(),
  'logs' || 'log-view' => 'logs_title'.tr(),
  'sync' => 'menu_cloud_sync'.tr(),
  'backup' => 'menu_backup'.tr(),
  _ => '',
};

IconData _windowIcon(String viewId) => switch (desktopViewName(viewId)) {
  'menu' => Icons.menu_rounded,
  'settings' => Icons.settings_rounded,
  'theme-settings' => Icons.palette_rounded,
  'theme-editor' => Icons.format_paint_rounded,
  'third-party-providers' => Icons.extension_rounded,
  'character-editor' => Icons.person_rounded,
  'preset-block' => Icons.notes_rounded,
  'persona-editor' => Icons.badge_rounded,
  'lorebook-editor' => Icons.menu_book_rounded,
  'regex-editor' => Icons.code_rounded,
  'about' => Icons.info_outline_rounded,
  'hall-of-fame' => Icons.emoji_events_rounded,
  'logs' || 'log-view' => Icons.receipt_long_rounded,
  'sync' => Icons.cloud_sync_rounded,
  'backup' => Icons.backup_rounded,
  _ => Icons.web_asset_rounded,
};

/// The screen a floating window shows for [viewId]. Every id in
/// [desktopFloatingViews] must resolve here.
Widget desktopWindowContent(String viewId) {
  final view = Uri.parse(viewId);
  return switch (view.path) {
    'menu' => const MenuScreen(),
    'settings' => AppSettingsScreen(
      highlightId: view.queryParameters['highlight'],
    ),
    'theme-settings' => const ThemePresetScreen(),
    'theme-editor' => const ThemeEditorScreen(),
    'third-party-providers' => const ThirdPartyProvidersScreen(),
    'character-editor' => switch (view.queryParameters['new']) {
      final newId? => CharacterEditorScreen(charId: newId, isNew: true),
      null => CharacterEditorScreen(charId: view.queryParameters['id'] ?? ''),
    },
    'preset-block' => PresetBlockEditorWindow(
      presetId: view.queryParameters['preset'] ?? '',
      blockId: view.queryParameters['block'] ?? '',
    ),
    'persona-editor' => PersonaEditorWindow(
      personaId: view.queryParameters['id'],
    ),
    'lorebook-editor' => LorebookEditorScreen(
      lorebookId: view.queryParameters['id'] ?? '',
    ),
    'regex-editor' => RegexEditorWindow(
      scriptId: view.queryParameters['id'] ?? '',
      scope:
          RegexScope.values.asNameMap()[view.queryParameters['scope']] ??
          RegexScope.global,
      presetId: view.queryParameters['preset'],
    ),
    'about' => const AboutScreen(),
    'hall-of-fame' => const HallOfFameScreen(),
    'logs' => const LogsScreen(),
    'log-view' => LogViewerScreen(path: view.queryParameters['path'] ?? ''),
    'sync' => const SyncSheet(),
    'backup' => const BackupScreen(),
    _ => const SizedBox.shrink(),
  };
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
        BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 24),
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
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(10),
          onTap: () =>
              focused ? windows.minimize(window.id) : windows.focus(window.id),
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
