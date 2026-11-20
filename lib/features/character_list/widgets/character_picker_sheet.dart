import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/character.dart';
import '../../../core/state/character_folder_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/picker_search_field.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../character_sort.dart';
import '../filtered_characters_provider.dart';
import 'character_filter_sheet.dart';
import 'character_folders_section.dart';
import 'character_grid.dart';
import 'character_variations_sheet.dart';

/// What a tap on a card with several variations picks.
enum CharacterPickTarget {
  /// The whole variation group: the card's own (representative) row is the
  /// result. Lorebook bindings work on groups.
  group,

  /// One concrete variation: a group with several opens the variations grid to
  /// choose from. Preset and persona bindings are per character row.
  variation,
}

/// Opens the library — the same cards, folders, search, filters and sorting
/// as the main My Characters screen — to pick one character for a binding.
///
/// [excludedIds] are already bound: group ids for [CharacterPickTarget.group],
/// character ids for [CharacterPickTarget.variation] (a group stays listed
/// while any of its variations is still free).
Future<Character?> showCharacterPicker(
  BuildContext context, {
  required String title,
  Set<String> excludedIds = const {},
  CharacterPickTarget target = CharacterPickTarget.group,
}) {
  return showGlazeSheet<Character>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CharacterPickerSheet(
      title: title,
      excludedIds: excludedIds,
      target: target,
    ),
  );
}

class CharacterPickerSheet extends ConsumerStatefulWidget {
  final String title;
  final Set<String> excludedIds;
  final CharacterPickTarget target;

  const CharacterPickerSheet({
    super.key,
    required this.title,
    this.excludedIds = const {},
    this.target = CharacterPickTarget.group,
  });

  @override
  ConsumerState<CharacterPickerSheet> createState() =>
      _CharacterPickerSheetState();
}

class _CharacterPickerSheetState extends ConsumerState<CharacterPickerSheet> {
  // Same defaults as the main screen, so the picker opens in the order the
  // library is usually seen in.
  SortType _sortBy = SortType.date;
  SortDir _sortDir = SortDir.desc;
  CharacterListFilters _filters = const CharacterListFilters();
  String _search = '';
  String? _folderId;
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  CharacterQuery get _query => CharacterQuery(
    search: _search,
    favOnly: _folderId == kFavoritesFolderId || _filters.favOnly,
    tags: _filters.tagNames.toList()..sort(),
    minTokens: _filters.minTokens,
    maxTokens: _filters.maxTokens,
    hasTokenFilter: _filters.hasTokenFilter,
    sortBy: _sortBy,
    sortDir: _sortDir,
    folderId: _folderId == kFavoritesFolderId ? null : _folderId,
  );

  String _groupIdOf(Character c) =>
      c.variantGroupId.isEmpty ? c.id : c.variantGroupId;

  /// Drops cards that have nothing left to bind.
  List<Character> _available(List<Character> cards, List<Character> all) {
    final excluded = widget.excludedIds;
    if (excluded.isEmpty) return cards;
    if (widget.target == CharacterPickTarget.group) {
      return cards.where((c) => !excluded.contains(_groupIdOf(c))).toList();
    }
    final freeGroups = <String>{
      for (final c in all)
        if (!excluded.contains(c.id)) _groupIdOf(c),
    };
    return cards.where((c) => freeGroups.contains(_groupIdOf(c))).toList();
  }

  Future<void> _onPick(Character card) async {
    final nav = Navigator.of(context, rootNavigator: true);
    if (widget.target == CharacterPickTarget.variation) {
      final all = ref.read(charactersProvider).value ?? const <Character>[];
      final groupId = _groupIdOf(card);
      final free = all
          .where(
            (c) =>
                _groupIdOf(c) == groupId && !widget.excludedIds.contains(c.id),
          )
          .toList();
      final siblings = all.where((c) => _groupIdOf(c) == groupId).length;
      if (siblings > 1) {
        // One free variation left: nothing to choose between.
        final picked = free.length == 1
            ? free.first
            : await showGlazeSheet<Character>(
                context: context,
                isScrollControlled: true,
                useRootNavigator: true,
                useSafeArea: true,
                backgroundColor: Colors.transparent,
                builder: (_) => CharacterVariationsSheet(
                  groupId: groupId,
                  sourceId: card.id,
                  picking: true,
                  excludedIds: widget.excludedIds,
                ),
              );
        if (picked != null && mounted) nav.pop(picked);
        return;
      }
    }
    nav.pop(card);
  }

  void _openFilters() {
    final all = ref.read(charactersProvider).value ?? const <Character>[];
    final allTags = {for (final c in all) ...c.tags}.toList()..sort();
    showGlazeSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CharacterFilterSheet(
        filters: _filters,
        allTags: allTags,
        onApply: (f) {
          if (mounted) setState(() => _filters = f);
        },
      ),
    );
  }

  String? _folderTitle() {
    final id = _folderId;
    if (id == null) return null;
    if (id == kFavoritesFolderId) return 'section_favorites'.tr();
    final folders = ref.watch(characterFoldersProvider).value ?? const [];
    return folders.where((f) => f.id == id).firstOrNull?.name;
  }

  @override
  Widget build(BuildContext context) {
    final folderTitle = _folderTitle();
    return SheetView(
      title: folderTitle ?? widget.title,
      showBack: _folderId != null,
      onBack: _folderId != null ? () => setState(() => _folderId = null) : null,
      // Opens nearly full height: the list is the whole point of the sheet.
      collapsedFraction: 0.92,
      headerBottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: PickerSearchField(
          controller: _searchCtrl,
          hint: 'search_characters'.tr(),
          onChanged: (v) => setState(() => _search = v.trim()),
        ),
      ),
      body: Builder(builder: (context) => _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final inset = MediaQuery.paddingOf(context);
    final charsAsync = ref.watch(charactersProvider);
    if (charsAsync.isLoading && !charsAsync.hasValue) {
      return Center(child: GlazeSpinner(color: context.cs.primary));
    }
    final all = charsAsync.value ?? const <Character>[];
    final cards = _available(
      ref.watch(filteredCharactersProvider(_query)),
      all,
    );

    final atRoot = _folderId == null;
    final showFolders = atRoot && _search.isEmpty && !_filters.isActive;
    final hasFavorites = all.any((c) => c.fav);

    return CharacterGrid(
      characters: cards,
      totalCount: cards.length,
      sortBy: _sortBy,
      sortDir: _sortDir,
      topPadding: inset.top,
      bottomPadding: inset.bottom + 20,
      filterCount: _filters.activeCount,
      onFilterTap: _openFilters,
      onSortDirToggle: () => setState(() {
        _sortDir = _sortDir == SortDir.asc ? SortDir.desc : SortDir.asc;
      }),
      onSortTypeChanged: (t) => setState(() => _sortBy = t),
      onPick: _onPick,
      headerSliver: showFolders
          ? SliverToBoxAdapter(
              child: CharacterFoldersSection(
                editable: false,
                showFavorites: hasFavorites,
                onOpenFavorites: () =>
                    setState(() => _folderId = kFavoritesFolderId),
                onOpenFolder: (id) => setState(() => _folderId = id),
              ),
            )
          : null,
      emptyState: cards.isEmpty
          ? Center(
              child: Text(
                _folderId != null && _search.isEmpty && !_filters.isActive
                    ? 'folder_empty'.tr()
                    : 'no_characters'.tr(),
                style: TextStyle(color: context.cs.onSurfaceVariant),
              ),
            )
          : null,
    );
  }
}
