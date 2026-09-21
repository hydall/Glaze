import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../../../shared/widgets/glaze_error_block.dart';
import '../../../../shared/widgets/glaze_scaffold.dart';
import '../../../../shared/widgets/glaze_spinner.dart';
import '../../catalog_models.dart';
import '../../services/datacat/datacat_creators.dart';
import '../../services/datacat/datacat_models.dart';
import '../catalog_card_grid.dart';
import '../catalog_detail_launcher.dart';

/// Opens [creatorRef]'s page on the root navigator, so it works the same from
/// the catalog and from a character preview — those live in different shell
/// branches.
Future<void> openDatacatCreatorScreen(
  BuildContext context, {
  required String creatorRef,
  String? creatorName,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => DatacatCreatorScreen(
        creatorRef: creatorRef,
        creatorName: creatorName,
      ),
    ),
  );
}

/// A DataCat creator's profile and their characters.
///
/// New in the app: there was no way to browse a creator before, because the
/// scraped site endpoints exposed none. The first page arrives with the profile
/// in one `bootstrap` call; every page after that comes from the paged endpoint
/// at the server's own cursor.
class DatacatCreatorScreen extends StatefulWidget {
  final String creatorRef;

  /// Shown in the header until the profile lands, so the screen is never
  /// titled "Creator" for a creator whose name the caller already knew.
  final String? creatorName;

  const DatacatCreatorScreen({
    super.key,
    required this.creatorRef,
    this.creatorName,
  });

  @override
  State<DatacatCreatorScreen> createState() => _DatacatCreatorScreenState();
}

class _DatacatCreatorScreenState extends State<DatacatCreatorScreen> {
  final _scrollController = ScrollController();

  DatacatCreatorProfile? _profile;
  final _items = <CatalogItem>[];
  Object? _error;
  bool _loading = true;
  bool _hasMore = true;
  int _nextOffset = 0;

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
      final page = await datacatFetchCreator(widget.creatorRef);
      if (!mounted) return;
      setState(() {
        _profile = page.profile;
        _items
          ..clear()
          ..addAll(page.characters.characters);
        _hasMore = page.characters.hasMore ?? false;
        _nextOffset = page.characters.nextOffset ?? _items.length;
        _loading = false;
      });
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
      final page = await datacatFetchCreatorCharacters(
        widget.creatorRef,
        offset: _nextOffset,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(page.characters);
        _hasMore = page.hasMore ?? false;
        _nextOffset = page.nextOffset ?? _nextOffset + page.characters.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // A failed later page keeps what is already on screen — losing a whole
      // creator's grid to one bad request is worse than a missing tail.
      setState(() {
        _hasMore = false;
        _loading = false;
      });
      debugPrint('[datacat] creator page failed: $e');
    }
  }

  Future<void> _openCharacter(CatalogItem item) async {
    await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          CatalogDetailLauncher(item: item, provider: CatalogProvider.datacat),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top + 74.0;
    final bottomPad = MediaQuery.of(context).padding.bottom + 20.0;
    final error = _error;

    return GlazeScaffold(
      title: _profile?.name ?? widget.creatorName ?? 'datacat_creator'.tr(),
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
          : CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: topPad + 8)),
                if (_profile != null)
                  SliverToBoxAdapter(child: _ProfileHeader(profile: _profile!)),
                CatalogCardGridSliver(
                  items: _items,
                  onTap: _openCharacter,
                ),
                if (_loading)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: GlazeSpinner(color: context.cs.primary),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(child: SizedBox(height: bottomPad)),
              ],
            ),
    );
  }
}

/// Avatar, name, verification mark, the about text and the creator's totals.
class _ProfileHeader extends StatelessWidget {
  final DatacatCreatorProfile profile;

  const _ProfileHeader({required this.profile});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Avatar(url: profile.avatarUrl, name: profile.name),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                profile.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: context.cs.onSurface,
                                ),
                              ),
                            ),
                            if (profile.verified) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.verified_rounded,
                                size: 16,
                                color: context.cs.primary,
                              ),
                            ],
                          ],
                        ),
                        if (profile.handle.isNotEmpty)
                          Text(
                            '@${profile.handle}',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (profile.about.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  profile.about.trim(),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  _Stat(
                    icon: Icons.person_outline_rounded,
                    value: profile.characterCount,
                    label: 'datacat_creator_characters'.tr(),
                  ),
                  _Stat(
                    icon: Icons.chat_bubble_outline_rounded,
                    value: profile.chatCount,
                    label: 'datacat_creator_chats'.tr(),
                  ),
                  _Stat(
                    icon: Icons.forum_outlined,
                    value: profile.messageCount,
                    label: 'datacat_creator_messages'.tr(),
                  ),
                ],
              ),
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

  const _Avatar({required this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final fallback = Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      color: context.cs.surfaceContainerHighest,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: context.cs.onSurfaceVariant,
        ),
      ),
    );

    return ClipOval(
      child: SizedBox(
        width: 48,
        height: 48,
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
        Text(
          '$value $label',
          style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
        ),
      ],
    );
  }
}
