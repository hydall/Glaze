import 'dart:async';

import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import '../../core/platform/haptics.dart';
import '../theme/app_colors.dart';
import 'filter_sheet.dart';
import 'glaze_spinner.dart';
import 'menu_group.dart';

/// The tags card of a [FilterSheet]: header with a clear action, the
/// section's option switches, the current selection, a search field and a
/// chip grid folded to [FilterTagsSection.collapsedCount] chips.
///
/// While a query is typed the grid shows the local matches followed by the
/// remote suggestions (and, where allowed, the raw query) as one list, so the
/// source of a tag never changes how it is picked.
class FilterTagPicker extends StatefulWidget {
  final FilterTagsSection section;
  const FilterTagPicker({super.key, required this.section});

  @override
  State<FilterTagPicker> createState() => _FilterTagPickerState();
}

class _FilterTagPickerState extends State<FilterTagPicker> {
  final _controller = TextEditingController();
  Timer? _debounce;

  /// Trimmed query. Doubles as the guard for [_fetch] so an out-of-order
  /// response can't overwrite results for a newer query.
  String _search = '';

  /// Free-text suggestions for [_search], from [FilterTagsSection.fetchSuggestions].
  List<String> _suggestions = [];
  bool _loading = false;

  /// Whether the folded grid has been opened. Folds again on a new query.
  bool _expanded = false;

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
    if (q == _search) return;
    setState(() {
      _search = q;
      _expanded = false;
    });
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
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _search = '';
      _suggestions = [];
      _loading = false;
      _expanded = false;
    });
  }

  /// Names already offered by the curated grid — suggestions that duplicate one
  /// would just be a second way to pick the same chip.
  Set<String> get _knownNames =>
      {for (final t in _s.tags) t.name.toLowerCase()};

  /// Curated tags matching the query, the ones that start with it first.
  List<FilterTag> get _localMatches {
    final q = _search.toLowerCase();
    final starts = <FilterTag>[];
    final contains = <FilterTag>[];
    for (final t in _s.tags) {
      if (_isSelected(t)) continue;
      final name = t.name.toLowerCase();
      if (name.startsWith(q)) {
        starts.add(t);
      } else if (name.contains(q)) {
        contains.add(t);
      }
    }
    return [...starts, ...contains];
  }

  /// Suggested custom tags for the current query, minus curated and already
  /// selected ones.
  List<FilterTag> get _remoteMatches {
    if (_search.isEmpty || _suggestions.isEmpty) return const [];
    final known = _knownNames;
    final selected = {for (final n in _s.selectedNames) n.toLowerCase()};
    final seen = <String>{};
    final out = <FilterTag>[];
    for (final s in _suggestions) {
      final name = s.trim();
      final lower = name.toLowerCase();
      if (name.isEmpty || known.contains(lower) || selected.contains(lower)) {
        continue;
      }
      if (seen.add(lower)) out.add(FilterTag(name: name));
    }
    return out;
  }

  /// Whether to offer the raw query as a custom tag — only when it isn't
  /// already reachable as a curated chip, a suggestion or a selected tag.
  bool _canAddRaw(List<FilterTag> remote) {
    if (!_s.allowCustomTags || _search.isEmpty) return false;
    final q = _search.toLowerCase();
    if (_knownNames.contains(q)) return false;
    if (_s.selectedNames.any((n) => n.toLowerCase() == q)) return false;
    return !remote.any((t) => t.name.toLowerCase() == q);
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
    final selected = _selectedList;
    return MenuGroup(
      header: _s.title,
      headerVariant: MenuGroupHeaderVariant.accentCaps,
      headerTrailing: _selectedCount > 0
          ? FilterClearButton(count: _selectedCount, onTap: _s.onClear)
          : null,
      items: [
        for (final option in _s.options) filterRow(option),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (selected.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in selected)
                      FilterTagChip(
                        label: t.name,
                        selected: true,
                        onTap: () => _s.onToggle(t),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              FilterSearchField(
                controller: _controller,
                hint: _s.searchHint,
                loading: _loading,
                onChanged: _onSearchChanged,
                onClear: _reset,
                onSubmitted: _s.allowCustomTags ? _addCustomTag : null,
              ),
              const SizedBox(height: 12),
              _buildGrid(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGrid(BuildContext context) {
    if (_s.loading && _s.tags.isEmpty && _search.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: GlazeSpinner(strokeWidth: 2),
          ),
        ),
      );
    }

    final searching = _search.isNotEmpty;
    final remote = searching ? _remoteMatches : const <FilterTag>[];
    final tags = searching
        ? [..._localMatches, ...remote]
        : _s.tags.where((t) => !_isSelected(t)).toList();
    final addRaw = searching && _canAddRaw(remote);

    if (tags.isEmpty && !addRaw) {
      return _hint(
        context,
        searching
            ? (_loading ? 'catalog_searching_tags' : 'filter_tags_nothing_found')
                  .tr()
            : 'filter_tags_none'.tr(),
      );
    }

    // Folding a list only a few chips longer than the fold would trade a
    // couple of chips for a button of the same size.
    final limit = _s.collapsedCount;
    final folds = tags.length > limit + 6;
    final shown = folds && !_expanded ? tags.take(limit) : tags;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in shown)
              FilterTagChip(
                label: t.name,
                onTap: () {
                  _s.onToggle(t);
                  // A pick from a search result ends the search: the chip
                  // moves up into the selection, and the query is spent.
                  if (searching) _reset();
                },
              ),
            if (addRaw)
              FilterTagChip(
                label: 'catalog_add_custom_tag'.tr(namedArgs: {'tag': _search}),
                icon: Icons.add_rounded,
                onTap: () => _addCustomTag(_search),
              ),
          ],
        ),
        if (folds)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton.icon(
              onPressed: () {
                Haptics.selectionClick();
                setState(() => _expanded = !_expanded);
              },
              style: TextButton.styleFrom(
                foregroundColor: context.cs.primary,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              icon: Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
              ),
              label: Text(
                _expanded
                    ? 'filter_tags_show_less'.tr()
                    : 'filter_tags_show_all'.tr(
                        namedArgs: {'count': '${tags.length}'},
                      ),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _hint(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
      ),
    );
  }
}

/// The search field above a tag grid, on the theme's input style. Shows a
/// spinner while [loading], otherwise a clear button once there is text.
class FilterSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool loading;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final ValueChanged<String>? onSubmitted;

  const FilterSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onClear,
    this.loading = false,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final Widget? suffix = loading
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: GlazeSpinner(strokeWidth: 2),
                ),
              )
            : value.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                color: context.cs.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
                onPressed: onClear,
              )
            : null;
        return TextField(
          controller: controller,
          style: TextStyle(fontSize: 15, color: context.cs.onSurface),
          textInputAction: onSubmitted != null
              ? TextInputAction.done
              : TextInputAction.search,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 20,
              color: context.cs.onSurfaceVariant,
            ),
            suffixIcon: suffix,
          ),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          onTapOutside: (_) => FocusScope.of(context).unfocus(),
        );
      },
    );
  }
}

/// One tag in a filter grid. [selected] chips are accent-filled and carry a
/// remove mark; [icon] leads a chip that does something other than toggle
/// (adding the typed query as a tag).
class FilterTagChip extends StatelessWidget {
  final String label;
  final bool selected;
  final IconData? icon;
  final VoidCallback onTap;

  const FilterTagChip({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final fg = selected ? cs.onSurface : cs.onSurfaceVariant;
    return Material(
      color: selected
          ? cs.primary.withValues(alpha: 0.22)
          : cs.onSurface.withValues(alpha: 0.05),
      shape: StadiumBorder(
        side: BorderSide(
          color: selected
              ? cs.primary.withValues(alpha: 0.7)
              : cs.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        onTap: () {
          Haptics.selectionClick();
          onTap();
        },
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            icon != null ? 8 : 12,
            6,
            selected ? 8 : 12,
            6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: cs.primary),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: fg, height: 1.2),
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 4),
                Icon(Icons.close_rounded, size: 14, color: fg),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
