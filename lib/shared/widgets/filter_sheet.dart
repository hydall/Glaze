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

/// A titled, searchable, multi-select tag picker row.
class FilterTagsSection extends FilterSection {
  final String title;
  final String searchHint;
  final List<FilterTag> tags;
  final Set<int> selectedIds;
  final Set<String> selectedNames;
  final ValueChanged<FilterTag> onToggle;
  final VoidCallback onClear;

  const FilterTagsSection({
    required this.title,
    required this.searchHint,
    required this.tags,
    required this.selectedIds,
    required this.selectedNames,
    required this.onToggle,
    required this.onClear,
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

  const FilterSheet({super.key, required this.title, required this.sections});

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: title,
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      body: ListView(
        children: [
          const SizedBox(height: 16),
          for (final section in sections) ..._buildSection(section),
          const SizedBox(height: 40),
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
}

class _FilterTags extends StatefulWidget {
  final FilterTagsSection section;
  const _FilterTags({required this.section});

  @override
  State<_FilterTags> createState() => _FilterTagsState();
}

class _FilterTagsState extends State<_FilterTags> {
  String _search = '';

  FilterTagsSection get _s => widget.section;

  bool _isSelected(FilterTag tag) {
    if (tag.id != null) return _s.selectedIds.contains(tag.id);
    return _s.selectedNames.contains(tag.name);
  }

  List<FilterTag> get _filtered {
    if (_search.isEmpty) return _s.tags;
    final q = _search.toLowerCase();
    return _s.tags.where((t) => t.name.toLowerCase().contains(q)).toList();
  }

  List<FilterTag> get _selectedList =>
      _s.tags.where(_isSelected).toList();

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
            style: const TextStyle(fontSize: 14, color: Colors.white),
            decoration: InputDecoration(
              hintText: _s.searchHint,
              hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
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
