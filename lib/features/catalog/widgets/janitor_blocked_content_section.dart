import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/filter_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../catalog_models.dart';
import '../services/janitor_provider.dart';

/// JanitorAI account block-list control for the catalog filter sheet.
///
/// To the user everything here is just a "tag". Under the hood JanitorAI splits
/// them into curated [allTags] (blocked by id → `tags`) and free-text
/// [keywords] (custom tags blocked by name); "keyword" is only the API's name.
/// As the user types we filter the curated tags locally and query
/// `/tags/suggest` for the rest ([fetchJanitorTagSuggestions]); the raw text can
/// also be blocked verbatim. Selected entries show as removable chips, with no
/// visual distinction between the two backing lists. The owner persists the
/// resulting sets — see `CatalogFilterSheet`.
class JanitorBlockedContentSection extends StatefulWidget {
  final List<CatalogTag> allTags;
  final Set<int> blockedTagIds;
  final Set<String> blockedKeywords;
  final ValueChanged<int> onToggleTag;
  final ValueChanged<String> onAddKeyword;
  final ValueChanged<String> onRemoveKeyword;
  final VoidCallback onClear;

  const JanitorBlockedContentSection({
    super.key,
    required this.allTags,
    required this.blockedTagIds,
    required this.blockedKeywords,
    required this.onToggleTag,
    required this.onAddKeyword,
    required this.onRemoveKeyword,
    required this.onClear,
  });

  @override
  State<JanitorBlockedContentSection> createState() =>
      _JanitorBlockedContentSectionState();
}

class _JanitorBlockedContentSectionState
    extends State<JanitorBlockedContentSection> {
  final _controller = TextEditingController();
  Timer? _debounce;

  /// Keyword suggestions for the current [_query], from `/tags/suggest`.
  List<String> _suggestions = [];
  bool _loading = false;

  /// The query the in-flight / last suggestion fetch was for — guards against
  /// out-of-order responses overwriting newer results.
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  String _tagName(int id) =>
      widget.allTags
          .firstWhere(
            (t) => t.id == id,
            orElse: () => CatalogTag(id: id, name: '#$id'),
          )
          .name;

  int get _selectedCount =>
      widget.blockedTagIds.length + widget.blockedKeywords.length;

  void _onChanged(String value) {
    final q = value.trim();
    setState(() => _query = q);
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() {
        _suggestions = [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 250), () => _fetch(q));
  }

  Future<void> _fetch(String q) async {
    final results = await fetchJanitorTagSuggestions(q);
    if (!mounted || q != _query) return;
    setState(() {
      _suggestions = results;
      _loading = false;
    });
  }

  void _addKeyword(String keyword) {
    final k = keyword.trim();
    if (k.isEmpty) return;
    widget.onAddKeyword(k);
    _reset();
  }

  void _toggleTag(int id) {
    widget.onToggleTag(id);
    _reset();
  }

  void _reset() {
    _controller.clear();
    setState(() {
      _query = '';
      _suggestions = [];
      _loading = false;
    });
  }

  /// Curated tags whose name matches the query and aren't already blocked.
  List<CatalogTag> get _tagMatches {
    if (_query.isEmpty) return const [];
    final q = _query.toLowerCase();
    return widget.allTags
        .where((t) =>
            t.id != null &&
            !widget.blockedTagIds.contains(t.id) &&
            t.name.toLowerCase().contains(q))
        .take(8)
        .toList();
  }

  List<String> get _keywordMatches => _suggestions
      .where((s) => !widget.blockedKeywords.contains(s))
      .take(8)
      .toList();

  @override
  Widget build(BuildContext context) {
    return MenuGroup(
      header: 'catalog_blocked_tags'.tr(),
      headerVariant: MenuGroupHeaderVariant.accentCaps,
      headerTrailing: _selectedCount > 0
          ? FilterClearButton(count: _selectedCount, onTap: widget.onClear)
          : null,
      items: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Blocked tags and keywords, indistinguishable on purpose.
              if (_selectedCount > 0) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final id in widget.blockedTagIds)
                      FilterTagChip(
                        label: _tagName(id),
                        selected: true,
                        onTap: () => widget.onToggleTag(id),
                      ),
                    for (final k in widget.blockedKeywords)
                      FilterTagChip(
                        label: k,
                        selected: true,
                        onTap: () => widget.onRemoveKeyword(k),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              FilterSearchField(
                controller: _controller,
                hint: 'catalog_blocked_search'.tr(),
                loading: _loading,
                onChanged: _onChanged,
                onClear: _reset,
                onSubmitted: _addKeyword,
              ),
              if (_query.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // Always offer blocking the raw text as a keyword.
                    if (!widget.blockedKeywords.contains(_query))
                      FilterTagChip(
                        label: 'catalog_blocked_add_keyword'.tr(
                          namedArgs: {'keyword': _query},
                        ),
                        icon: Icons.block_rounded,
                        onTap: () => _addKeyword(_query),
                      ),
                    for (final t in _tagMatches)
                      FilterTagChip(
                        label: t.name,
                        onTap: () => _toggleTag(t.id!),
                      ),
                    for (final k in _keywordMatches)
                      FilterTagChip(label: k, onTap: () => _addKeyword(k)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
