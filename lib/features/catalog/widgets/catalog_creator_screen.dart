import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../../shared/shell/shell_header_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import '../services/catalog_creators.dart';
import 'catalog_card_grid.dart';
import 'catalog_detail_launcher.dart';

/// The size the creator window opens at on desktop: wide enough for the
/// profile column beside a grid of four cards.
const _kCreatorWindowSize = Size(1180, 820);

/// Width from which the profile moves into a column beside the grid.
const _kSideProfileBreakpoint = 860.0;
const _kSideProfileWidth = 300.0;

/// Opens [feed]'s creator page on the root navigator, so it works the same
/// from the catalog and from a character preview — those live in different
/// shell branches.
///
/// On desktop it opens as a centered window, over the preview it was opened
/// from, rather than as a page covering the whole app.
Future<void> openCatalogCreatorScreen(
  BuildContext context, {
  required CatalogCreatorFeed feed,
  String? creatorName,
}) {
  if (isDesktopLayout(context)) {
    return showGlazeSheet<void>(
      context: context,
      useRootNavigator: true,
      windowSize: _kCreatorWindowSize,
      windowTitle: creatorName,
      builder: (_) =>
          CatalogCreatorScreen(feed: feed, creatorName: creatorName),
    );
  }
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          CatalogCreatorScreen(feed: feed, creatorName: creatorName),
    ),
  );
}

/// A creator's profile and their characters, for any source with creator
/// pages (DataCat, JanitorAI, Chub).
///
/// The first page arrives with the profile; every page after that comes from
/// [CatalogCreatorFeed.next], which keeps the source's own paging cursor.
class CatalogCreatorScreen extends ConsumerStatefulWidget {
  final CatalogCreatorFeed feed;

  /// Shown in the header until the profile lands, so the screen is never
  /// titled "Creator" for a creator whose name the caller already knew.
  final String? creatorName;

  const CatalogCreatorScreen({super.key, required this.feed, this.creatorName});

  @override
  ConsumerState<CatalogCreatorScreen> createState() =>
      _CatalogCreatorScreenState();
}

class _CatalogCreatorScreenState extends ConsumerState<CatalogCreatorScreen> {
  final _scrollController = ScrollController();

  CatalogCreatorProfile? _profile;
  final _items = <CatalogItem>[];
  Object? _error;
  bool _loading = true;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// What the reader has the catalog set to. Read rather than watched: a
  /// filter change while this screen is open must not silently reshuffle a
  /// grid the user is scrolling — it applies to the next page, and to the
  /// screen the next time it is opened.
  CatalogFilters get _filters => ref.read(catalogProvider).filters;

  void _onScroll() {
    if (!_scrollController.hasClients || _loading || !_hasMore) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) _loadMore();
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.feed.first(_filters);
      if (!mounted) return;
      setState(() {
        _profile = page.profile;
        _items
          ..clear()
          ..addAll(page.characters.characters);
        _hasMore = page.characters.hasMore ?? false;
        _loading = false;
      });
      _fillViewport();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loading = true);
    try {
      final page = await widget.feed.next(_filters);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.characters);
        _hasMore = page.hasMore ?? false;
        _loading = false;
      });
      _fillViewport();
    } catch (e) {
      if (!mounted) return;
      // A failed later page keeps what is already on screen — losing a whole
      // creator's grid to one bad request is worse than a missing tail.
      setState(() {
        _hasMore = false;
        _loading = false;
      });
      debugPrint('[catalog] creator page failed: $e');
    }
  }

  Future<void> _openCharacter(CatalogItem item) async {
    await showGlazeSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          CatalogDetailLauncher(item: item, provider: widget.feed.provider),
    );
  }

  /// A wide screen shows every card of a short page at once, leaving nothing
  /// to scroll and so nothing to trigger the next page: keep loading until the
  /// grid overflows or the creator runs out.
  void _fillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (_loading || !_hasMore) return;
      if (_scrollController.position.maxScrollExtent <= 0) _loadMore();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Inside a desktop window the window's title bar is the header, so there
    // is no floating header to keep clear of.
    final inWindow = DetachedShellHost.drawsChrome(context);
    final topPad = inWindow ? 8.0 : MediaQuery.of(context).padding.top + 74.0;
    final bottomPad = MediaQuery.of(context).padding.bottom + 20.0;
    final error = _error;

    return GlazeScaffold(
      title: _profile?.name ?? widget.creatorName ?? 'catalog_creator'.tr(),
      showBackground: true,
      extendBodyBehindHeader: true,
      // Pushed as a raw route, so pop it directly — GlazeScaffold's PopScope
      // would otherwise recurse back into onBack.
      onBack: () => Navigator.of(context).pop(),
      body: error != null && _items.isEmpty
          ? Padding(
              padding: EdgeInsets.fromLTRB(16, topPad + 16, 16, bottomPad),
              child: GlazeErrorBlock.fromError(error),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final side = constraints.maxWidth >= _kSideProfileBreakpoint;
                final profile = _profile;
                final grid = _buildGrid(
                  topPad: topPad,
                  bottomPad: bottomPad,
                  // On a wide screen the profile sits in its own column, so
                  // the grid scrolls past nothing but cards.
                  header: side || profile == null
                      ? null
                      : _ProfileHeader(profile: profile),
                );
                if (!side) return grid;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: _kSideProfileWidth,
                      child: profile == null
                          ? const SizedBox.shrink()
                          : SingleChildScrollView(
                              padding: EdgeInsets.fromLTRB(
                                16,
                                topPad + 8,
                                0,
                                bottomPad,
                              ),
                              child: _ProfileHeader(
                                profile: profile,
                                vertical: true,
                              ),
                            ),
                    ),
                    Expanded(child: grid),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildGrid({
    required double topPad,
    required double bottomPad,
    Widget? header,
  }) {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverToBoxAdapter(child: SizedBox(height: topPad + 8)),
        if (header != null) SliverToBoxAdapter(child: header),
        CatalogCardGridSliver(items: _items, onTap: _openCharacter),
        if (_loading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(child: GlazeSpinner(color: context.cs.primary)),
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: bottomPad)),
      ],
    );
  }
}

/// Avatar, name, verification mark, the about text and the creator's totals.
///
/// [vertical] is the desktop side-column form: the avatar large and centered
/// above the name, and the totals one per line.
class _ProfileHeader extends StatelessWidget {
  final CatalogCreatorProfile profile;
  final bool vertical;

  const _ProfileHeader({required this.profile, this.vertical = false});

  @override
  Widget build(BuildContext context) {
    final name = Row(
      mainAxisSize: vertical ? MainAxisSize.min : MainAxisSize.max,
      children: [
        Flexible(
          child: Text(
            profile.name,
            overflow: TextOverflow.ellipsis,
            textAlign: vertical ? TextAlign.center : TextAlign.start,
            style: TextStyle(
              fontSize: vertical ? 19 : 17,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
        ),
        if (profile.verified) ...[
          const SizedBox(width: 6),
          Icon(Icons.verified_rounded, size: 16, color: context.cs.primary),
        ],
      ],
    );
    final showHandle =
        profile.handle.isNotEmpty &&
        profile.handle.toLowerCase() != profile.name.toLowerCase();
    final handle = Text(
      '@${profile.handle}',
      style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
    );
    final stats = [
      if (profile.characterCount != null)
        _Stat(
          icon: Icons.person_outline_rounded,
          value: profile.characterCount!,
          label: 'catalog_creator_characters'.tr(),
        ),
      if (profile.followerCount != null)
        _Stat(
          icon: Icons.favorite_border_rounded,
          value: profile.followerCount!,
          label: 'catalog_creator_followers'.tr(),
        ),
      if (profile.chatCount != null)
        _Stat(
          icon: Icons.chat_bubble_outline_rounded,
          value: profile.chatCount!,
          label: 'catalog_creator_chats'.tr(),
        ),
      if (profile.messageCount != null)
        _Stat(
          icon: Icons.forum_outlined,
          value: profile.messageCount!,
          label: 'catalog_creator_messages'.tr(),
        ),
    ];

    final identity = vertical
        ? Column(
            children: [
              _Avatar(url: profile.avatarUrl, name: profile.name, size: 96),
              const SizedBox(height: 12),
              name,
              if (showHandle) ...[const SizedBox(height: 2), handle],
            ],
          )
        : Row(
            children: [
              _Avatar(url: profile.avatarUrl, name: profile.name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [name, if (showHandle) handle],
                ),
              ),
            ],
          );

    return Padding(
      padding: vertical
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: EdgeInsets.all(vertical ? 20 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              identity,
              if (profile.about.trim().isNotEmpty) ...[
                SizedBox(height: vertical ? 16 : 12),
                SelectableText(
                  profile.about.trim(),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ],
              if (stats.isNotEmpty) ...[
                SizedBox(height: vertical ? 16 : 12),
                vertical
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final stat in stats)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: stat,
                            ),
                        ],
                      )
                    : Wrap(spacing: 16, runSpacing: 6, children: stats),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final String name;
  final double size;

  const _Avatar({required this.url, required this.name, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: context.cs.surfaceContainerHighest,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.375,
          fontWeight: FontWeight.w700,
          color: context.cs.onSurfaceVariant,
        ),
      ),
    );

    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? fallback
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                placeholder: (_, _) => fallback,
                errorWidget: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final int value;
  final String label;

  const _Stat({required this.icon, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: context.cs.onSurfaceVariant),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            '$value $label',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
