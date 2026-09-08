import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/cloud_sync/widgets/sync_sheet.dart';
import '../../../features/menu/menu_screen.dart';
import '../../../features/settings/app_settings_screen.dart';
import '../../../features/settings/theme_preset_screen.dart';
import 'desktop_floating_provider.dart';

class DesktopWindowView extends ConsumerWidget {
  final VoidCallback onClose;

  const DesktopWindowView({super.key, required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewId = ref.watch<String?>(activeFloatingViewProvider);
    if (viewId == null) return const SizedBox.shrink();

    return Stack(
      children: [
        // Semi-transparent backdrop
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            child: Container(color: Colors.black38),
          ),
        ),
        // Centered floating window
        Center(
          child: Container(
            width: 620,
            height: MediaQuery.of(context).size.height * 0.82,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 40,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: _buildContent(viewId),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(String viewId) {
    switch (viewId) {
      case 'menu':
        return const MenuScreen();
      case 'settings':
        return const AppSettingsScreen();
      case 'theme-settings':
        return const ThemePresetScreen();
      case 'sync':
        return const SyncSheet();
      case 'backup':
        // BackupSheet is not yet a Concrete class; show placeholder
        return const _PlaceholderView(label: 'Backup');
      default:
        return const SizedBox.shrink();
    }
  }
}

class _PlaceholderView extends StatelessWidget {
  final String label;
  const _PlaceholderView({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        label,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}
