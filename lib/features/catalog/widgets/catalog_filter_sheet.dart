import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/widgets/filter_sheet.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../catalog_models.dart';
import '../janitor_account_provider.dart';
import '../services/chub_provider.dart';
import '../services/datacat_provider.dart';
import '../services/janitor_provider.dart';
import 'janitor_blocked_content_section.dart';
import 'package:easy_localization/easy_localization.dart';

class CatalogFilterSheet extends ConsumerStatefulWidget {
  final CatalogFilters filters;
  final CatalogProvider provider;
  final ValueChanged<CatalogFilters> onApply;

  /// Called after the JanitorAI account block list is PATCHed (blocked tags or
  /// keywords changed), so the catalog list can be reloaded to reflect it.
  final VoidCallback? onBlockedTagsChanged;

  const CatalogFilterSheet({
    super.key,
    required this.filters,
    required this.provider,
    required this.onApply,
    this.onBlockedTagsChanged,
  });

  @override
  ConsumerState<CatalogFilterSheet> createState() => _CatalogFilterSheetState();
}

class _CatalogFilterSheetState extends ConsumerState<CatalogFilterSheet> {
  late bool _nsfw;
  late bool _nsfl;
  late int _minTokens;
  late int _maxTokens;

  Set<int> _selectedTagIds = {};
  Set<String> _selectedTagNames = {};

  List<CatalogTag> _allTags = [];

  /// Account-level blocked tags (JanitorAI only, when signed in). Loaded from
  /// the server on open and PATCHed back on dispose if changed. Null until the
  /// initial fetch lands (or when not applicable) so the section stays hidden.
  JanitorBlockList? _blockList;
  Set<int> _blockedTagIds = {};
  Set<String> _blockedKeywords = {};

  bool get _janitorBlockTagsEnabled =>
      widget.provider == CatalogProvider.janitor &&
      ref.read(janitorAccountProvider).isLoggedIn;

  @override
  void initState() {
    super.initState();
    _nsfw = widget.filters.nsfw;
    _nsfl = widget.filters.nsfl;
    _minTokens = widget.filters.minTokens;
    _maxTokens = widget.filters.maxTokens;
    _selectedTagIds = Set.from(widget.filters.tagIds);
    _selectedTagNames = Set.from(widget.filters.tagNames);

    _loadTags();
    if (_janitorBlockTagsEnabled) _loadBlockedTags();
  }

  Future<void> _loadTags() async {
    List<CatalogTag> tags = [];
    if (widget.provider == CatalogProvider.chub) {
      tags = await fetchChubTags();
    } else if (widget.provider == CatalogProvider.datacat) {
      tags = await fetchDatacatTags();
    } else {
      tags = await fetchJanitorTags();
    }

    if (mounted) {
      setState(() {
        _allTags = tags;
      });
    }
  }

  Future<void> _loadBlockedTags() async {
    try {
      final list = await fetchJanitorBlockedContent();
      if (mounted) {
        setState(() {
          _blockList = list;
          _blockedTagIds = list.tags.toSet();
          _blockedKeywords = list.keywords.toSet();
        });
      }
    } catch (_) {
      // Not signed in / CF block / network — leave the section hidden.
    }
  }

  void _toggleBlockedTag(int id) {
    setState(() {
      if (!_blockedTagIds.remove(id)) _blockedTagIds.add(id);
    });
  }

  void _addBlockedKeyword(String keyword) {
    setState(() => _blockedKeywords.add(keyword));
  }

  void _removeBlockedKeyword(String keyword) {
    setState(() => _blockedKeywords.remove(keyword));
  }

  void _clearBlockedContent() {
    setState(() {
      _blockedTagIds.clear();
      _blockedKeywords.clear();
    });
  }

  @override
  void dispose() {
    // Only apply if changed
    final changed = _nsfw != widget.filters.nsfw ||
        _nsfl != widget.filters.nsfl ||
        _minTokens != widget.filters.minTokens ||
        _maxTokens != widget.filters.maxTokens ||
        _selectedTagIds.length != widget.filters.tagIds.length ||
        _selectedTagNames.length != widget.filters.tagNames.length ||
        !_selectedTagIds.containsAll(widget.filters.tagIds) ||
        !_selectedTagNames.containsAll(widget.filters.tagNames);

    if (changed) {
      final newTagIds = _selectedTagIds.toList()..sort();
      final newTagNames = _selectedTagNames.toList()..sort();
      final apply = widget.onApply;

      Future.microtask(() {
        apply(
          CatalogFilters(
            sort: widget.filters.sort,
            nsfw: _nsfw,
            nsfl: _nsfl,
            tagIds: newTagIds,
            tagNames: newTagNames,
            minTokens: _minTokens,
            maxTokens: _maxTokens,
          ),
        );
      });
    }

    _saveBlockedTagsIfChanged();
    super.dispose();
  }

  /// PATCHes the account block list if the blocked tags or keywords changed.
  /// Bots/creators are preserved from the fetched [_blockList]; only the tag id
  /// set and keyword list are replaced.
  void _saveBlockedTagsIfChanged() {
    final original = _blockList;
    if (original == null) return;
    final originalTags = original.tags.toSet();
    final originalKeywords = original.keywords.toSet();
    final tagsUnchanged = originalTags.length == _blockedTagIds.length &&
        originalTags.containsAll(_blockedTagIds);
    final keywordsUnchanged =
        originalKeywords.length == _blockedKeywords.length &&
            originalKeywords.containsAll(_blockedKeywords);
    if (tagsUnchanged && keywordsUnchanged) return;
    final updated = original.copyWith(
      tags: _blockedTagIds.toList()..sort(),
      keywords: _blockedKeywords.toList()..sort(),
    );
    final onChanged = widget.onBlockedTagsChanged;
    Future.microtask(() async {
      await saveJanitorBlockList(updated);
      // Reload the catalog so the server-side block list applies to results.
      onChanged?.call();
    });
  }

  void _toggleTag(FilterTag tag) {
    setState(() {
      if (tag.id != null) {
        if (!_selectedTagIds.remove(tag.id)) _selectedTagIds.add(tag.id!);
      } else {
        if (!_selectedTagNames.remove(tag.name)) _selectedTagNames.add(tag.name);
      }
    });
  }

  void _clearTags() {
    setState(() {
      _selectedTagIds.clear();
      _selectedTagNames.clear();
    });
  }

  void _onNsflToggle(bool value) {
    if (value) {
      // Trying to enable — show warning
      GlazeBottomSheet.show<void>(
        context,
        title: 'catalog_nsfl_warning_title'.tr(),
        bigInfo: BottomSheetBigInfo(
          icon: Icons.warning_amber_rounded,
          description: 'catalog_nsfl_warning_desc'.tr(),
        ),
        items: [
          BottomSheetItem(
            label: 'catalog_nsfl_btn'.tr(),
            isDestructive: true,
            centered: true,
            onTap: () {
              setState(() => _nsfl = true);
              Navigator.of(context, rootNavigator: true).pop();
            },
          ),
          BottomSheetItem(
            label: 'catalog_nsfl_btn_cancel'.tr(),
            centered: true,
            onTap: () => Navigator.of(context, rootNavigator: true).pop(),
          ),
        ],
      );
    } else {
      // Disabling
      setState(() => _nsfl = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilterSheet(
      title: 'catalog_filters'.tr(),
      sections: [
        FilterToggleSection(
          label: 'catalog_filter_nsfw'.tr(),
          value: _nsfw,
          onChanged: (v) => setState(() => _nsfw = v),
        ),
        if (widget.provider == CatalogProvider.chub)
          FilterToggleSection(
            label: 'catalog_filter_nsfl'.tr(),
            value: _nsfl,
            onChanged: _onNsflToggle,
            isDanger: true,
          ),
        FilterRangeSection(
          title: 'catalog_token_range'.tr(),
          minLabel: 'catalog_min'.tr(),
          maxLabel: 'catalog_max'.tr(),
          min: _minTokens,
          max: _maxTokens,
          onMinChanged: (v) => setState(() => _minTokens = v),
          onMaxChanged: (v) => setState(() => _maxTokens = v),
        ),
        FilterTagsSection(
          title: 'catalog_tags'.tr(),
          searchHint: 'catalog_search_tags'.tr(),
          tags: [for (final t in _allTags) FilterTag(id: t.id, name: t.name)],
          selectedIds: _selectedTagIds,
          selectedNames: _selectedTagNames,
          onToggle: _toggleTag,
          onClear: _clearTags,
        ),
        if (_blockList != null)
          FilterCustomSection(
            child: JanitorBlockedContentSection(
              allTags: _allTags,
              blockedTagIds: _blockedTagIds,
              blockedKeywords: _blockedKeywords,
              onToggleTag: _toggleBlockedTag,
              onAddKeyword: _addBlockedKeyword,
              onRemoveKeyword: _removeBlockedKeyword,
              onClear: _clearBlockedContent,
            ),
          ),
      ],
    );
  }
}
