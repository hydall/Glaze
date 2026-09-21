import 'dart:async';

import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import '../theme/app_colors.dart';
import 'sheet_view.dart';

/// A selectable tag for a [FilterTagsSection]. Identified by [id] when the
/// source provides one (e.g. catalog tags), otherwise matched by [name]
/// (e.g. local character tags).
class FilterTag {
  final int? id;
  final String name;
  const FilterTag({this.id, required this.name});
}

/// Base type for the configurable rows rendered by [FilterSheet].
///
/// The sheet itself is presentational and stateless — the owner holds the
/// filter state, rebuilds with fresh section configs on every change, and is
/// responsible for committing the result (e.g. on dispose).
sealed class FilterSection {
  const FilterSection();
}

/// A single labelled on/off switch row.
class FilterToggleSection extends FilterSection {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool isDanger;

  const FilterToggleSection({
    required this.label,
    required this.value,
    required this.onChanged,
    this.isDanger = false,
  });
}

/// A titled min/max integer range row with two numeric fields.
class FilterRangeSection extends FilterSection {
  final String title;
  final String minLabel;
  final String maxLabel;
  final int min;
  final int max;
  final ValueChanged<int> onMinChanged;
  final ValueChanged<int> onMaxChanged;

  const FilterRangeSection({
    required this.title,
    required this.minLabel,
    required this.maxLabel,
    required this.min,
    required this.max,
    required this.onMinChanged,
    required this.onMaxChanged,
  });
}

/// A titled row with a single integer field.
class FilterNumberSection extends FilterSection {
  final String title;
  final String label;
  final int value;
  final String? hint;
  final ValueChanged<int> onChanged;

  const FilterNumberSection({
    required this.title,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
  });
}

/// A titled, searchable, multi-select tag picker row.
///
/// [tags] is the curated list rendered as a chip grid and filtered locally.
/// Sources that also accept free-text tags (JanitorAI custom tags, chub topics)
/// can supply [fetchSuggestions] and/or [allowCustomTags] so the query can
/// resolve to a name-based [FilterTag] that isn't in [tags].
class FilterTagsSection extends FilterSection {
  final String title;
  final String searchHint;
  final List<FilterTag> tags;
  final Set<int> selectedIds;
  final Set<String> selectedNames;
  final ValueChanged<FilterTag> onToggle;
  final VoidCallback onClear;

  /// Remote autocomplete for tags [tags] doesn't cover. Called with the trimmed
  /// query after a short debounce; implementations must resolve to an empty
  /// list on error rather than throwing.
  final Future<List<String>> Function(String query)? fetchSuggestions;

  /// When true the raw query can be selected verbatim as a name-based tag,
  /// even when neither [tags] nor the suggestions contain it.
  final bool allowCustomTags;

  const FilterTagsSection({
    required this.title,
    required this.searchHint,
    required this.tags,
    required this.selectedIds,
    required this.selectedNames,
    required this.onToggle,
    required this.onClear,
    this.fetchSuggestions,
    this.allowCustomTags = false,
  });
}

/// An arbitrary feature-specific widget rendered inline as a section. Use for
/// rows the descriptor types above can't express (e.g. the JanitorAI blocked
/// tags + keywords control with its own autocomplete).
class FilterCustomSection extends FilterSection {
  final Widget child;
  const FilterCustomSection({required this.child});
}

/// Generic, reusable filter bottom sheet.
///
/// Renders an ordered list of [FilterSection]s inside a [SheetView]. Used by
/// the catalog filters and the My Characters filters; add new consumers by
/// composing the section descriptors above.
class FilterSheet extends StatelessWidget {
  final String title;
  final List<FilterSection> sections;

  /// Sizes the sheet to its sections instead of opening at the standard sheet
  /// height. Use it for short filter sets (a single range row, say), where the
  /// default height is mostly empty space.
  final bool fitContent;

  const FilterSheet({
    super.key,
    required this.title,
    required this.sections,
    this.fitContent = false,
  });

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: title,
      showHandle: true,
      fitContent: fitContent,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      // A fitted sheet gives its body unbounded height, so the list has to
      // shrink-wrap; the trailing spacer only exists to keep the last section
      // clear of the sheet's bottom edge on the scrollable variant.
      body: ListView(
        shrinkWrap: fitContent,
        children: [
          const SizedBox(height: 16),
          for (final section in sections) ..._buildSection(section),
          SizedBox(height: fitContent ? 8 : 40),
        ],
      ),
    );
  }

  List<Widget> _buildSection(FilterSection section) {
    return switch (section) {
      FilterToggleSection() => [_FilterToggleTile(section: section)],
      FilterRangeSection() => [
        const SizedBox(height: 20),
        _FilterRange(section: section),
      ],
      FilterNumberSection() => [
        const SizedBox(height: 20),
        _FilterNumber(section: section),
      ],
      FilterTagsSection() => [
        const SizedBox(height: 20),
        _FilterTags(section: section),
      ],
      FilterCustomSection() => [
        const SizedBox(height: 20),
        section.child,
      ],
    };
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

class _FilterToggleTile extends StatelessWidget {
  final FilterToggleSection section;
  const _FilterToggleTile({required this.section});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            section.label,
            style: TextStyle(color: context.cs.onSurface, fontSize: 15),
          ),
          Switch(
            value: section.value,
            onChanged: section.onChanged,
            activeTrackColor: section.isDanger
                ? Colors.redAccent
                : context.cs.primary,
            activeThumbColor: Colors.white,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
            inactiveThumbColor: Colors.white,
          ),
        ],
      ),
    );
  }
}

class _FilterRange extends StatelessWidget {
  final FilterRangeSection section;
  const _FilterRange({required this.section});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(section.title),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _numberField(
                section.minLabel,
                section.min,
                section.onMinChanged,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '—',
                style: TextStyle(
                  color: context.cs.onSurfaceVariant,
                  fontSize: 18,
                ),
              ),
            ),
            Expanded(
              child: _numberField(
                section.maxLabel,
                section.max,
                section.onMaxChanged,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A section with a single labelled integer field, for one-dimensional numeric
/// filters (e.g. Chub's minimum AI rating) that a min/max range doesn't fit.
class _FilterNumber extends StatelessWidget {
  final FilterNumberSection section;
  const _FilterNumber({required this.section});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(section.title),
        const SizedBox(height: 10),
        _numberField(section.label, section.value, section.onChanged),
        if (section.hint != null) ...[
          const SizedBox(height: 6),
          Text(
            section.hint!,
            style: TextStyle(
              fontSize: 11,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

Widget _numberField(String label, int value, ValueChanged<int> onChanged) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.4),
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
      const SizedBox(height: 4),
      Container(
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: TextField(
          controller: TextEditingController(text: '$value'),
          keyboardType: TextInputType.number,
          style: const TextStyle(fontSize: 14, color: Colors.white),
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
          ),
          onSubmitted: (v) {
            final p = int.tryParse(v);
            if (p != null) onChanged(p);
          },
        ),
      ),
    ],
  );
}

class _FilterTags extends StatefulWidget {
  final FilterTagsSection section;
  const _FilterTags({required this.section});

  @override
  State<_FilterTags> createState() => _FilterTagsState();
}

class _FilterTagsState extends State<_FilterTags> {
  final _controller = TextEditingController();
  Timer? _debounce;

  /// Trimmed query. Doubles as the guard for [_fetch] so an out-of-order
  /// response can't overwrite results for a newer query.
  String _search = '';

  /// Free-text suggestions for [_search], from [FilterTagsSection.fetchSuggestions].
  List<String> _suggestions = [];
  bool _loading = false;

  FilterTagsSection get _s => widget.section;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  bool _isSelected(FilterTag tag) {
    if (tag.id != null) return _s.selectedIds.contains(tag.id);
    return _s.selectedNames.contains(tag.name);
  }

  void _onSearchChanged(String value) {
    final q = value.trim();
    setState(() => _search = q);
    _debounce?.cancel();
    if (_s.fetchSuggestions == null) return;
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
    final results = await _s.fetchSuggestions!(q);
    if (!mounted || q != _search) return;
    setState(() {
      _suggestions = results;
      _loading = false;
    });
  }

  /// Selects [name] as a name-based tag (no id) and clears the query.
  void _addCustomTag(String name) {
    final n = name.trim();
    if (n.isEmpty || _s.selectedNames.contains(n)) return;
    _s.onToggle(FilterTag(name: n));
    _reset();
  }

  void _reset() {
    _controller.clear();
    setState(() {
      _search = '';
      _suggestions = [];
      _loading = false;
    });
  }

  List<FilterTag> get _filtered {
    if (_search.isEmpty) return _s.tags;
    final q = _search.toLowerCase();
    return _s.tags.where((t) => t.name.toLowerCase().contains(q)).toList();
  }

  /// Names already offered by the curated grid — suggestions that duplicate one
  /// would just be a second way to pick the same chip.
  Set<String> get _knownNames =>
      {for (final t in _s.tags) t.name.toLowerCase()};

  /// Suggested custom tags for the current query, minus curated and already
  /// selected ones.
  List<String> get _customMatches {
    if (_search.isEmpty || _suggestions.isEmpty) return const [];
    final known = _knownNames;
    final seen = <String>{};
    final out = <String>[];
    for (final s in _suggestions) {
      final name = s.trim();
      if (name.isEmpty) continue;
      if (known.contains(name.toLowerCase())) continue;
      if (_s.selectedNames.contains(name)) continue;
      if (!seen.add(name.toLowerCase())) continue;
      out.add(name);
      if (out.length == 8) break;
    }
    return out;
  }

  /// Whether to offer the raw query as a custom tag — only when it isn't
  /// already reachable as a curated chip, a suggestion or a selected tag.
  bool get _canAddRaw {
    if (!_s.allowCustomTags || _search.isEmpty) return false;
    final q = _search.toLowerCase();
    if (_knownNames.contains(q)) return false;
    if (_s.selectedNames.any((n) => n.toLowerCase() == q)) return false;
    return !_customMatches.any((s) => s.toLowerCase() == q);
  }

  /// Selected curated chips plus selected custom tags, which have no entry in
  /// [FilterTagsSection.tags] and would otherwise be invisible.
  List<FilterTag> get _selectedList {
    final list = _s.tags.where(_isSelected).toList();
    final shown = {
      for (final t in _s.tags)
        if (t.id == null) t.name,
    };
    for (final name in _s.selectedNames) {
      if (!shown.contains(name)) list.add(FilterTag(name: name));
    }
    return list;
  }

  int get _selectedCount => _s.selectedIds.length + _s.selectedNames.length;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _SectionLabel(_s.title),
            if (_selectedCount > 0)
              GestureDetector(
                onTap: _s.onClear,
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

        // Selected preview
        if (_selectedList.isNotEmpty)
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
                children: _selectedList
                    .map((t) => _chip(t, active: true))
                    .toList(),
              ),
            ),
          ),

        // Search
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
            textInputAction: _s.allowCustomTags ? TextInputAction.done : null,
            decoration: InputDecoration(
              hintText: _s.searchHint,
              hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
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
            onChanged: _onSearchChanged,
            onSubmitted: _s.allowCustomTags ? _addCustomTag : null,
          ),
        ),

        // Custom (name-based) tag suggestions — sources without a curated id.
        if (_customMatches.isNotEmpty || _canAddRaw) ...[
          const SizedBox(height: 6),
          ..._customMatches.map(
            (name) => _suggestionRow(
              icon: Icons.sell_outlined,
              label: name,
              onTap: () => _addCustomTag(name),
            ),
          ),
          if (_canAddRaw)
            _suggestionRow(
              icon: Icons.add,
              label: 'catalog_add_custom_tag'.tr(
                namedArgs: {'tag': _search},
              ),
              onTap: () => _addCustomTag(_search),
            ),
        ],
        const SizedBox(height: 12),

        // Grid
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _filtered
              .map((t) => _chip(t, active: _isSelected(t)))
              .toList(),
        ),
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

  Widget _chip(FilterTag tag, {required bool active}) {
    return GestureDetector(
      onTap: () => _s.onToggle(tag),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active
                ? context.cs.primary
                : Colors.white.withValues(alpha: 0.12),
          ),
          color: active
              ? context.cs.primary.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tag.name,
              style: TextStyle(
                fontSize: 12,
                color: active
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.65),
              ),
            ),
            if (active) ...[
              const SizedBox(width: 5),
              const Icon(Icons.close, size: 10, color: Colors.white),
            ],
          ],
        ),
      ),
    );
  }
}
