import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import '../third_party_providers_provider.dart';
import 'catalog_filter_sheet.dart';
import 'third_party_providers_screen.dart';
import 'package:easy_localization/easy_localization.dart';

class CatalogControls extends ConsumerWidget {
  final CatalogState state;
  final CatalogNotifier notifier;

  const CatalogControls({
    super.key,
    required this.state,
    required this.notifier,
  });

  static String providerLabel(CatalogProvider p) => switch (p) {
    CatalogProvider.janitor => 'catalog_provider_janitor_label'.tr(),
    CatalogProvider.janny => 'catalog_provider_janny_label'.tr(),
    CatalogProvider.datacat => 'catalog_provider_datacat_label'.tr(),
    CatalogProvider.chub => 'catalog_provider_chub_label'.tr(),
  };

  static Map<String, String> sortOptionsForProvider(CatalogProvider p) =>
      switch (p) {
        CatalogProvider.janitor => {
          'trending': 'catalog_sort_janitor_trending'.tr(),
          'trending_24h': 'catalog_sort_janitor_trending24'.tr(),
          'popular': 'catalog_sort_janitor_popular'.tr(),
          'latest': 'catalog_sort_janitor_latest'.tr(),
        },
        CatalogProvider.janny => {
          'newest': 'catalog_sort_janny_newest'.tr(),
          'oldest': 'catalog_sort_janny_oldest'.tr(),
          'tokens_desc': 'catalog_sort_janny_tokens_desc'.tr(),
          'tokens_asc': 'catalog_sort_janny_tokens_asc'.tr(),
          'relevant': 'catalog_sort_janny_relevant'.tr(),
        },
        CatalogProvider.datacat => {
          'recent': 'catalog_sort_datacat_recent'.tr(),
          'fresh': 'catalog_sort_datacat_fresh'.tr(),
          'score_week': 'catalog_sort_datacat_score_week'.tr(),
          'score_24h': 'catalog_sort_datacat_score_24h'.tr(),
          'chat_count_week': 'catalog_sort_datacat_chat_count_week'.tr(),
          'chat_count_24h': 'catalog_sort_datacat_chat_count_24h'.tr(),
        },
        CatalogProvider.chub => {
          'popular': 'catalog_sort_chub_popular'.tr(),
          'trending_week': 'catalog_sort_chub_trending_week'.tr(),
          'trending_24h': 'catalog_sort_chub_trending_24h'.tr(),
          'latest': 'catalog_sort_chub_latest'.tr(),
          'rating': 'catalog_sort_chub_rating'.tr(),
          'updated': 'catalog_sort_chub_updated'.tr(),
        },
      };

  int _activeFilterCount() {
    final f = state.filters;
    int count = 0;
    if (f.nsfw) count++;
    // NSFL is a chub-only filter (its toggle is only shown for chub in the
    // filter sheet), so only count it for the current provider — otherwise a
    // leftover NSFL flag from chub would inflate the badge on janitor et al.
    if (state.activeProvider == CatalogProvider.chub && f.nsfl) count++;
    if (f.tagIds.isNotEmpty) count += f.tagIds.length;
    if (f.tagNames.isNotEmpty) count += f.tagNames.length;
    if (f.minTokens != 29) count++;
    if (f.maxTokens != 100000) count++;
    return count;
  }

  String _currentSortLabel() {
    final opts = sortOptionsForProvider(state.activeProvider);
    return opts[state.filters.sort] ?? state.filters.sort;
  }

  // Icon per sort-mode key, shared across providers since the same key
  // (e.g. 'latest', 'popular') always carries the same meaning.
  static const Map<String, IconData> _sortIcons = {
    'trending': Icons.trending_up_rounded,
    'trending_week': Icons.trending_up_rounded,
    'trending_24h': Icons.local_fire_department_rounded,
    'popular': Icons.star_rounded,
    'latest': Icons.schedule_rounded,
    'newest': Icons.schedule_rounded,
    'oldest': Icons.history_rounded,
    'tokens_desc': Icons.arrow_downward_rounded,
    'tokens_asc': Icons.arrow_upward_rounded,
    'relevant': Icons.auto_awesome_rounded,
    'recent': Icons.schedule_rounded,
    'fresh': Icons.new_releases_rounded,
    'score_week': Icons.star_rounded,
    'score_24h': Icons.local_fire_department_rounded,
    'chat_count_week': Icons.chat_bubble_rounded,
    'chat_count_24h': Icons.whatshot_rounded,
    'rating': Icons.thumb_up_rounded,
    'updated': Icons.update_rounded,
  };

  static IconData sortIconForKey(String key) =>
      _sortIcons[key] ?? Icons.sort_rounded;

  IconData _currentSortIcon() => sortIconForKey(state.filters.sort);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabledProviders = ref.watch(enabledCatalogProvidersProvider);
    return Row(
      children: [
        _LabeledChip(
          label: providerLabel(state.activeProvider),
          onTap: () => _showPickerSheet(
            context,
            title: 'blacklist_glossary_chip'.tr(),
            items: enabledProviders
                .map(
                  (p) => _PickerItem(
                    label: providerLabel(p),
                    isActive: p == state.activeProvider,
                    value: p,
                  ),
                )
                .toList(),
            onSelect: (v) => notifier.setProvider(v as CatalogProvider),
            headerAction: _SettingsGearButton(
              onTap: () {
                Navigator.of(context, rootNavigator: true).pop();
                openThirdPartyProvidersScreen(context);
              },
            ),
          ),
        ),
        const Spacer(),
        _FilterIconButton(
          count: _activeFilterCount(),
          onTap: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useRootNavigator: true,
            useSafeArea: true,
            backgroundColor: Colors.transparent,
            builder: (_) => CatalogFilterSheet(
              filters: state.filters,
              provider: state.activeProvider,
              onApply: (f) => notifier.setFilters(f),
              onBlockedTagsChanged: () => notifier.search(reset: true),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _SortIconChip(
          icon: _currentSortIcon(),
          tooltip: _currentSortLabel(),
          onTap: () => _showPickerSheet(
            context,
            title: 'sort_by'.tr(),
            items: sortOptionsForProvider(state.activeProvider).entries
                .map(
                  (e) => _PickerItem(
                    label: e.value,
                    isActive: e.key == state.filters.sort,
                    value: e.key,
                    icon: sortIconForKey(e.key),
                  ),
                )
                .toList(),
            onSelect: (v) => notifier.setSort(v as String),
          ),
        ),
      ],
    );
  }

  void _showPickerSheet(
    BuildContext context, {
    required String title,
    required List<_PickerItem> items,
    required ValueChanged<dynamic> onSelect,
    Widget? headerAction,
  }) {
    GlazeBottomSheet.show<void>(
      context,
      title: title,
      headerAction: headerAction,
      items: items
          .map(
            (item) => BottomSheetItem(
              icon: item.icon ?? (item.isActive ? Icons.check_rounded : null),
              iconColor: item.icon != null
                  ? (item.isActive
                        ? context.cs.primary
                        : context.cs.onSurfaceVariant)
                  : context.cs.primary,
              label: item.label,
              actions: item.icon != null && item.isActive
                  ? [
                      BottomSheetAction(
                        icon: Icons.check_rounded,
                        color: context.cs.primary,
                        onTap: () {
                          Navigator.of(context, rootNavigator: true).pop();
                          onSelect(item.value);
                        },
                      ),
                    ]
                  : const [],
              onTap: () {
                Navigator.of(context, rootNavigator: true).pop();
                onSelect(item.value);
              },
            ),
          )
          .toList(),
    );
  }
}

class _PickerItem {
  final String label;
  final bool isActive;
  final dynamic value;
  final IconData? icon;
  const _PickerItem({
    required this.label,
    required this.isActive,
    required this.value,
    this.icon,
  });
}

/// Gear button pinned to the provider-picker sheet header; opens the
/// Third-Party providers screen where sources can be enabled/disabled.
class _SettingsGearButton extends StatelessWidget {
  final VoidCallback onTap;

  const _SettingsGearButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(Icons.settings_outlined, size: 22, color: context.cs.primary),
      tooltip: 'third_party_providers_title'.tr(),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _LabeledChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _LabeledChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        height: 32,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          tint: context.cs.surface,
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.18)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.cs.primary,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: context.cs.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SortIconChip extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _SortIconChip({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          height: 32,
          child: GlassSurface(
            borderRadius: BorderRadius.circular(16),
            tint: context.cs.surface,
            border: Border.all(color: context.cs.primary.withValues(alpha: 0.18)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: context.cs.primary),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: context.cs.primary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterIconButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _FilterIconButton({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            GlassSurface(
              borderRadius: BorderRadius.circular(16),
              tint: context.cs.surface,
              border: Border.all(color: context.cs.primary.withValues(alpha: 0.18)),
              child: Center(
                child: Icon(
                  Icons.filter_list_rounded,
                  size: 18,
                  color: context.cs.primary,
                ),
              ),
            ),
            if (count > 0)
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: context.cs.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
