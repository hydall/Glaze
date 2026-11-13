import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/models/preset.dart';
import '../../shared/widgets/filter_sheet.dart';

/// The script placements a filter can narrow the list to, in the order the
/// editor's "Affects" group lists them.
const List<int> regexFilterPlacements = [1, 2, 3, 5, 6];

String regexPlacementLabel(int placement) => switch (placement) {
  1 => 'regex_user_input'.tr(),
  2 => 'regex_ai_output'.tr(),
  3 => 'regex_slash_commands'.tr(),
  5 => 'regex_world_info'.tr(),
  6 => 'regex_reasoning'.tr(),
  _ => '$placement',
};

/// What the filter sheet narrows the regex list to. The scope (preset, global,
/// agent scripts) is not part of it — that is the control row's dropdown, so
/// the badge on the filter button only counts what is set here.
class RegexListFilters {
  final bool enabledOnly;
  final bool disabledOnly;

  /// Shows only scripts that affect at least one of these placements. Empty
  /// means every placement.
  final Set<int> placements;

  const RegexListFilters({
    this.enabledOnly = false,
    this.disabledOnly = false,
    this.placements = const {},
  });

  int get activeCount =>
      (enabledOnly ? 1 : 0) + (disabledOnly ? 1 : 0) + placements.length;

  bool get isActive => activeCount > 0;

  bool matches(PresetRegex script) {
    if (enabledOnly && script.disabled) return false;
    if (disabledOnly && !script.disabled) return false;
    if (placements.isNotEmpty && !script.placement.any(placements.contains)) {
      return false;
    }
    return true;
  }
}

/// The full id order after the row at [oldIndex] of [visible] was dragged to
/// [newIndex] (its final index, as `onReorderItem` reports it).
///
/// [visible] is what the user dragged over — one folder, or the rows a filter
/// left; [full] is the whole list. The moved row lands right after the visible
/// row it now follows, so rows hidden from view keep the places they had.
List<String> reanchorOrder(
  List<String> full,
  List<String> visible,
  int oldIndex,
  int newIndex,
) {
  if (oldIndex == newIndex) return full;
  final shown = List<String>.of(visible);
  final moved = shown.removeAt(oldIndex);
  shown.insert(newIndex, moved);
  final result = List<String>.of(full)..remove(moved);
  if (newIndex == 0) {
    // Lands before the row that now follows it.
    final next = shown.length > 1 ? shown[1] : null;
    final at = next == null ? 0 : result.indexOf(next);
    result.insert(at < 0 ? 0 : at, moved);
    return result;
  }
  final anchor = shown[newIndex - 1];
  result.insert(result.indexOf(anchor) + 1, moved);
  return result;
}

/// The scripts of [preset] filed in folder [folderId], in run order. A null
/// [folderId] gives the scripts at the top of the preset's list: those in no
/// folder, or in one the preset no longer declares.
List<PresetRegex> presetScriptsIn(Preset preset, String? folderId) {
  final declared = {for (final f in preset.regexFolders) f.id};
  return [
    for (final r in preset.regexes)
      if (folderId == null
          ? (r.folderId == null || !declared.contains(r.folderId))
          : r.folderId == folderId)
        r,
  ];
}

/// [preset] with the scripts [ids] filed in [folderId] (null = out of any
/// folder). Their place in the run order does not change.
Preset movePresetScripts(Preset preset, Set<String> ids, String? folderId) =>
    preset.copyWith(
      regexes: [
        for (final r in preset.regexes)
          ids.contains(r.id) ? r.copyWith(folderId: folderId) : r,
      ],
    );

/// [preset] without folder [folderId]; its scripts move to the top level.
Preset deletePresetRegexFolder(Preset preset, String folderId) =>
    preset.copyWith(
      regexFolders: [
        for (final f in preset.regexFolders)
          if (f.id != folderId) f,
      ],
      regexes: [
        for (final r in preset.regexes)
          r.folderId == folderId ? r.copyWith(folderId: null) : r,
      ],
    );

/// Filters for the regex list on the shared [FilterSheet], applied when the
/// sheet closes (the same pattern as the Presets list's filter sheet).
class RegexFilterSheet extends StatefulWidget {
  final RegexListFilters filters;
  final ValueChanged<RegexListFilters> onApply;

  const RegexFilterSheet({
    super.key,
    required this.filters,
    required this.onApply,
  });

  @override
  State<RegexFilterSheet> createState() => _RegexFilterSheetState();
}

class _RegexFilterSheetState extends State<RegexFilterSheet> {
  late bool _enabledOnly = widget.filters.enabledOnly;
  late bool _disabledOnly = widget.filters.disabledOnly;
  late Set<int> _placements = {...widget.filters.placements};

  @override
  void dispose() {
    final apply = widget.onApply;
    final result = RegexListFilters(
      enabledOnly: _enabledOnly,
      disabledOnly: _disabledOnly,
      placements: _placements,
    );
    Future.microtask(() => apply(result));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FilterSheet(
      title: 'catalog_filters'.tr(),
      fitContent: true,
      sections: [
        FilterGroupSection(
          title: 'regex_filter_status'.tr(),
          rows: [
            // The two are opposites: turning one on turns the other off.
            FilterToggleSection(
              label: 'regex_filter_enabled_only'.tr(),
              value: _enabledOnly,
              onChanged: (v) => setState(() {
                _enabledOnly = v;
                if (v) _disabledOnly = false;
              }),
            ),
            FilterToggleSection(
              label: 'regex_filter_disabled_only'.tr(),
              value: _disabledOnly,
              onChanged: (v) => setState(() {
                _disabledOnly = v;
                if (v) _enabledOnly = false;
              }),
            ),
          ],
        ),
        FilterGroupSection(
          title: 'regex_affects'.tr(),
          rows: [
            for (final placement in regexFilterPlacements)
              FilterToggleSection(
                label: regexPlacementLabel(placement),
                value: _placements.contains(placement),
                onChanged: (v) => setState(() {
                  _placements = {..._placements};
                  v
                      ? _placements.add(placement)
                      : _placements.remove(placement);
                }),
              ),
          ],
        ),
      ],
    );
  }
}
