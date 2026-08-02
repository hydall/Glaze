import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/preset_folder.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/filter_sheet.dart';
import '../preset_entry.dart';

/// Filter state for the Presets list: preset type (chat / Studio agent) and an
/// estimated-token range.
class PresetListFilters {
  static const int defaultMinTokens = 0;
  static const int defaultMaxTokens = 100000;

  /// Empty means "every type" — the same convention the tag filters use.
  final Set<PresetKind> kinds;
  final int minTokens;
  final int maxTokens;

  const PresetListFilters({
    this.kinds = const {},
    this.minTokens = defaultMinTokens,
    this.maxTokens = defaultMaxTokens,
  });

  bool get hasTokenFilter =>
      minTokens != defaultMinTokens || maxTokens != defaultMaxTokens;

  bool get isActive => kinds.isNotEmpty || hasTokenFilter;

  int get activeCount =>
      kinds.length +
      (minTokens != defaultMinTokens ? 1 : 0) +
      (maxTokens != defaultMaxTokens ? 1 : 0);

  bool matches(PresetItem entry) {
    if (kinds.isNotEmpty && !kinds.contains(entry.kind)) return false;
    // Reading `tokens` triggers the (lazy) count, so only touch it when a range
    // is actually set.
    if (hasTokenFilter &&
        (entry.tokens < minTokens || entry.tokens > maxTokens)) {
      return false;
    }
    return true;
  }

  PresetListFilters copyWith({
    Set<PresetKind>? kinds,
    int? minTokens,
    int? maxTokens,
  }) => PresetListFilters(
    kinds: kinds ?? this.kinds,
    minTokens: minTokens ?? this.minTokens,
    maxTokens: maxTokens ?? this.maxTokens,
  );
}

/// Reuses the shared [FilterSheet] to filter the Presets list. Mirrors
/// [CharacterFilterSheet]'s apply-on-dispose pattern.
class PresetFilterSheet extends StatefulWidget {
  final PresetListFilters filters;

  /// False when the Studio master switch is off — the list then only holds chat
  /// presets, so the type section is pointless.
  final bool showTypeFilter;
  final ValueChanged<PresetListFilters> onApply;

  const PresetFilterSheet({
    super.key,
    required this.filters,
    required this.onApply,
    this.showTypeFilter = true,
  });

  @override
  State<PresetFilterSheet> createState() => _PresetFilterSheetState();
}

class _PresetFilterSheetState extends State<PresetFilterSheet> {
  late Set<PresetKind> _kinds;
  late int _minTokens;
  late int _maxTokens;

  @override
  void initState() {
    super.initState();
    _kinds = Set.from(widget.filters.kinds);
    _minTokens = widget.filters.minTokens;
    _maxTokens = widget.filters.maxTokens;
  }

  @override
  void dispose() {
    final changed =
        _minTokens != widget.filters.minTokens ||
        _maxTokens != widget.filters.maxTokens ||
        _kinds.length != widget.filters.kinds.length ||
        !_kinds.containsAll(widget.filters.kinds);

    if (changed) {
      final apply = widget.onApply;
      final result = PresetListFilters(
        kinds: Set.from(_kinds),
        minTokens: _minTokens,
        maxTokens: _maxTokens,
      );
      Future.microtask(() => apply(result));
    }
    super.dispose();
  }

  void _toggleKind(PresetKind kind) {
    setState(() {
      if (!_kinds.remove(kind)) _kinds.add(kind);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FilterSheet(
      title: 'catalog_filters'.tr(),
      sections: [
        if (widget.showTypeFilter)
          FilterCustomSection(
            child: _TypeSection(selected: _kinds, onToggle: _toggleKind),
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
      ],
    );
  }
}

class _TypeSection extends StatelessWidget {
  final Set<PresetKind> selected;
  final ValueChanged<PresetKind> onToggle;

  const _TypeSection({required this.selected, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'preset_filter_type'.tr().toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: context.cs.onSurfaceVariant,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _chip(
              context,
              label: 'preset_type_normal'.tr(),
              icon: Icons.description_outlined,
              kind: PresetKind.normal,
            ),
            _chip(
              context,
              label: 'preset_type_agentic'.tr(),
              icon: Icons.smart_toy_outlined,
              kind: PresetKind.agentic,
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip(
    BuildContext context, {
    required String label,
    required IconData icon,
    required PresetKind kind,
  }) {
    final active = selected.contains(kind);
    return GestureDetector(
      onTap: () => onToggle(kind),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
            Icon(
              icon,
              size: 14,
              color: active
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.65),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: active
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.65),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
