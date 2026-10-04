import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/filter_sheet.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../catalog_models.dart';
import '../chub_account_provider.dart';
import '../janitor_account_provider.dart';
import '../services/chub_provider.dart';
import '../services/datacat/datacat_discovery.dart';
import '../services/janitor_provider.dart';
import 'catalog_controls.dart';
import 'janitor_blocked_content_section.dart';
import 'chub_login_sheet.dart';
import 'package:easy_localization/easy_localization.dart';

class CatalogFilterSheet extends ConsumerStatefulWidget {
  final CatalogFilters filters;
  final CatalogProvider provider;
  final ValueChanged<CatalogFilters> onApply;

  /// Chub's "Timeline" feed is served by its own endpoint that only consumes
  /// `nsfw` and `nsfl`; every other catalog filter is ignored. When set, the
  /// sheet hides those controls and shows a hint instead of leaving a wall of
  /// switches that would silently do nothing.
  final bool timelineMode;

  /// Called after the JanitorAI account block list is PATCHed (blocked tags or
  /// keywords changed), so the catalog list can be reloaded to reflect it.
  final VoidCallback? onBlockedTagsChanged;

  const CatalogFilterSheet({
    super.key,
    required this.filters,
    required this.provider,
    required this.onApply,
    this.timelineMode = false,
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

  // Chub-only content flags, mirrored 1:1 onto the API parameters.
  late bool _nsfwOnly;
  late bool _requireImages;
  late bool _requireLore;
  late bool _requireCustomPrompt;
  late bool _requireExampleDialogues;
  late bool _requireAlternateGreetings;
  late bool _recommendedVerified;
  late bool _excludeMine;
  late bool _inclusiveOr;
  late int _minAiRating;
  late int _minTags;

  Set<int> _selectedTagIds = {};
  Set<String> _selectedTagNames = {};

  List<CatalogTag> _allTags = [];

  /// Account-level blocked tags (JanitorAI only, when signed in). Loaded from
  /// the server on open and PATCHed back on dispose if changed. Null until the
  /// initial fetch lands (or when not applicable) so the section stays hidden.
  JanitorBlockList? _blockList;
  Set<int> _blockedTagIds = {};
  Set<String> _blockedKeywords = {};

  bool get _isJanitor => widget.provider == CatalogProvider.janitor;

  bool get _janitorBlockTagsEnabled =>
      _isJanitor && ref.read(janitorAccountProvider).isLoggedIn;

  @override
  void initState() {
    super.initState();
    _nsfw = widget.filters.nsfw;
    _nsfl = widget.filters.nsfl;
    _minTokens = widget.filters.minTokens;
    _maxTokens = widget.filters.maxTokens;
    _nsfwOnly = widget.filters.nsfwOnly;
    _requireImages = widget.filters.requireImages;
    _requireLore = widget.filters.requireLore;
    _requireCustomPrompt = widget.filters.requireCustomPrompt;
    _requireExampleDialogues = widget.filters.requireExampleDialogues;
    _requireAlternateGreetings = widget.filters.requireAlternateGreetings;
    _recommendedVerified = widget.filters.recommendedVerified;
    _excludeMine = widget.filters.excludeMine;
    _inclusiveOr = widget.filters.inclusiveOr;
    _minAiRating = widget.filters.minAiRating;
    _minTags = widget.filters.minTags;
    _selectedTagIds = Set.from(widget.filters.tagIds);
    _selectedTagNames = Set.from(widget.filters.tagNames);

    if (!widget.timelineMode) _loadTags();
    if (_janitorBlockTagsEnabled) _loadBlockedTags();
  }

  Future<void> _loadTags() async {
    List<CatalogTag> tags = [];
    if (widget.provider == CatalogProvider.chub) {
      tags = await fetchChubTags(
        apiKey: ref.read(chubAccountProvider).apiKey,
      );
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

    // Loaded second, so the sheet is usable with the curated tags while this
    // is still in flight.
    if (!_isJanitor) return;
    final popular = await fetchJanitorTopCustomTags();
    if (!mounted || popular.isEmpty) return;
    final merged = withPopularCustomTags(tags, popular);
    if (merged.length == tags.length) return;
    setState(() {
      _allTags = merged;
    });
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
    // Build the candidate up front and let freezed's deep equality decide
    // whether anything actually changed — the sheet edits a lot of fields now,
    // and hand-rolling the comparison is how a new one silently stops applying.
    final newFilters = CatalogFilters(
      sort: widget.filters.sort,
      nsfw: _nsfw,
      nsfl: _nsfl,
      tagIds: _selectedTagIds.toList()..sort(),
      tagNames: _selectedTagNames.toList()..sort(),
      excludeTagNames: widget.filters.excludeTagNames,
      minTokens: _minTokens,
      maxTokens: _maxTokens,
      nsfwOnly: _nsfwOnly,
      requireImages: _requireImages,
      requireLore: _requireLore,
      requireCustomPrompt: _requireCustomPrompt,
      requireExampleDialogues: _requireExampleDialogues,
      requireAlternateGreetings: _requireAlternateGreetings,
      recommendedVerified: _recommendedVerified,
      excludeMine: _excludeMine,
      inclusiveOr: _inclusiveOr,
      minAiRating: _minAiRating,
      minTags: _minTags,
    );

    if (newFilters != widget.filters) {
      final apply = widget.onApply;
      Future.microtask(() => apply(newFilters));
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

  /// Chub's own search refinements, appended right after the token range. They
  /// map 1:1 onto the parameters chub.ai's site sends, so their labels mirror
  /// what the site calls them.
  List<FilterSection> _chubFilterSections() {
    return [
      FilterToggleSection(
        label: 'catalog_filter_nsfw_only'.tr(),
        value: _nsfwOnly,
        onChanged: (v) => setState(() => _nsfwOnly = v),
      ),
      FilterToggleSection(
        label: 'catalog_filter_require_images'.tr(),
        value: _requireImages,
        onChanged: (v) => setState(() => _requireImages = v),
      ),
      FilterToggleSection(
        label: 'catalog_filter_require_lore'.tr(),
        value: _requireLore,
        onChanged: (v) => setState(() => _requireLore = v),
      ),
      FilterToggleSection(
        label: 'catalog_filter_require_custom_prompt'.tr(),
        value: _requireCustomPrompt,
        onChanged: (v) => setState(() => _requireCustomPrompt = v),
      ),
      FilterToggleSection(
        label: 'catalog_filter_require_example_dialogues'.tr(),
        value: _requireExampleDialogues,
        onChanged: (v) => setState(() => _requireExampleDialogues = v),
      ),
      FilterToggleSection(
        label: 'catalog_filter_require_alternate_greetings'.tr(),
        value: _requireAlternateGreetings,
        onChanged: (v) => setState(() => _requireAlternateGreetings = v),
      ),
      FilterToggleSection(
        label: 'catalog_filter_recommended_verified'.tr(),
        value: _recommendedVerified,
        onChanged: (v) => setState(() => _recommendedVerified = v),
      ),
      FilterToggleSection(
        label: 'catalog_filter_exclude_mine'.tr(),
        value: _excludeMine,
        onChanged: (v) => setState(() => _excludeMine = v),
      ),
      FilterToggleSection(
        label: 'catalog_filter_inclusive_or'.tr(),
        value: _inclusiveOr,
        onChanged: (v) => setState(() => _inclusiveOr = v),
      ),
      FilterNumberSection(
        title: 'catalog_filter_min_ai_rating'.tr(),
        label: 'catalog_min'.tr(),
        value: _minAiRating,
        onChanged: (v) => setState(() => _minAiRating = v),
      ),
      FilterNumberSection(
        title: 'catalog_filter_min_tags'.tr(),
        label: 'catalog_min'.tr(),
        value: _minTags,
        onChanged: (v) => setState(() => _minTags = v),
      ),
    ];
  }

  void _onNsflToggle(bool value) {
    if (!value) {
      // Disabling
      setState(() => _nsfl = false);
      return;
    }
    // chub.ai only serves NSFL to a signed-in account (and the public API
    // silently ignores the flag). Don't flip the switch — send them to log in,
    // then offer the warning again once there is an account behind it.
    if (!ref.read(chubAccountProvider).isLoggedIn) {
      _promptChubLoginForNsfl();
      return;
    }
    _confirmNsfl();
  }

  /// The site-side explanation shown when NSFL is switched on without an
  /// account, with a button into the Chub login sheet.
  void _promptChubLoginForNsfl() {
    GlazeBottomSheet.show<void>(
      context,
      title: 'catalog_filter_nsfl'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.lock_outline_rounded,
        description: 'chub_nsfl_login_desc'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'chub_nsfl_login_btn'.tr(),
          centered: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await showChubLoginSheet(context);
            if (!mounted) return;
            // Signed in via the WebView — carry the toggle through to the
            // warning instead of making them tap NSFL again.
            if (ref.read(chubAccountProvider).isLoggedIn) _confirmNsfl();
          },
        ),
      ],
    );
  }

  /// The destructive-content warning that gates actually turning NSFL on.
  void _confirmNsfl() {
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
  }

  @override
  Widget build(BuildContext context) {
    final timelineMode = widget.timelineMode;
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
        // Timeline's endpoint consumes only `nsfw`/`nsfl`; every other control
        // would silently do nothing, so it is replaced by a hint.
        if (timelineMode)
          const FilterCustomSection(child: _TimelineFiltersHint())
        else ...[
          // DataCat's Client API filters by text, tags, sort and paging only —
          // there are no token bounds to send. Showing the slider anyway would
          // be a control that silently does nothing.
          if (CatalogControls.supportsTokenRange(widget.provider))
            FilterRangeSection(
              title: 'catalog_token_range'.tr(),
              minLabel: 'catalog_min'.tr(),
              maxLabel: 'catalog_max'.tr(),
              min: _minTokens,
              max: _maxTokens,
              onMinChanged: (v) => setState(() => _minTokens = v),
              onMaxChanged: (v) => setState(() => _maxTokens = v),
            ),
          if (widget.provider == CatalogProvider.chub) ..._chubFilterSections(),
          FilterTagsSection(
            title: 'catalog_tags'.tr(),
            searchHint: 'catalog_search_tags'.tr(),
            tags: [for (final t in _allTags) FilterTag(id: t.id, name: t.name)],
            selectedIds: _selectedTagIds,
            selectedNames: _selectedTagNames,
            onToggle: _toggleTag,
            onClear: _clearTags,
            // JanitorAI: `/hampter/tags` only covers the curated tags searched by
            // id. Custom tags are free text (`custom_tags[]`), so they come from
            // the same `/tags/suggest` autocomplete the block list uses, and the
            // raw query can be searched verbatim.
            fetchSuggestions: _isJanitor ? fetchJanitorTagSuggestions : null,
            allowCustomTags: _isJanitor,
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
      ],
    );
  }
}

/// Explains why the filter sheet is nearly empty while Chub's Timeline feed is
/// selected: the feed's endpoint only reads `nsfw`/`nsfl`.
class _TimelineFiltersHint extends StatelessWidget {
  const _TimelineFiltersHint();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 16,
          color: context.cs.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'catalog_chub_timeline_no_filters'.tr(),
            style: TextStyle(
              fontSize: 13,
              color: context.cs.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}
