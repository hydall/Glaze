import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/preset.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/active_studio_preset_provider.dart';
import '../../core/utils/platform_paths.dart';
import '../../core/state/db_provider.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/shell/nav_retap_provider.dart';
import '../personas/persona_list_provider.dart';
import '../presets/preset_image.dart';
import '../presets/preset_list_provider.dart';
import '../../shared/shell/shell_header_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glass_surface.dart';
import '../chat/widgets/chat_stats_sheet.dart';
import '../image_gen/widgets/image_gen_sheet.dart';
import '../studio/screens/studio_preset_editor_screen.dart';

class PersonaInfo {
  final String name;
  final String? avatarPath;
  const PersonaInfo({required this.name, this.avatarPath});
}

final _activePersonaInfoProvider = Provider<PersonaInfo?>((ref) {
  final personas = ref.watch(personaListProvider).value ?? [];
  final activeId = ref.watch(activePersonaIdProvider);
  final connections = ref.watch(personaConnectionsProvider);
  final persona = getEffectivePersona(
    personas,
    null,
    null,
    activeId,
    connections,
  );
  if (persona == null) return null;
  return PersonaInfo(name: persona.name, avatarPath: persona.avatarPath);
});

final _resolvedPersonaAvatarPathProvider = FutureProvider<String?>((ref) async {
  final info = ref.watch(_activePersonaInfoProvider);
  final raw = info?.avatarPath;
  if (raw == null || raw.isEmpty) return null;
  final storage = await ref.watch(imageStorageProvider.future);
  final abs = storage.absolutePath(raw);
  if (abs != null && await File(abs).exists()) return abs;
  if (await File(raw).exists()) return raw;
  return null;
});

/// The globally active preset. Watches the list (not just the id) so a rename
/// or a new cover image is reflected on the card without leaving the screen.
final _activePresetProvider = Provider<Preset?>((ref) {
  final activeId = ref.watch(activePresetIdProvider);
  if (activeId == null) return null;
  final presets = ref.watch(presetListProvider).value ?? const <Preset>[];
  return presets.where((p) => p.id == activeId).firstOrNull;
});

/// Cover image of the active preset — a user-picked one, or the bundled art of
/// a featured preset.
final _activePresetImageProvider = Provider<ImageProvider?>((ref) {
  final preset = ref.watch(_activePresetProvider);
  return preset != null ? presetCoverImage(preset) : null;
});

// SVG paths matching ToolsView.vue
const _kIconPersonas =
    'M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm6 12H6v-1c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1z';
const _kIconPresets =
    'M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6h-6V2zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z';
const _kIconApi =
    'M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z';
const _kIconLorebook =
    'M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z';
const _kIconRegex =
    'M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z';
const _kIconStats =
    'M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zM9 17H7v-7h2v7zm4 0h-2V7h2v10zm4 0h-2v-4h2v4z';
const _kIconImageGen =
    'M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z';

Widget _svgPath(
  String d, {
  Color fill = Colors.white,
  double size = 20,
}) => SvgPicture.string(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="$d"/></svg>',
  width: size,
  height: size,
  colorFilter: ColorFilter.mode(fill, BlendMode.srcIn),
);

class ToolsScreen extends ConsumerStatefulWidget {
  const ToolsScreen({super.key});

  @override
  ConsumerState<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends ConsumerState<ToolsScreen>
    with ShellHeaderMixin {
  final ScrollController _scrollController = ScrollController();

  @override
  int get headerBranchIndex => 2;

  @override
  ShellHeaderConfig buildShellHeader() =>
      ShellHeaderConfig(title: 'tab_tools'.tr());

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Opens the Studio preset editor for the globally active Studio preset.
  /// Studio presets are app-wide, so this needs no active chat session.
  Future<void> _openStudio() async {
    final presetId = await ref.read(activeStudioPresetProvider.future);
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => StudioPresetEditorScreen(presetId: presetId),
      ),
    );
  }

  /// Animates the list back to the top (guarded against a detached / multiply
  /// attached controller).
  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.positions.length != 1) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = ref.watch(navHeightProvider) + 20;
    final personaInfo = ref.watch(_activePersonaInfoProvider);
    final resolvedAvatar = ref.watch(_resolvedPersonaAvatarPathProvider).value;
    final presetName =
        ref.watch(_activePresetProvider)?.name ?? 'label_default'.tr();
    final presetImage = ref.watch(_activePresetImageProvider);
    final studioEnabled = ref.watch(studioFeatureEnabledProvider);
    final topPad = MediaQuery.of(context).padding.top + 66.0;

    // Re-tap on the active Tools navbar tab → scroll to top (sub-routes are
    // already popped by the shell's goBranch(initialLocation: true)).
    ref.listen(navReTapProvider, (_, next) {
      if (next.branchIndex == kToolsBranchIndex) _scrollToTop();
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          ListView(
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(16, topPad + 16, 16, bottomPad),
            children: [
              _HeroCard(
                iconPath: _kIconPersonas,
                title: 'menu_personas'.tr(),
                subtitle: personaInfo?.name ?? 'user',
                avatarPath: resolvedAvatar,
                isAvatar: true,
                onTap: () => context.push('/tools/personas'),
              ),
              const SizedBox(height: 10),
              _HeroCard(
                iconPath: _kIconPresets,
                title: 'tab_presets'.tr(),
                subtitle: presetName,
                backgroundImage: presetImage,
                onTap: () => context.push('/tools/presets'),
              ),
              const SizedBox(height: 10),
              // IntrinsicHeight + stretch so both tiles in a row share the
              // taller one's height and fill the whole allocated cell.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _GridTile(
                        iconPath: _kIconApi,
                        title: 'tab_api'.tr(),
                        subtitle: 'tools_api_subtitle'.tr(),
                        showStatusDot: true,
                        onTap: () => context.push('/tools/api'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _GridTile(
                        iconPath: _kIconLorebook,
                        title: 'menu_lorebooks'.tr(),
                        subtitle: 'tools_lorebooks_subtitle'.tr(),
                        onTap: () => context.push('/tools/lorebooks'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _GridTile(
                        iconPath: _kIconRegex,
                        title: 'menu_regex'.tr(),
                        subtitle: 'tools_regex_subtitle'.tr(),
                        onTap: () => context.push('/tools/regex'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _GridTile(
                        iconPath: _kIconStats,
                        title: 'stats_title'.tr(),
                        subtitle: 'stats_subtitle'.tr(),
                        onTap: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          useRootNavigator: true,
                          backgroundColor: Colors.transparent,
                          builder: (_) =>
                              const ChatStatsSheet(initialCharId: ''),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _GridTile(
                        iconPath: _kIconImageGen,
                        title: 'imggen_title'.tr(),
                        subtitle: 'imggen_subtitle'.tr(),
                        onTap: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          useRootNavigator: true,
                          backgroundColor: Colors.transparent,
                          builder: (_) => const ImageGenSheet(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Studio only appears once its experimental master switch is on.
                    Expanded(
                      child: studioEnabled
                          ? _GridTile(
                              icon: Icons.movie_filter_outlined,
                              title: 'menu_studio'.tr(),
                              subtitle: 'tools_studio_subtitle'.tr(),
                              onTap: _openStudio,
                            )
                          : const SizedBox(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final String iconPath;
  final String title;
  final String subtitle;
  final bool isAvatar;
  final String? avatarPath;

  /// Image shown as the card background (e.g. a preset's cover — a bundled
  /// asset for a featured preset, a stored file for a user-picked one).
  /// Applies only to the non-avatar layout and does not change the card size.
  final ImageProvider? backgroundImage;
  final VoidCallback onTap;

  const _HeroCard({
    required this.iconPath,
    required this.title,
    required this.subtitle,
    this.isAvatar = false,
    this.avatarPath,
    this.backgroundImage,
    required this.onTap,
  });

  static const _labelStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.bold,
    letterSpacing: 1,
    color: Color(0xE6FFFFFF), // rgba(255,255,255,0.9)
  );

  /// Cards filled with artwork — the persona avatar, a preset cover — get a
  /// stronger accent outline: the default hairline is invisible against a
  /// photo, and the frame is what separates the art from the page background.
  bool get _hasArtwork => isAvatar || backgroundImage != null;

  @override
  Widget build(BuildContext context) {
    final card = GlassSurface(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: _hasArtwork
            ? context.cs.primary.withValues(alpha: 0.5)
            : context.cs.outlineVariant,
        width: _hasArtwork ? 2 : 1,
      ),
      child: SizedBox(
        height: isAvatar ? null : 140,
        child: Stack(
          children: [
            if (isAvatar) ...[
              Positioned.fill(
                child: avatarPath != null && avatarPath!.isNotEmpty
                    ? Image.file(
                        File(resolveGlazeFilePath(avatarPath!)!),
                        key: ValueKey(avatarPath),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            _AvatarGradientPlaceholder(subtitle: subtitle),
                      )
                    : _AvatarGradientPlaceholder(subtitle: subtitle),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.3),
                        Colors.black.withValues(alpha: 0.8),
                      ],
                    ),
                  ),
                ),
              ),
            ] else if (backgroundImage != null) ...[
              Positioned.fill(
                child: Image(
                  image: backgroundImage!,
                  key: ValueKey(backgroundImage),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
              // Dark scrim so the white label/subtitle stay legible over art.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.8),
                      ],
                    ),
                  ),
                ),
              ),
            ] else ...[
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: 0.05),
                        Colors.white.withValues(alpha: 0.01),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (isAvatar)
                    Text(title.toUpperCase(), style: _labelStyle)
                  else
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(
                            child: _svgPath(
                              iconPath,
                              fill: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(title.toUpperCase(), style: _labelStyle),
                      ],
                    ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (isAvatar) return AspectRatio(aspectRatio: 1, child: card);
    return card;
  }
}

class _AvatarGradientPlaceholder extends StatelessWidget {
  final String subtitle;
  const _AvatarGradientPlaceholder({required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF66CCFF), Color(0xFF7996CE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          subtitle.isNotEmpty ? subtitle[0].toUpperCase() : '?',
          style: const TextStyle(
            fontSize: 80,
            fontWeight: FontWeight.w800,
            color: Color(0xCCFFFFFF), // rgba(255,255,255,0.8)
          ),
        ),
      ),
    );
  }
}

class _GridTile extends StatelessWidget {
  final String? iconPath;
  final IconData? icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool showStatusDot;

  const _GridTile({
    this.iconPath,
    this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.showStatusDot = false,
  }) : assert(
         iconPath != null || icon != null,
         'Provide either an SVG iconPath or an IconData icon',
       );

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: context.cs.outlineVariant),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: context.cs.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: iconPath != null
                        ? _svgPath(
                            iconPath!,
                            fill: context.cs.onSurfaceVariant,
                            size: 22,
                          )
                        : Icon(
                            icon,
                            color: context.cs.onSurfaceVariant,
                            size: 22,
                          ),
                  ),
                ),
                if (showStatusDot)
                  Positioned(
                    bottom: -2,
                    right: -2,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: context.cs.onSurfaceVariant,
                        border: Border.all(color: context.cs.surface, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: context.cs.primary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
