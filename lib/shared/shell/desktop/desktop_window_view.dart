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

/// The desktop floating window — Vue's `WindowView` in "panel" mode.
///
/// Hosts the Menu and everything reachable from it, on top of the three-column
/// layout, with its own back/close chrome and its own navigation stack so
/// drilling in never disturbs the middle column.
class DesktopWindowView extends ConsumerWidget {
  const DesktopWindowView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stack = ref.watch(desktopFloatingStackProvider);
    final controller = ref.read(desktopFloatingProvider);
    final size = MediaQuery.sizeOf(context);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: stack.isEmpty
          ? const SizedBox.shrink(key: ValueKey('window-closed'))
          : Stack(
              key: const ValueKey('window-open'),
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: controller.close,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    // Vue: 620px wide / 82vh tall, clamped to 92% of the window
                    // so it never touches the edges on a small desktop window.
                    constraints: BoxConstraints(
                      maxWidth: size.width * 0.92,
                      maxHeight: size.height * 0.92,
                    ),
                    child: SizedBox(
                      width: 620,
                      height: size.height * 0.82,
                      child: _WindowFrame(
                        viewId: stack.last,
                        canGoBack: stack.length > 1,
                        onBack: controller.pop,
                        onClose: controller.close,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _WindowFrame extends ConsumerWidget {
  final String viewId;
  final bool canGoBack;
  final VoidCallback onBack;
  final VoidCallback onClose;

  const _WindowFrame({
    required this.viewId,
    required this.canGoBack,
    required this.onBack,
    required this.onClose,
  });

  /// Screens that publish into [shellHeaderProvider] instead of drawing their
  /// own app bar (`useShellHeader: true`); the window renders that claim —
  /// title plus actions such as the settings search — in its own title bar.
  /// Anything not listed brings its own `GlazeScaffold` header.
  ///
  /// All of these live on the menu branch, and only one is mounted at a time,
  /// so resolving that branch always yields the screen on screen.
  static const _shellHeaderBranch = <String, int>{
    'menu': 3,
    'settings': 3,
    'theme-settings': 3,
    'about': 3,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branch = _shellHeaderBranch[viewId];
    final entry = branch == null
        ? null
        : ref.watch(
            shellHeaderProvider.select((e) => resolveShellHeader(e, branch)),
          );

    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: context.cs.outlineVariant),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 40,
          spreadRadius: 4,
        ),
      ],
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            _TitleBar(
              title: entry?.config.title ?? _fallbackTitle(),
              titleWidget: entry?.config.titleWidget,
              actions: entry?.config.actions ?? const [],
              canGoBack: canGoBack,
              onBack: onBack,
              onClose: onClose,
            ),
            Divider(height: 1, color: context.cs.outlineVariant),
            Expanded(child: DetachedShellHost(child: _content())),
          ],
        ),
      ),
    );
  }

  String _fallbackTitle() => switch (viewId) {
    'menu' => 'menu_menu_title'.tr(),
    'settings' => 'menu_app_settings'.tr(),
    'theme-settings' => 'theme_presets'.tr(),
    'about' => 'menu_about'.tr(),
    'sync' => 'menu_cloud_sync'.tr(),
    'backup' => 'menu_backup'.tr(),
    _ => '',
  };

  Widget _content() => switch (viewId) {
    'menu' => const MenuScreen(),
    'settings' => const AppSettingsScreen(),
    'theme-settings' => const ThemePresetScreen(),
    'about' => const AboutScreen(),
    'sync' => const SyncSheet(),
    'backup' => const BackupScreen(),
    _ => const SizedBox.shrink(),
  };
}

class _TitleBar extends StatelessWidget {
  final String title;
  final Widget? titleWidget;
  final List<Widget> actions;
  final bool canGoBack;
  final VoidCallback onBack;
  final VoidCallback onClose;

  const _TitleBar({
    required this.title,
    required this.titleWidget,
    required this.actions,
    required this.canGoBack,
    required this.onBack,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          const SizedBox(width: 4),
          if (canGoBack)
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
                    color: context.cs.onSurface,
                  ),
                ),
          ),
          ...actions,
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: onClose,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
