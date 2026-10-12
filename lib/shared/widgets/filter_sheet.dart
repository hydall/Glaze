import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:easy_localization/easy_localization.dart';
import '../theme/app_colors.dart';
import 'filter_tag_picker.dart';
import 'menu_group.dart';
import 'sheet_view.dart';

export 'filter_tag_picker.dart' show FilterTagChip, FilterSearchField;

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

/// A row that lives inside a card: a switch, a number or a range. Consecutive
/// rows outside a [FilterGroupSection] share one untitled card.
sealed class FilterRowSection extends FilterSection {
  const FilterRowSection();

  /// Whether the row narrows the results — drives the active count a
  /// collapsible group shows while closed.
  bool get isActive;
}

/// A single labelled on/off switch row.
class FilterToggleSection extends FilterRowSection {
  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool isDanger;

  const FilterToggleSection({
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
    this.isDanger = false,
  });

  @override
  bool get isActive => value;
}

/// A titled min/max integer range row with two numeric fields.
class FilterRangeSection extends FilterRowSection {
  final String title;
  final String minLabel;
  final String maxLabel;
  final int min;
  final int max;
  final ValueChanged<int> onMinChanged;
  final ValueChanged<int> onMaxChanged;

  /// The unfiltered bounds, used only to tell whether the range is in use.
  final int? defaultMin;
  final int? defaultMax;

  const FilterRangeSection({
    required this.title,
    required this.minLabel,
    required this.maxLabel,
    required this.min,
    required this.max,
    required this.onMinChanged,
    required this.onMaxChanged,
    this.defaultMin,
    this.defaultMax,
  });

  @override
  bool get isActive =>
      (defaultMin != null && min != defaultMin) ||
      (defaultMax != null && max != defaultMax);
}

/// A titled row with a single integer field.
class FilterNumberSection extends FilterRowSection {
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

  @override
  bool get isActive => value > 0;
}

/// A titled card of rows. [collapsible] folds it behind a disclosure header
/// that shows how many of its rows are in use; it opens by itself when any is.
class FilterGroupSection extends FilterSection {
  final String? title;
  final List<FilterRowSection> rows;
  final bool collapsible;

  const FilterGroupSection({
    this.title,
    required this.rows,
    this.collapsible = false,
  }) : assert(!collapsible || title != null, 'a collapsible group needs a title');
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

  /// Switches that change how the selection is applied (Chub's "match any
  /// tag"), rendered in the tags card above the picker.
  final List<FilterToggleSection> options;

  /// How many chips the grid shows before folding the rest behind a
  /// "show all" button.
  final int collapsedCount;

  /// Shown in place of the grid while [tags] is still being fetched.
  final bool loading;

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
    this.options = const [],
    this.collapsedCount = 24,
    this.loading = false,
  });
}

/// An arbitrary feature-specific widget rendered inline as a section. Use for
/// rows the descriptor types above can't express (e.g. the JanitorAI blocked
/// tags + keywords control with its own autocomplete). By default the child is
/// laid out inside the sheet's 16 px gutters; a child that brings its own
/// [MenuGroup] card passes `padded: false`.
class FilterCustomSection extends FilterSection {
  final Widget child;
  final bool padded;
  const FilterCustomSection({required this.child, this.padded = true});
}

/// Generic, reusable filter bottom sheet.
///
/// Renders an ordered list of [FilterSection]s inside a [SheetView], as
/// [MenuGroup] cards: switches, numbers and ranges are menu rows, tags get a
/// card of their own with a search field and a folded chip grid. Used by the
/// catalog, My Characters and preset filters; add new consumers by composing
/// the section descriptors above.
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
      bodyPadding: EdgeInsets.zero,
      // A fitted sheet gives its body unbounded height, so the list has to
      // shrink-wrap. Cards carry their own 16 px gutters and 12 px gap.
      body: Builder(
        builder: (context) {
          final insets = MediaQuery.paddingOf(context);
          return ListView(
            shrinkWrap: fitContent,
            padding: EdgeInsets.fromLTRB(
              0,
              insets.top + 8,
              0,
              insets.bottom + (fitContent ? 8 : 32),
            ),
            children: _buildSections(),
          );
        },
      ),
    );
  }

  List<Widget> _buildSections() {
    final out = <Widget>[];
    var pending = <FilterRowSection>[];

    void flushRows() {
      if (pending.isEmpty) return;
      out.add(_FilterGroup(group: FilterGroupSection(rows: pending)));
      pending = [];
    }

    for (final section in sections) {
      if (section is FilterRowSection) {
        pending.add(section);
        continue;
      }
      flushRows();
      out.add(switch (section) {
        FilterGroupSection() => _FilterGroup(group: section),
        FilterTagsSection() => FilterTagPicker(section: section),
        FilterCustomSection(padded: false) => section.child,
        FilterCustomSection() => Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: section.child,
        ),
        FilterRowSection() => throw StateError('rows are batched above'),
      });
    }
    flushRows();
    return out;
  }
}

class _FilterGroup extends StatelessWidget {
  final FilterGroupSection group;
  const _FilterGroup({required this.group});

  @override
  Widget build(BuildContext context) {
    final rows = [for (final r in group.rows) filterRow(r)];
    if (!group.collapsible) {
      return MenuGroup(
        header: group.title,
        headerVariant: MenuGroupHeaderVariant.accentCaps,
        items: rows,
      );
    }
    final active = group.rows.where((r) => r.isActive).length;
    return MenuCollapsibleSection(
      label: active > 0 ? '${group.title} · $active' : group.title!,
      initiallyExpanded: active > 0,
      children: [MenuGroup(items: rows)],
    );
  }
}

/// The menu row for one [FilterRowSection]. Shared with the tags card, which
/// renders its [FilterTagsSection.options] the same way.
Widget filterRow(FilterRowSection row) {
  return switch (row) {
    FilterToggleSection() => MenuSwitchItem(
      label: row.label,
      description: row.description,
      value: row.value,
      onChanged: row.onChanged,
      activeColor: row.isDanger ? _dangerColor : null,
    ),
    FilterNumberSection() => _NumberRow(section: row),
    FilterRangeSection() => _RangeRow(section: row),
  };
}

const _dangerColor = Color(0xFFFF5A5F);

const _rowLabelStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w400);

/// Label on the left, a compact number field on the right.
class _NumberRow extends StatelessWidget {
  final FilterNumberSection section;
  const _NumberRow({required this.section});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  section.title,
                  style: _rowLabelStyle.copyWith(
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                if (section.hint != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    section.hint!,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.cs.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 96,
            child: _NumberField(
              value: section.value,
              onChanged: section.onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

/// Label on its own line, then the two bounds side by side.
class _RangeRow extends StatelessWidget {
  final FilterRangeSection section;
  const _RangeRow({required this.section});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.title,
            style: _rowLabelStyle.copyWith(color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  value: section.min,
                  onChanged: section.onMinChanged,
                  prefix: section.minLabel,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '–',
                  style: TextStyle(
                    color: context.cs.onSurfaceVariant,
                    fontSize: 16,
                  ),
                ),
              ),
              Expanded(
                child: _NumberField(
                  value: section.max,
                  onChanged: section.onMaxChanged,
                  prefix: section.maxLabel,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// An integer field that commits on every edit, not only on submit: the sheet
/// applies its state when it closes, and a value typed without pressing Enter
/// used to be lost. Holds its own controller so a rebuild of the sheet does
/// not reset the caret or the text being typed.
class _NumberField extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;
  final String? prefix;

  const _NumberField({
    required this.value,
    required this.onChanged,
    this.prefix,
  });

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _controller = TextEditingController(text: '${widget.value}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    // Follow outside changes (a reset), but never fight the user's typing.
    if (!_focus.hasFocus && int.tryParse(_controller.text) != widget.value) {
      _controller.text = '${widget.value}';
    }
  }

  /// An emptied field snaps back to the committed value once it loses focus.
  void _onFocusChange() {
    if (!_focus.hasFocus && int.tryParse(_controller.text) == null) {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefix = widget.prefix;
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textAlign: prefix == null ? TextAlign.center : TextAlign.end,
      style: TextStyle(
        fontSize: 15,
        color: context.cs.onSurface,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        prefixIcon: prefix == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 12, right: 8),
                child: Text(
                  prefix,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ),
        prefixIconConstraints: const BoxConstraints(),
      ),
      onChanged: (v) {
        final parsed = int.tryParse(v);
        if (parsed != null) widget.onChanged(parsed);
      },
      onTapOutside: (_) => _focus.unfocus(),
    );
  }
}

/// The "Clear (n)" action in a card header.
class FilterClearButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const FilterClearButton({super.key, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: context.cs.primary,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      // Styled on the Text, not via `textStyle:` — that replaces the theme's
      // label style wholesale, font family included.
      child: Text(
        'catalog_clear_tags'.tr(namedArgs: {'count': '$count'}),
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}
