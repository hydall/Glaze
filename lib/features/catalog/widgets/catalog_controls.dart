import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/list_controls.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import '../third_party_providers_provider.dart';
import 'catalog_filter_sheet.dart';
import 'provider_logo.dart';
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
        // The five sort fields the Client API accepts. The time window used
        // to be baked into these labels (`score_week`); it is its own chip
        // now, so every field can be combined with every window instead of
        // only the four pairings the old list happened to name.
        CatalogProvider.datacat => {
          'fresh': 'catalog_sort_datacat_fresh'.tr(),
          'score': 'catalog_sort_datacat_score'.tr(),
          'chat_count': 'catalog_sort_datacat_chat_count'.tr(),
          'messages_per_chat': 'catalog_sort_datacat_messages_per_chat'.tr(),
          'first_published': 'catalog_sort_datacat_first_published'.tr(),
        },
        CatalogProvider.chub => {
          'timeline': 'catalog_sort_chub_timeline'.tr(),
          'popular': 'catalog_sort_chub_popular'.tr(),
          'trending_week': 'catalog_sort_chub_trending_week'.tr(),
          'trending_24h': 'catalog_sort_chub_trending_24h'.tr(),
          'latest': 'catalog_sort_chub_latest'.tr(),
          'rating': 'catalog_sort_chub_rating'.tr(),
          'updated': 'catalog_sort_chub_updated'.tr(),
        },
      };

  /// Labels for the DataCat time-window chip.
  static Map<String, String> get windowOptions => {
    'all': 'catalog_window_all'.tr(),
    'week': 'catalog_window_week'.tr(),
    '24h': 'catalog_window_24h'.tr(),
  };

  static const Map<String, IconData> _windowIcons = {
    'all': Icons.all_inclusive_rounded,
    'week': Icons.date_range_rounded,
    '24h': Icons.local_fire_department_rounded,
  };

  /// Whether this provider can express a time window. Only DataCat can: every
  /// other source folds the window into its sort key.
  static bool supportsWindow(CatalogProvider p) => p == CatalogProvider.datacat;

  /// Whether this provider can filter by token count. DataCat's API takes no
  /// token bounds, so the slider is hidden there rather than quietly ignored.
  static bool supportsTokenRange(CatalogProvider p) =>
      p != CatalogProvider.datacat;

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
    // Only counted where the filter exists — a leftover token range from
    // another provider must not badge a provider that cannot apply it.
    if (supportsTokenRange(state.activeProvider)) {
      if (f.minTokens != 29) count++;
      if (f.maxTokens != 100000) count++;
    }
    // The Chub-only refinements share the same rule as NSFL: they only apply to
    // chub, so they only count toward chub's badge.
    if (state.activeProvider == CatalogProvider.chub) {
      if (f.nsfwOnly) count++;
      if (f.requireImages) count++;
      if (f.requireLore) count++;
      if (f.requireCustomPrompt) count++;
      if (f.requireExampleDialogues) count++;
      if (f.requireAlternateGreetings) count++;
      if (f.recommendedVerified) count++;
      if (f.excludeMine) count++;
      if (f.inclusiveOr) count++;
      if (f.minAiRating > 0) count++;
      if (f.minTags > 0) count++;
    }
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
    'fresh': Icons.new_releases_rounded,
    'score': Icons.star_rounded,
    'chat_count': Icons.chat_bubble_rounded,
    'messages_per_chat': Icons.forum_rounded,
    'first_published': Icons.event_available_rounded,
    'rating': Icons.thumb_up_rounded,
    'updated': Icons.update_rounded,
    'timeline': Icons.timeline_rounded,
  };

  static IconData sortIconForKey(String key) =>
      _sortIcons[key] ?? Icons.sort_rounded;

  IconData _currentSortIcon() => sortIconForKey(state.filters.sort);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabledProviders = ref.watch(enabledCatalogProvidersProvider);
    final row = Row(
      children: [
        GlazeDropdownChip(
          label: providerLabel(state.activeProvider),
          leading: ProviderLogo.catalog(provider: state.activeProvider),
          onTap: () => showGlazePickerSheet(
            context,
            title: 'blacklist_glossary_chip'.tr(),
            items: enabledProviders
                .map(
                  (p) => GlazePickerItem(
                    label: providerLabel(p),
                    isActive: p == state.activeProvider,
                    value: p,
                    iconWidget: ProviderLogo.catalog(provider: p, size: 20),
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
        GlazeFilterIconButton(
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
              timelineMode: state.chubTimelineActive,
              onApply: (f) => notifier.setFilters(f),
              onBlockedTagsChanged: () => notifier.search(reset: true),
            ),
          ),
        ),
        if (supportsWindow(state.activeProvider)) ...[
          const SizedBox(width: 8),
          GlazeActionChip(
            icon: _windowIcons[state.filters.window] ??
                Icons.all_inclusive_rounded,
            label: windowOptions[state.filters.window],
            tooltip: 'catalog_window_title'.tr(),
            onTap: () => showGlazePickerSheet(
              context,
              title: 'catalog_window_title'.tr(),
              items: windowOptions.entries
                  .map(
                    (e) => GlazePickerItem(
                      label: e.value,
                      isActive: e.key == state.filters.window,
                      value: e.key,
                      icon: _windowIcons[e.key],
                    ),
                  )
                  .toList(),
              onSelect: (v) => notifier.setWindow(v as String),
            ),
          ),
        ],
        const SizedBox(width: 8),
        GlazeSortIconChip(
          icon: _currentSortIcon(),
          tooltip: _currentSortLabel(),
          onTap: () => showGlazePickerSheet(
            context,
            title: 'sort_by'.tr(),
            items: sortOptionsForProvider(state.activeProvider).entries
                .map(
                  (e) => GlazePickerItem(
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

    // One backdrop capture for the row instead of one per chip: these are
    // plain siblings that never overlap. See [GlassBackdropGroup].
    return GlassBackdropGroup(child: row);
  }
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
