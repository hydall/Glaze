import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import '../../../shared/widgets/filter_sheet.dart';

/// Filter state for the My Characters grid. Local characters carry no NSFW
/// flags, so favorites + tags + an estimated-token range are filterable.
class CharacterListFilters {
  static const int defaultMinTokens = 0;
  static const int defaultMaxTokens = 100000;

  final bool favOnly;
  final Set<String> tagNames;
  final int minTokens;
  final int maxTokens;

  const CharacterListFilters({
    this.favOnly = false,
    this.tagNames = const {},
    this.minTokens = defaultMinTokens,
    this.maxTokens = defaultMaxTokens,
  });

  bool get hasTokenFilter =>
      minTokens != defaultMinTokens || maxTokens != defaultMaxTokens;

  bool get isActive => favOnly || tagNames.isNotEmpty || hasTokenFilter;

  int get activeCount =>
      (favOnly ? 1 : 0) +
      tagNames.length +
      (minTokens != defaultMinTokens ? 1 : 0) +
      (maxTokens != defaultMaxTokens ? 1 : 0);

  CharacterListFilters copyWith({
    bool? favOnly,
    Set<String>? tagNames,
    int? minTokens,
    int? maxTokens,
  }) =>
      CharacterListFilters(
        favOnly: favOnly ?? this.favOnly,
        tagNames: tagNames ?? this.tagNames,
        minTokens: minTokens ?? this.minTokens,
        maxTokens: maxTokens ?? this.maxTokens,
      );
}

/// Reuses the shared [FilterSheet] to filter the My Characters grid by
/// favorites and tags. Mirrors [CatalogFilterSheet]'s apply-on-dispose pattern.
class CharacterFilterSheet extends StatefulWidget {
  final CharacterListFilters filters;
  final List<String> allTags;
  final ValueChanged<CharacterListFilters> onApply;

  const CharacterFilterSheet({
    super.key,
    required this.filters,
    required this.allTags,
    required this.onApply,
  });

  @override
  State<CharacterFilterSheet> createState() => _CharacterFilterSheetState();
}

class _CharacterFilterSheetState extends State<CharacterFilterSheet> {
  late bool _favOnly;
  late Set<String> _selectedTagNames;
  late int _minTokens;
  late int _maxTokens;

  @override
  void initState() {
    super.initState();
    _favOnly = widget.filters.favOnly;
    _selectedTagNames = Set.from(widget.filters.tagNames);
    _minTokens = widget.filters.minTokens;
    _maxTokens = widget.filters.maxTokens;
  }

  @override
  void dispose() {
    final changed = _favOnly != widget.filters.favOnly ||
        _minTokens != widget.filters.minTokens ||
        _maxTokens != widget.filters.maxTokens ||
        _selectedTagNames.length != widget.filters.tagNames.length ||
        !_selectedTagNames.containsAll(widget.filters.tagNames);

    if (changed) {
      final apply = widget.onApply;
      final result = CharacterListFilters(
        favOnly: _favOnly,
        tagNames: Set.from(_selectedTagNames),
        minTokens: _minTokens,
        maxTokens: _maxTokens,
      );
      Future.microtask(() => apply(result));
    }
    super.dispose();
  }

  void _toggleTag(FilterTag tag) {
    setState(() {
      if (!_selectedTagNames.remove(tag.name)) {
        _selectedTagNames.add(tag.name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return FilterSheet(
      title: 'catalog_filters'.tr(),
      sections: [
        FilterToggleSection(
          label: 'section_favorites'.tr(),
          value: _favOnly,
          onChanged: (v) => setState(() => _favOnly = v),
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
          tags: [for (final t in widget.allTags) FilterTag(name: t)],
          selectedIds: const {},
          selectedNames: _selectedTagNames,
          onToggle: _toggleTag,
          onClear: () => setState(() => _selectedTagNames.clear()),
        ),
      ],
    );
  }
}
