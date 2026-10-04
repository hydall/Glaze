import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/filter_sheet.dart';
import '../preset_entry.dart';

/// Filter state for the Presets list: an estimated-token range.
///
/// Preset type (chat / Studio agent) is *not* part of this — it is picked from
/// the dropdown in the list's control row, so the sheet (and the badge on the
/// button that opens it) only covers the ranges set here.
class PresetListFilters {
  static const int defaultMinTokens = 0;
  static const int defaultMaxTokens = 100000;

  final int minTokens;
  final int maxTokens;

  const PresetListFilters({
    this.minTokens = defaultMinTokens,
    this.maxTokens = defaultMaxTokens,
  });

  bool get hasTokenFilter =>
      minTokens != defaultMinTokens || maxTokens != defaultMaxTokens;

  bool get isActive => hasTokenFilter;

  int get activeCount =>
      (minTokens != defaultMinTokens ? 1 : 0) +
      (maxTokens != defaultMaxTokens ? 1 : 0);

  bool matches(PresetItem entry) {
    // Reading `tokens` triggers the (lazy) count, so only touch it when a range
    // is actually set.
    if (hasTokenFilter &&
        (entry.tokens < minTokens || entry.tokens > maxTokens)) {
      return false;
    }
    return true;
  }

  PresetListFilters copyWith({int? minTokens, int? maxTokens}) =>
      PresetListFilters(
        minTokens: minTokens ?? this.minTokens,
        maxTokens: maxTokens ?? this.maxTokens,
      );
}

/// Reuses the shared [FilterSheet] to filter the Presets list. Mirrors
/// [CharacterFilterSheet]'s apply-on-dispose pattern.
class PresetFilterSheet extends StatefulWidget {
  final PresetListFilters filters;
  final ValueChanged<PresetListFilters> onApply;

  const PresetFilterSheet({
    super.key,
    required this.filters,
    required this.onApply,
  });

  @override
  State<PresetFilterSheet> createState() => _PresetFilterSheetState();
}

class _PresetFilterSheetState extends State<PresetFilterSheet> {
  late int _minTokens;
  late int _maxTokens;

  @override
  void initState() {
    super.initState();
    _minTokens = widget.filters.minTokens;
    _maxTokens = widget.filters.maxTokens;
  }

  @override
  void dispose() {
    final changed =
        _minTokens != widget.filters.minTokens ||
        _maxTokens != widget.filters.maxTokens;

    if (changed) {
      final apply = widget.onApply;
      final result = PresetListFilters(
        minTokens: _minTokens,
        maxTokens: _maxTokens,
      );
      Future.microtask(() => apply(result));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FilterSheet(
      title: 'catalog_filters'.tr(),
      // One range row — the sheet only needs the height that row occupies.
      fitContent: true,
      sections: [
        FilterRangeSection(
          title: 'catalog_token_range'.tr(),
          minLabel: 'catalog_min'.tr(),
          maxLabel: 'catalog_max'.tr(),
          min: _minTokens,
          max: _maxTokens,
          onMinChanged: (v) => setState(() => _minTokens = v),
          onMaxChanged: (v) => setState(() => _maxTokens = v),
        ),
      ],
    );
  }
}
