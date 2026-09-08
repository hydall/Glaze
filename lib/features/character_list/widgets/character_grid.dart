import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/models/character.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../settings/app_settings_provider.dart';
import '../character_detail_screen.dart';
import '../character_sort.dart';
import 'character_card.dart';
import 'randomizing_card_overlay.dart';

class CharacterGrid extends StatelessWidget {
  final List<Character> characters;
  final int totalCount;
  final SortType sortBy;
  final SortDir sortDir;
  final VoidCallback onSortDirToggle;
  final ValueChanged<SortType> onSortTypeChanged;
  final double topPadding;
  final double bottomPadding;
  final bool isLoadingMore;
  final bool hasMore;
  final int filterCount;
  final VoidCallback? onFilterTap;

  /// Optional sliver inserted right after the top padding (e.g. the folders
  /// section).
  final Widget? headerSliver;

  /// When set, cards are rendered inside this folder and expose "Remove from
  /// folder".
  final String? folderId;

  /// Resolves the full pool of characters the dice may pick from. The grid only
  /// holds the currently rendered cards ([characters]), which in the paginated
  /// My-Characters view is just the loaded page — picking from that would bias
  /// the dice toward already-scrolled rows. When provided, [randomPool] returns
  /// every character matching the active view (filters/folder included) so the
  /// dice draws from the complete set. Falls back to [characters] when null.
  final List<Character> Function()? randomPool;

  const CharacterGrid({
    super.key,
    required this.characters,
    required this.totalCount,
    required this.sortBy,
    required this.sortDir,
    required this.onSortDirToggle,
    required this.onSortTypeChanged,
    this.topPadding = 0,
    this.bottomPadding = 16,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.filterCount = 0,
    this.onFilterTap,
    this.headerSliver,
    this.folderId,
    this.randomPool,
  });

  /// The pool the shuffle button draws from — always the currently matching set
  /// (active filters, search and the hidden toggle already applied upstream via
  /// [randomPool]); falls back to the rendered cards when no resolver is given.
  List<Character> _randomPool() => randomPool?.call() ?? characters;

  /// Opens the randomizing discovery overlay over the full matching set: a
  /// holographic card the user can swipe right (start a new chat) or left (skip
  /// to the next random card).
  void _openRandomizing(BuildContext context) {
    final pool = _randomPool();
    if (pool.isEmpty) return;
    showRandomizingCardOverlay(context, pool);
  }

  /// Classic shuffle: opens one random character straight in the detail sheet.
  /// Mirrors the card's tap behaviour (modal sheet + route-return nav). Used
  /// when "use standard randomizer" is enabled in settings.
  Future<void> _openStandardRandom(BuildContext context) async {
    final pool = _randomPool();
    if (pool.isEmpty) return;
    final picked = pool[Random().nextInt(pool.length)];
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CharacterDetailScreen(charId: picked.id),
    );
    if (result != null && result.isNotEmpty && context.mounted) {
      context.go(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        if (topPadding > 0)
          SliverToBoxAdapter(child: SizedBox(height: topPadding)),
        ?headerSliver,
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (characters.isNotEmpty) ...[
                  Consumer(
                    builder: (context, ref, _) {
                      final standard = ref.watch(
                        appSettingsProvider.select(
                          (s) => s.value?.useStandardRandomizer ?? false,
                        ),
                      );
                      return _DiceButton(
                        standard: standard,
                        onTap: () => standard
                            ? _openStandardRandom(context)
                            : _openRandomizing(context),
                      );
                    },
                  ),
                  const SizedBox(width: 10),
                ],
                if (onFilterTap != null) ...[
                  _FilterButton(count: filterCount, onTap: onFilterTap!),
                  const SizedBox(width: 10),
                ],
                _SortDirButton(
                  isAsc: sortDir == SortDir.asc,
                  onTap: onSortDirToggle,
                ),
                const SizedBox(width: 10),
                _SortTypePill(sortBy: sortBy, onChanged: onSortTypeChanged),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Text(
              '$totalCount ${'count_characters'.plural(totalCount)}',
              style: TextStyle(
                fontSize: 11,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2 / 3,
            ),
            delegate: SliverChildBuilderDelegate(
              // No explicit RepaintBoundary: SliverChildBuilderDelegate already
              // wraps each child in one (addRepaintBoundaries: true by default).
              //
              // Keyed by character id so Flutter matches each card's State to its
              // character across list changes. Without this, deleting a card mid-
              // list left its slot's State (which still holds the finished dust
              // cloud) attached to the character that shifted up into that slot —
              // showing an empty slot instead of the next card.
              (ctx, i) => CharacterCard(
                key: ValueKey(characters[i].id),
                character: characters[i],
                folderId: folderId,
              ),
              childCount: characters.length,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: SizedBox(
            height: hasMore || isLoadingMore ? 56 : 0,
            child: isLoadingMore
                ? Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.cs.primary,
                      ),
                    ),
                  )
                : null,
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
      ],
    );
  }
}

class _SortDirButton extends StatelessWidget {
  final bool isAsc;
  final VoidCallback onTap;

  const _SortDirButton({required this.isAsc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          tint: context.cs.surface,
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.18)),
          child: Center(
            child: AnimatedRotation(
              turns: isAsc ? 0.5 : 0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutBack,
              child: Icon(
                Icons.arrow_downward_rounded,
                size: 18,
                color: context.cs.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiceButton extends StatelessWidget {
  final VoidCallback onTap;

  /// Classic shuffle uses the dice icon; the randomizing (Holocard) overlay
  /// uses the stacked-cards icon.
  final bool standard;

  const _DiceButton({required this.onTap, this.standard = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          tint: context.cs.surface,
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.18)),
          child: Center(
            child: Icon(
              standard ? Icons.casino_rounded : Icons.style_rounded,
              size: 18,
              color: context.cs.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _FilterButton({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            GlassSurface(
              borderRadius: BorderRadius.circular(16),
              tint: context.cs.surface,
              border: Border.all(
                color: context.cs.primary.withValues(alpha: 0.18),
              ),
              child: Center(
                child: Icon(
                  Icons.filter_list_rounded,
                  size: 18,
                  color: context.cs.primary,
                ),
              ),
            ),
            if (count > 0)
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: context.cs.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SortTypePill extends StatelessWidget {
  final SortType sortBy;
  final ValueChanged<SortType> onChanged;

  const _SortTypePill({required this.sortBy, required this.onChanged});

  String get _label => switch (sortBy) {
    SortType.name => 'sort_name'.tr(),
    SortType.date => 'sort_date'.tr(),
    SortType.lastChat => 'Last chat',
  };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showPicker(context),
      child: SizedBox(
        height: 32,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          tint: context.cs.surface,
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.18)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.cs.primary,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: context.cs.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showPicker(BuildContext context) {
    BottomSheetItem build(String label, SortType type) => BottomSheetItem(
      label: label,
      actions: sortBy == type
          ? [
              BottomSheetAction(
                icon: Icons.check_rounded,
                color: context.cs.primary,
                onTap: () {
                  Navigator.of(context, rootNavigator: true).pop();
                  onChanged(type);
                },
              ),
            ]
          : const [],
      onTap: () {
        Navigator.of(context, rootNavigator: true).pop();
        onChanged(type);
      },
    );

    GlazeBottomSheet.show<void>(
      context,
      title: 'sort_by'.tr(),
      items: [
        build('sort_name'.tr(), SortType.name),
        build('sort_date'.tr(), SortType.date),
        build('Last chat', SortType.lastChat),
      ],
    );
  }
}
