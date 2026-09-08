import 'dart:io';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/wallpaper.dart';
import '../../../core/services/file_export_service.dart';
import '../../../shared/shell/nav_height_provider.dart';
import '../../../shared/theme/built_in_themes.dart';
import '../../../shared/theme/theme_font_provider.dart';
import '../../../shared/theme/theme_preset.dart';
import '../../../shared/theme/theme_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../../shared/widgets/tab_slide_switcher.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import 'theme_editor_screen.dart';

class ThemePresetScreen extends ConsumerStatefulWidget {
  const ThemePresetScreen({super.key});

  @override
  ConsumerState<ThemePresetScreen> createState() => _ThemePresetScreenState();
}

class _ThemePresetScreenState extends ConsumerState<ThemePresetScreen> {
  // Decoded bg-image bytes keyed by `preset.id`, paired with the bgImage's
  // hash so edits invalidate the cache. Reusing the same `Uint8List` instance
  // across rebuilds keeps `MemoryImage` cached in the global ImageCache and
  // prevents the flicker that happens when the preset list rebuilds (e.g.
  // after applying a preset).
  final Map<String, ({int hash, Uint8List? bytes})> _bgBytesCache = {};

  /// 0 = user's own themes, 1 = built-in author catalog.
  int _activeTab = 0;

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final bottomPad = ref.watch(navHeightProvider) + 20;

    return GlazeScaffold(
      title: 'theme_presets'.tr(),
      useShellHeader: true,
      headerBranchIndex: 3,
      onBack: () => Navigator.pop(context),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: GlazeTabBar(
                  tabs: [
                    GlazeTabItem(
                      label: 'theme_tab_my'.tr(),
                      icon: Icons.palette_outlined,
                    ),
                    GlazeTabItem(
                      label: 'theme_tab_built_in'.tr(),
                      icon: Icons.auto_awesome_outlined,
                    ),
                  ],
                  activeIndex: _activeTab,
                  onChanged: (i) => setState(() => _activeTab = i),
                ),
              ),
              Expanded(
                child: SwipeTabSwitcher(
                  index: _activeTab,
                  length: 2,
                  onChanged: (i) => setState(() => _activeTab = i),
                  child: TabSlideSwitcher(
                    index: _activeTab,
                    child: IndexedStack(
                      index: _activeTab,
                      children: [
                        _buildMyThemesList(context, theme, bottomPad),
                        _buildBuiltInList(context, theme.activePreset, bottomPad),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          // The add/import FAB only applies to the user's own theme list.
          if (_activeTab == 0)
            Positioned(
              right: 16,
              bottom: bottomPad,
              child: _ThemeFab(onTap: () => _showAddSheet(context)),
            ),
        ],
      ),
    );
  }

  Widget _buildMyThemesList(
    BuildContext context,
    ThemeSettings theme,
    double bottomPad,
  ) {
    final presets = theme.presets;
    final activeId = theme.activePreset.id;
    return ListView(
      padding: EdgeInsets.only(bottom: bottomPad + 60),
      children: [
        _buildFontToggle(context),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'theme_all_themes'.tr(),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 8),
        ...presets.map(
          (p) => _buildPresetTile(
            context,
            p,
            p.id == activeId,
            theme.activePreset,
          ),
        ),
      ],
    );
  }

  Widget _buildBuiltInList(
    BuildContext context,
    ThemePreset activePreset,
    double bottomPad,
  ) {
    final catalog = ref.watch(builtInThemesProvider);
    if (catalog.isEmpty) {
      return _buildBuiltInEmptyState(context);
    }
    return ListView(
      padding: EdgeInsets.only(top: 8, bottom: bottomPad + 60),
      children: [
        ...catalog.map(
          (p) => _buildPresetTile(
            context,
            p,
            false,
            activePreset,
            catalog: true,
          ),
        ),
      ],
    );
  }

  Widget _buildBuiltInEmptyState(BuildContext context) {
    final cs = context.cs;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 48,
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'theme_built_in_empty_title'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'theme_built_in_empty_desc'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Installs a built-in catalog theme into the user's own list. Catalog
  /// entries are templates, so we clone with a fresh `custom_…` id, apply it,
  /// and flip back to the "My Themes" tab so the user sees the result.
  Future<void> _installBuiltIn(ThemePreset preset) async {
    final clone = preset.copyWith(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
    );
    await ref.read(themeProvider.notifier).importPreset(clone);
    await ref.read(themeProvider.notifier).applyPreset(clone);
    if (!mounted) return;
    setState(() => _activeTab = 0);
    GlazeToast.show(
      context,
      'theme_imported_message'.tr(namedArgs: {'name': clone.name}),
    );
  }

  Widget _buildFontToggle(BuildContext context) {
    final ignoreCustomFont = ref.watch(themeProvider).ignoreCustomFont;
    final hasFont = ref.watch(themeProvider).activePreset.hasChatFont ||
        ref.watch(themeProvider).activePreset.hasCustomFont;
    if (!hasFont) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SwitchListTile(
        value: !ignoreCustomFont,
        onChanged: (v) =>
            ref.read(themeProvider.notifier).setIgnoreCustomFont(!v),
        title: Text(
          'theme_custom_font'.tr(),
          style: TextStyle(color: context.cs.onSurface),
        ),
        subtitle: Text(
          'theme_custom_font_subtitle'.tr(),
          style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
        ),
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  void _showAddSheet(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'theme_add_theme'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.add_rounded,
          label: 'theme_new_theme'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _createNewTheme();
          },
        ),
        BottomSheetItem(
          icon: Icons.file_download_outlined,
          label: 'hint_import_file'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _importTheme();
          },
        ),
      ],
    );
  }

  Uint8List? _decodeBgImage(ThemePreset preset) {
    if (!preset.hasBgImage) return null;
    final data = preset.bgImage!;
    final hash = data.hashCode;
    final cached = _bgBytesCache[preset.id];
    if (cached != null && cached.hash == hash) return cached.bytes;
    Uint8List? bytes;
    try {
      final commaIdx = data.indexOf(',');
      if (commaIdx != -1) {
        bytes = base64Decode(data.substring(commaIdx + 1));
      }
    } catch (_) {
      bytes = null;
    }
    _bgBytesCache[preset.id] = (hash: hash, bytes: bytes);
    return bytes;
  }

  Widget _buildPresetTile(
    BuildContext context,
    ThemePreset preset,
    bool isActive,
    ThemePreset activePreset, {
    bool catalog = false,
  }) {
    final cs = context.cs;
    final accent = preset.accent;
    final bgBytes = _decodeBgImage(preset);
    final hasImage = bgBytes != null;

    final sublabelParts = <String>[];
    if (preset.author.isNotEmpty) sublabelParts.add('by ${preset.author}');
    if (isActive) sublabelParts.add('label_active'.tr());
    final sublabel = sublabelParts.join(' • ');

    final borderBase = activePreset.borderParsed ?? cs.onSurface;
    final borderOpacity = activePreset.borderOpacity.clamp(0.0, 1.0);
    final borderWidth = activePreset.borderWidth;
    // Base border is always the active preset's UI Element border. The
    // active-state highlight is painted on top via an `AnimatedContainer`
    // so the transition between presets fades smoothly.
    final baseBorder = Border.all(
      color: borderBase.withValues(alpha: borderOpacity),
      width: borderWidth,
    );
    final highlightWidth = borderWidth < 1 ? 1.0 : borderWidth;

    final tint = activePreset.uiColorParsed ?? cs.surfaceContainerHighest;

    final labelColor = hasImage ? Colors.white : cs.onSurface;
    final sublabelColor =
        hasImage ? Colors.white.withAlpha(178) : cs.onSurfaceVariant;
    final textShadows = hasImage
        ? const [
            Shadow(
              color: Color(0xCC000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ]
        : null;

    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: hasImage ? 160 : 0),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: hasImage ? 16 : 12,
          vertical: hasImage ? 12 : 10,
        ),
        child: Align(
          alignment:
              hasImage ? Alignment.bottomLeft : Alignment.centerLeft,
          child: Row(
            children: [
              if (!hasImage) ...[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x1A000000),
                        blurRadius: 5,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      preset.name,
                      style: TextStyle(
                        fontSize: hasImage ? 16 : 15,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                        shadows: textShadows,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (sublabel.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        sublabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: sublabelColor,
                          shadows: textShadows,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (catalog)
                GestureDetector(
                  onTap: () => _installBuiltIn(preset),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.15),
                        width: 1,
                      ),
                    ),
                    child: const Icon(
                      Icons.add_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                )
              else if (preset.id != 'default')
                GestureDetector(
                  onTap: () =>
                      _showPresetActions(context, preset, isActive),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.15),
                        width: 1,
                      ),
                    ),
                    child: const Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    final Widget base;
    if (hasImage) {
      base = Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(bgBytes, fit: BoxFit.cover, gaplessPlayback: true),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x4D000000), Color(0xCC000000)],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              border: baseBorder,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ],
      );
    } else {
      base = GlassSurface(
        borderRadius: BorderRadius.circular(12),
        border: baseBorder,
        tint: tint,
        child: const SizedBox.expand(),
      );
    }

    final activeHighlight = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: isActive ? accent.withValues(alpha: 0.2) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? accent.withValues(alpha: 0.5) : Colors.transparent,
          width: highlightWidth,
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Positioned.fill(child: IgnorePointer(child: base)),
            Positioned.fill(child: IgnorePointer(child: activeHighlight)),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: catalog
                    ? () => _installBuiltIn(preset)
                    : (isActive ? null : () => _selectPreset(preset)),
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPresetActions(BuildContext context, ThemePreset preset, bool isActive) {
    GlazeBottomSheet.show<void>(
      context,
      title: preset.name,
      items: [
        BottomSheetItem(
          icon: Icons.tune,
          label: 'theme_edit_theme'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openThemeEditor(preset, isActive: isActive);
          },
        ),
        BottomSheetItem(
          icon: Icons.drive_file_rename_outline,
          label: 'action_rename'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _renamePreset(preset);
          },
        ),
        if (!preset.isBuiltIn)
          BottomSheetItem(
            icon: Icons.copy_all_outlined,
            label: 'theme_clone_theme'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _clonePreset(preset);
            },
          ),
        BottomSheetItem(
          icon: Icons.upload_file,
          label: 'action_export'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _exportPreset(preset);
          },
        ),
        if (!preset.isBuiltIn)
          BottomSheetItem(
            icon: Icons.delete_outline,
            label: 'btn_delete'.tr(),
            isDestructive: true,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _deletePreset(preset.id);
            },
          ),
      ],
    );
  }

  void _renamePreset(ThemePreset preset) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'theme_rename_theme'.tr(),
      input: BottomSheetInput(
        placeholder: 'theme_name_placeholder'.tr(),
        value: preset.name,
        confirmLabel: 'action_rename'.tr(),
        onConfirm: (val) async {
          Navigator.of(context, rootNavigator: true).pop();
          if (val.trim().isNotEmpty) {
            final renamed = preset.copyWith(name: val.trim());
            await ref.read(themeProvider.notifier).updatePreset(renamed);
          }
        },
      ),
    );
  }

  Future<void> _clonePreset(ThemePreset preset) async {
    final clone = preset.copyWith(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: '${preset.name} (copy)',
    );
    await ref.read(themeProvider.notifier).importPreset(clone);
    await ref.read(themeProvider.notifier).applyPreset(clone);
  }

  Future<void> _exportPreset(ThemePreset preset) async {
    try {
      final json = jsonEncode(preset.toJson());
      final filename = '${preset.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.json';
      final path = await FileExportService.export(
        data: json,
        filename: filename,
        subfolder: 'themes',
      );
      if (!mounted) return;
      GlazeToast.show(context, 'Theme exported to $path');
    } catch (e) {
      if (e.toString().contains('cancelled')) return;
      if (!mounted) return;
      GlazeErrorDialog.show(context, e, prefix: 'Export failed: ');
    }
  }

  Future<void> _openThemeEditor(ThemePreset preset, {required bool isActive}) async {
    if (!isActive) {
      _applyPreset(preset);
    }
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const ThemeEditorScreen()),
    );
  }

  Future<void> _createNewTheme() async {
    final preset = ThemePreset(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: 'theme_new_theme'.tr(),
    );
    await ref.read(themeProvider.notifier).importPreset(preset);
    await ref.read(themeProvider.notifier).applyPreset(preset);
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const ThemeEditorScreen()),
    );
  }

  Future<void> _importTheme() async {
    try {
      final result = await FilePicker.pickFiles(
        type: Platform.isIOS ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isIOS ? null : ['json', 'thm'],
        dialogTitle: 'theme_import_theme'.tr(),
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;
      final path = file.path!;
      final lowerPath = path.toLowerCase();
      final isSupported =
          lowerPath.endsWith('.json') || lowerPath.endsWith('.thm');
      if (!isSupported) {
        if (mounted) {
          GlazeErrorDialog.show(context, 'theme_unsupported_file_type'.tr());
        }
        return;
      }

      final preset = await ref
          .read(themeProvider.notifier)
          .importPresetFromFile(path);
      if (preset == null) return;

      if (mounted) {
        GlazeToast.show(context, 'theme_imported_message'.tr(namedArgs: {'name': preset.name}));
      }
    } on FormatException catch (e) {
      if (mounted) {
        GlazeErrorDialog.show(context, 'theme_invalid_theme_file'.tr(namedArgs: {'message': e.message}));
      }
    } catch (e) {
      if (mounted) {
        GlazeErrorDialog.show(context, e, prefix: 'Failed to import: ');
      }
    }
  }

  void _applyPreset(ThemePreset preset) {
    ref.read(themeProvider.notifier).applyPreset(preset);
  }

  /// Applies a preset from a direct tap. For Material You, also offers the
  /// wallpaper-background permission prompt (Android only).
  Future<void> _selectPreset(ThemePreset preset) async {
    _applyPreset(preset);
    if (preset.isMaterialYou) {
      await _promptWallpaperPermissionIfNeeded();
    }
  }

  /// Material You uses the device wallpaper as its background, which needs the
  /// storage/media permission. Show a sheet explaining this with grant/decline
  /// options. No-op when not on Android or the permission is already granted.
  Future<void> _promptWallpaperPermissionIfNeeded() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (await Wallpaper.hasPermission()) return;
    if (!mounted) return;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'theme_wallpaper_permission_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.wallpaper_outlined,
        description: 'theme_wallpaper_permission_desc'.tr(),
      ),
      items: [
        BottomSheetItem(
          icon: Icons.check_circle_outline,
          label: 'theme_wallpaper_permission_grant'.tr(),
          centered: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            final granted = await Wallpaper.requestPermission();
            if (granted && mounted) {
              ref.invalidate(wallpaperBytesProvider);
            }
          },
        ),
        BottomSheetItem(
          icon: Icons.close,
          label: 'theme_wallpaper_permission_decline'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  Future<void> _deletePreset(String id) async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'btn_delete'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'theme_confirm_delete_message'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'action_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (confirmed == true) {
      await ref.read(themeProvider.notifier).deletePreset(id);
    }
  }
}

class _ThemeFab extends StatelessWidget {
  final VoidCallback onTap;
  const _ThemeFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: context.cs.primary,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.add_rounded, color: Colors.white, size: 24),
            const SizedBox(width: 8),
            Text(
              'action_add'.tr(),
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
