import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _SectionLabel('catalog_blocked_tags'.tr()),
            if (_selectedCount > 0)
              GestureDetector(
                onTap: widget.onClear,
                child: Text(
                  'catalog_clear_tags'.tr(
                    namedArgs: {'count': '$_selectedCount'},
                  ),
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),

        // Selected chips (blocked tags + keywords)
        if (_selectedCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
              ),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final id in widget.blockedTagIds)
                    _selectedChip(_tagName(id), () => widget.onToggleTag(id)),
                  for (final k in widget.blockedKeywords)
                    _selectedChip(k, () => widget.onRemoveKeyword(k)),
                ],
              ),
            ),
          ),

        // Input
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: TextField(
            controller: _controller,
            style: const TextStyle(fontSize: 14, color: Colors.white),
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: 'catalog_blocked_search'.tr(),
              hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              isDense: true,
              suffixIcon: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(11),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            onChanged: _onChanged,
            onSubmitted: _addKeyword,
          ),
        ),

        // Suggestions
        if (_query.isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._tagMatches.map(
            (t) => _suggestionRow(
              icon: Icons.sell_outlined,
              label: t.name,
              onTap: () => _toggleTag(t.id!),
            ),
          ),
          ..._keywordMatches.map(
            (k) => _suggestionRow(
              icon: Icons.sell_outlined,
              label: k,
              onTap: () => _addKeyword(k),
            ),
          ),
          // Always offer blocking the raw text as a keyword.
          if (!widget.blockedKeywords.contains(_query))
            _suggestionRow(
              icon: Icons.add,
              label: 'catalog_blocked_add_keyword'.tr(
                namedArgs: {'keyword': _query},
              ),
              onTap: () => _addKeyword(_query),
            ),
        ],
      ],
    );
  }

  Widget _suggestionRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 16, color: context.cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectedChip(String label, VoidCallback onRemove) {
    return GestureDetector(
      onTap: onRemove,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.cs.primary),
          color: context.cs.primary.withValues(alpha: 0.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
            const SizedBox(width: 5),
            const Icon(Icons.close, size: 10, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: context.cs.onSurfaceVariant,
        letterSpacing: 0.6,
      ),
    );
  }
}
