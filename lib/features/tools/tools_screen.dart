import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/preset.dart';
import '../../core/platform/haptics.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/db_provider.dart';
import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../shared/shell/desktop/sidebar_tool_panels.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/shell/nav_retap_provider.dart';
import '../../shared/shell/shell_header_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../chat/widgets/chat_stats_sheet.dart';
import '../chat/widgets/magic_drawer_widgets.dart' show MagicCardBadge;
import '../extensions/providers/extensions_settings_provider.dart';
import '../extensions/widgets/ext_blocks_settings_sheet.dart';
import '../image_gen/widgets/image_gen_sheet.dart';
import '../personas/persona_list_provider.dart';
import '../presets/preset_image.dart';
import '../presets/preset_list_provider.dart';
import 'tools_layout_service.dart';
import 'tools_tile_models.dart';

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

/// The icon a tile's def carries — an SVG glyph or an [IconData].
Widget _tileGlyph(
  ToolsTileDef def, {
  required Color color,
  required double size,
}) {
  if (def.svgPath != null) {
    return _svgPath(def.svgPath!, fill: color, size: size);
  }
  return Icon(def.icon, color: color, size: size);
}

class ToolsScreen extends ConsumerStatefulWidget {
  /// Rendered inside the desktop right sidebar rather than as the middle
  /// column's route. The sidebar has no shell header, so the screen must not
  /// reserve room for one nor publish a (never-rendered) header claim, and its
  /// tiles open panels in the sidebar instead of navigating the whole app.
  final bool inSidebar;

  const ToolsScreen({super.key, this.inSidebar = false});

  @override
  ConsumerState<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends ConsumerState<ToolsScreen>
    with ShellHeaderMixin {
  final ScrollController _scrollController = ScrollController();
  final List<ToolsTileDef> _allTiles = buildToolsTileCatalog();

  final List<String> _itemIds = [];
  final Map<String, ToolsTileSize> _sizes = {};
  final Set<String> _deletedIds = {};
  bool _loading = true;
  bool _editing = false;
  String? _draggingId;

  @override
  int get headerBranchIndex => 2;

  @override
  bool get publishesShellHeader => !widget.inSidebar;

  @override
  ShellHeaderConfig buildShellHeader() => ShellHeaderConfig(
    title: 'tab_tools'.tr(),
    actions: [_HeaderEditToggle(editing: _editing, onTap: _toggleEditing)],
  );

  @override
  void initState() {
    super.initState();
    _loadLayout();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLayout() async {
    try {
      final layout = await ToolsLayoutService(ref).loadLayout(_allTiles);
      if (!mounted) return;
      setState(() {
        _itemIds
          ..clear()
          ..addAll(layout.itemIds);
        _sizes
          ..clear()
          ..addAll(layout.sizes);
        _deletedIds
          ..clear()
          ..addAll(layout.deletedIds);
        _loading = false;
      });
    } catch (e) {
      debugPrint('[ToolsScreen] _loadLayout error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveLayout() =>
      ToolsLayoutService(ref).saveLayout(_itemIds, _sizes, _deletedIds);

  void _toggleEditing() {
    setState(() => _editing = !_editing);
    refreshShellHeader();
  }

  ToolsTileDef? _defFor(String id) {
    for (final tile in _allTiles) {
      if (tile.id == id) return tile;
    }
    return null;
  }

  ToolsTileSize _sizeFor(ToolsTileDef def) => _sizes[def.id] ?? def.defaultSize;

  bool _featureVisible(ToolsTileDef def, bool extBlocksEnabled) =>
      !def.featureGated || extBlocksEnabled;

  List<ToolsTileDef> _visibleTiles(bool extBlocksEnabled) => _itemIds
      .map(_defFor)
      .whereType<ToolsTileDef>()
      .where((def) => _featureVisible(def, extBlocksEnabled))
      .toList();

  bool _canAdd(bool extBlocksEnabled) => _allTiles.any(
    (tile) =>
        !_itemIds.contains(tile.id) && _featureVisible(tile, extBlocksEnabled),
  );

  Future<void> _removeTile(String id) async {
    setState(() {
      _itemIds.remove(id);
      _deletedIds.add(id);
    });
    await _saveLayout();
  }

  void _resizeTile(String id) {
    Haptics.selectionClick();
    final def = _defFor(id);
    if (def == null) return;
    setState(() => _sizes[id] = _sizeFor(def).next);
    _saveLayout();
  }

  Future<void> _moveTile(String movingId, String targetId) async {
    final from = _itemIds.indexOf(movingId);
    final to = _itemIds.indexOf(targetId);
    if (from < 0 || to < 0 || from == to) return;
    setState(() {
      _itemIds.insert(to, _itemIds.removeAt(from));
      _draggingId = null;
    });
    await _saveLayout();
  }

  Future<void> _showAddSheet(bool extBlocksEnabled) async {
    final hidden = _allTiles
        .where((tile) => !_itemIds.contains(tile.id))
        .where((tile) => _featureVisible(tile, extBlocksEnabled))
        .toList();
    if (hidden.isEmpty) return;

    final selected = await GlazeBottomSheet.show<ToolsTileDef>(
      context,
      title: 'sheet_title_add_tool'.tr(),
      child: _ToolsAddList(
        items: hidden,
        onSelect: (item) =>
            Navigator.of(context, rootNavigator: true).pop(item),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _itemIds.add(selected.id);
      _deletedIds.remove(selected.id);
    });
    await _saveLayout();
  }

  /// Opens the same Ext Blocks sheet as chat Quick Access.
  Future<void> _openExtBlocks() => showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const ExtBlocksSettingsSheet(),
  );

  /// From the sidebar, a tool opens as a sidebar panel; from the route it
  /// pushes `/tools/<id>` as before.
  void _openTool(BuildContext context, WidgetRef ref, String id) {
    if (widget.inSidebar) {
      showPanelInRightSidebar(ref, sidebarToolPanel(id));
      return;
    }
    context.push('/tools/$id');
  }

  /// Runs the tool a tile represents. Sheets stay over the screen; everything
  /// else navigates or opens a sidebar panel.
  void _launchTool(BuildContext context, WidgetRef ref, String id) {
    switch (id) {
      case 'personas':
      case 'presets':
      case 'api':
      case 'lorebooks':
      case 'regex':
        _openTool(context, ref, id);
      case 'stats':
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useRootNavigator: true,
          backgroundColor: Colors.transparent,
          builder: (_) => const ChatStatsSheet(initialCharId: ''),
        );
      case 'image-gen':
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useRootNavigator: true,
          backgroundColor: Colors.transparent,
          builder: (_) => const ImageGenSheet(),
        );
      case 'ext-blocks':
        _openExtBlocks();
    }
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

  String _subtitleFor(
    ToolsTileDef def,
    PersonaInfo? personaInfo,
    String presetName,
  ) {
    switch (def.id) {
      case 'personas':
        return personaInfo?.name ?? 'user';
      case 'presets':
        return presetName;
      default:
        return def.subtitle;
    }
  }

  ImageProvider? _artworkFor(
    ToolsTileDef def,
    String? avatarPath,
    ImageProvider? presetImage,
  ) {
    switch (def.id) {
      case 'personas':
        if (avatarPath == null || avatarPath.isEmpty) return null;
        return FileImage(File(avatarPath));
      case 'presets':
        return presetImage;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = ref.watch(navHeightProvider) + 20;
    final personaInfo = ref.watch(_activePersonaInfoProvider);
    final resolvedAvatar = ref.watch(_resolvedPersonaAvatarPathProvider).value;
    final presetName =
        ref.watch(_activePresetProvider)?.name ?? 'label_default'.tr();
    final presetImage = ref.watch(_activePresetImageProvider);
    final extBlocksEnabled = ref.watch(
      extensionsSettingsProvider.select((s) => s.enabled),
    );
    final topPad = widget.inSidebar
        ? 0.0
        : MediaQuery.of(context).padding.top + 66.0;

    // Re-tap on the active Tools navbar tab → scroll to top (sub-routes are
    // already popped by the shell's goBranch(initialLocation: true)).
    if (!widget.inSidebar) {
      ref.listen(navReTapProvider, (_, next) {
        if (next.branchIndex == kToolsBranchIndex) _scrollToTop();
      });
    }

    final tiles = _visibleTiles(extBlocksEnabled);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(16, topPad + 16, 16, bottomPad),
        children: _loading
            ? const [
                SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator()),
                ),
              ]
            : _buildRows(
                context,
                tiles,
                extBlocksEnabled,
                personaInfo,
                resolvedAvatar,
                presetName,
                presetImage,
              ),
      ),
    );
  }

  /// Packs the visible tiles into rows: small tiles pair up two-per-row, wide
  /// and large tiles each take a full row at their own height.
  List<Widget> _buildRows(
    BuildContext context,
    List<ToolsTileDef> tiles,
    bool extBlocksEnabled,
    PersonaInfo? personaInfo,
    String? resolvedAvatar,
    String presetName,
    ImageProvider? presetImage,
  ) {
    final rows = <Widget>[];
    final pendingSmall = <ToolsTileDef>[];

    Widget tileFor(ToolsTileDef def) => _buildTile(
      context,
      def,
      personaInfo,
      resolvedAvatar,
      presetName,
      presetImage,
    );

    void flushSmallRow() {
      if (pendingSmall.isEmpty) return;
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 10));
      final first = pendingSmall.removeAt(0);
      final second = pendingSmall.isNotEmpty ? pendingSmall.removeAt(0) : null;
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: tileFor(first)),
            const SizedBox(width: 10),
            Expanded(
              child: second != null ? tileFor(second) : const SizedBox(),
            ),
          ],
        ),
      );
    }

    for (final def in tiles) {
      if (_sizeFor(def) == ToolsTileSize.small) {
        pendingSmall.add(def);
        if (pendingSmall.length == 2) flushSmallRow();
      } else {
        flushSmallRow();
        if (rows.isNotEmpty) rows.add(const SizedBox(height: 10));
        rows.add(tileFor(def));
      }
    }
    flushSmallRow();

    if (_editing && _canAdd(extBlocksEnabled)) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 10));
      rows.add(_AddTile(onTap: () => _showAddSheet(extBlocksEnabled)));
    }

    return rows;
  }

  Widget _buildTile(
    BuildContext context,
    ToolsTileDef def,
    PersonaInfo? personaInfo,
    String? resolvedAvatar,
    String presetName,
    ImageProvider? presetImage,
  ) {
    final size = _sizeFor(def);
    final subtitle = _subtitleFor(def, personaInfo, presetName);
    final artwork = _artworkFor(def, resolvedAvatar, presetImage);

    Widget tile(
      ToolsTileSize tileSize, {
      bool editing = false,
      bool glass = true,
      VoidCallback? onTap,
    }) => _ToolTile(
      def: def,
      size: tileSize,
      subtitle: subtitle,
      artwork: artwork,
      editing: editing,
      onTap: onTap,
      onDelete: () => _removeTile(def.id),
      onResize: () => _resizeTile(def.id),
      glass: glass,
    );

    if (!_editing) {
      return tile(size, onTap: () => _launchTool(context, ref, def.id));
    }

    final display = tile(size, editing: true);
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data != def.id && _itemIds.contains(details.data),
      onAcceptWithDetails: (details) => _moveTile(details.data, def.id),
      builder: (context, _, _) {
        return LongPressDraggable<String>(
          data: def.id,
          delay: const Duration(milliseconds: 300),
          onDragStarted: () {
            Haptics.mediumImpact();
            setState(() => _draggingId = def.id);
          },
          onDragEnd: (_) {
            if (_draggingId == def.id) setState(() => _draggingId = null);
          },
          feedback: SizedBox(
            width: 150,
            height: size.isSquare ? 132 : size.height.clamp(0, 132),
            child: Material(
              color: Colors.transparent,
              child: Opacity(opacity: 0.92, child: tile(size, glass: false)),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.25, child: display),
          child: display,
        );
      },
    );
  }
}

/// Pencil in the shell header that toggles Tools edit mode. At rest it is a
/// bare glyph; the accent ring appears while editing so the state change is
/// what draws it, matching the chat drawer's edit toggle.
class _HeaderEditToggle extends StatelessWidget {
  final bool editing;
  final VoidCallback onTap;

  const _HeaderEditToggle({required this.editing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = editing ? 'btn_ok'.tr() : 'tools_customize'.tr();

    return Tooltip(
      message: label,
      preferBelow: false,
      child: Semantics(
        button: true,
        toggled: editing,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: editing
                  ? context.cs.primary.withValues(alpha: 0.22)
                  : Colors.transparent,
              border: Border.all(
                color: editing
                    ? context.cs.primary.withValues(alpha: 0.38)
                    : Colors.transparent,
              ),
            ),
            child: Icon(
              editing ? Icons.check : Icons.edit_outlined,
              size: 18,
              color: editing
                  ? context.cs.primary
                  : context.cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

/// One Windows-Phone-style tile.
///
/// The two hero tiles — personas and presets — keep their original full-bleed
/// look (avatar / cover + label) and adapt it to whatever size they are
/// assigned. Everything else renders the generic icon layout.
class _ToolTile extends StatelessWidget {
  final ToolsTileDef def;
  final ToolsTileSize size;
  final String subtitle;
  final ImageProvider? artwork;
  final bool editing;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onResize;

  /// False for the drag feedback, which renders over the [Overlay] where a
  /// [GlassSurface]'s backdrop filter has nothing sensible to sample — a plain
  /// solid card is cheaper and visually identical enough under the finger.
  final bool glass;

  const _ToolTile({
    required this.def,
    required this.size,
    required this.subtitle,
    this.artwork,
    this.editing = false,
    this.onTap,
    this.onDelete,
    this.onResize,
    this.glass = true,
  });

  static const _labelStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.bold,
    letterSpacing: 1,
    color: Color(0xE6FFFFFF), // rgba(255,255,255,0.9)
  );

  bool get _isSmall => size == ToolsTileSize.small;

  /// The old `_HeroCard` frame: an artwork hero gets the accent outline that
  /// separates its art from the page; everything else the hairline.
  bool get _hasArtworkFrame => def.isAvatar || artwork != null;

  @override
  Widget build(BuildContext context) {
    final inner = def.hero ? _buildHero(context) : _buildGeneric(context);

    if (!glass) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(color: context.cs.surfaceContainerHigh, child: inner),
      );
    }

    return GlassSurface(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      border: _hasArtworkFrame
          ? Border.all(
              color: context.cs.primary.withValues(alpha: 0.5),
              width: 2,
            )
          : Border.all(
              color: editing
                  ? context.cs.primary.withValues(alpha: 0.55)
                  : context.cs.outlineVariant,
              width: editing ? 1.5 : 1,
            ),
      child: inner,
    );
  }

  Widget _sized(Widget child) {
    if (size.isSquare) return AspectRatio(aspectRatio: 1, child: child);
    return SizedBox(height: size.height, child: child);
  }

  List<Widget> _editBadges(BuildContext context) => [
    if (editing && onDelete != null)
      Positioned(
        top: 6,
        right: 6,
        child: MagicCardBadge(
          icon: Icons.close,
          color: const Color(0xFFFF3B30),
          tooltip: 'btn_delete'.tr(),
          onTap: onDelete!,
        ),
      ),
    if (editing && onResize != null)
      Positioned(
        bottom: 6,
        right: 6,
        child: MagicCardBadge(
          icon: Icons.aspect_ratio,
          color: context.cs.onSurfaceVariant,
          tooltip: 'tools_resize'.tr(),
          onTap: onResize!,
        ),
      ),
  ];

  Widget _buildHero(BuildContext context) {
    return _sized(
      Stack(
        fit: StackFit.expand,
        children: [
          if (def.isAvatar) ...[
            if (artwork != null)
              Image(
                image: artwork!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              )
            else
              _AvatarGradientPlaceholder(
                subtitle: subtitle,
                fontSize: _isSmall ? 40 : 80,
              ),
            // Dark scrim so the white label/subtitle stay legible over art.
            DecoratedBox(
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
          ] else if (artwork != null) ...[
            Image(
              image: artwork!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
            DecoratedBox(
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
          ] else
            DecoratedBox(
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
          Padding(
            padding: EdgeInsets.all(_isSmall ? 12 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    if (!def.isAvatar) ...[
                      _heroIconBox(context, _isSmall ? 28 : 36),
                      const SizedBox(width: 12),
                    ],
                    Text(
                      def.title.toUpperCase(),
                      style: _labelStyle.copyWith(fontSize: _isSmall ? 11 : 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: _isSmall ? 14 : 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: _isSmall ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          ..._editBadges(context),
        ],
      ),
    );
  }

  Widget _buildGeneric(BuildContext context) {
    return _sized(
      Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
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
          _content(context),
          ..._editBadges(context),
        ],
      ),
    );
  }

  Widget _heroIconBox(BuildContext context, double boxSize) {
    return Container(
      width: boxSize,
      height: boxSize,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(boxSize * 0.28),
      ),
      child: Center(
        child: _tileGlyph(def, color: Colors.white, size: boxSize * 0.55),
      ),
    );
  }

  Widget _iconBox(BuildContext context, double boxSize) {
    return Container(
      width: boxSize,
      height: boxSize,
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: BorderRadius.circular(boxSize * 0.3),
      ),
      child: Center(
        child: _tileGlyph(
          def,
          color: context.cs.onSurfaceVariant,
          size: boxSize * 0.5,
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (size == ToolsTileSize.small) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _iconBox(context, 38),
            const Spacer(),
            Text(
              def.title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: context.cs.primary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );
    }

    if (size == ToolsTileSize.wide) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            _iconBox(context, 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    def.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: context.cs.primary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // large, no artwork — centred icon layout.
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _iconBox(context, 56),
          const SizedBox(height: 14),
          Text(
            def.title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: context.cs.primary,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Gradient backdrop for a persona hero with no avatar image, showing the
/// first letter of the active persona's name.
class _AvatarGradientPlaceholder extends StatelessWidget {
  final String subtitle;
  final double fontSize;

  const _AvatarGradientPlaceholder({
    required this.subtitle,
    required this.fontSize,
  });

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
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            color: const Color(0xCCFFFFFF), // rgba(255,255,255,0.8)
          ),
        ),
      ),
    );
  }
}

/// The "+" tile edit mode appends to the grid. Always the last cell, never a
/// drag target — it has nothing to reorder and opens the add sheet instead.
class _AddTile extends StatelessWidget {
  final VoidCallback onTap;

  const _AddTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: context.cs.outlineVariant),
      child: SizedBox(
        height: ToolsTileSize.small.height,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add,
                size: 22,
                color: context.cs.onSurface.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 8),
              Text(
                'action_add'.tr(),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// List of hidden tools shown by the add sheet — one row per tile, mirroring
/// the chat drawer's "Add Tool" list.
class _ToolsAddList extends StatelessWidget {
  final List<ToolsTileDef> items;
  final ValueChanged<ToolsTileDef> onSelect;

  const _ToolsAddList({required this.items, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in items)
          InkWell(
            onTap: () => onSelect(item),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  _tileGlyph(
                    item,
                    color: context.cs.onSurface.withValues(alpha: 0.85),
                    size: 20,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      item.title,
                      style: TextStyle(
                        fontSize: 15,
                        color: context.cs.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
