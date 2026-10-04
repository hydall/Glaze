import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../catalog_models.dart';
import '../../services/datacat/datacat_sort.dart';

/// The time windows DataCat can scope a listing to, in picker order.
const datacatWindows = <String>['all', 'week', '24h'];

/// Labels for the DataCat sort fields, in the order the picker shows them.
Map<String, String> datacatSortOptions() => {
  'fresh': 'catalog_sort_datacat_fresh'.tr(),
  'score': 'catalog_sort_datacat_score'.tr(),
  'chat_count': 'catalog_sort_datacat_chat_count'.tr(),
  'messages_per_chat': 'catalog_sort_datacat_messages_per_chat'.tr(),
  'first_published': 'catalog_sort_datacat_first_published'.tr(),
};

const _sortIcons = <String, IconData>{
  'fresh': Icons.new_releases_rounded,
  'score': Icons.star_rounded,
  'chat_count': Icons.chat_bubble_rounded,
  'messages_per_chat': Icons.forum_rounded,
  'first_published': Icons.event_available_rounded,
};

IconData datacatSortIconFor(String field) =>
    _sortIcons[field] ?? Icons.sort_rounded;

/// Labels for the DataCat time-window chip and picker.
Map<String, String> datacatWindowOptions() => {
  'all': 'catalog_window_all'.tr(),
  'week': 'catalog_window_week'.tr(),
  '24h': 'catalog_window_24h'.tr(),
};

const _windowIcons = <String, IconData>{
  'all': Icons.all_inclusive_rounded,
  'week': Icons.date_range_rounded,
  '24h': Icons.local_fire_department_rounded,
};

IconData datacatWindowIconFor(String window) =>
    _windowIcons[window] ?? Icons.all_inclusive_rounded;

/// Opens DataCat's listing order picker: the sort field and the time window in
/// a single sheet, since the API takes them as one listing order and the user
/// reads them as one choice. Picking any row applies it and closes the sheet.
Future<void> showDatacatSortSheet(
  BuildContext context, {
  required CatalogFilters filters,
  required ValueChanged<String> onSort,
  required ValueChanged<String> onWindow,
}) {
  void select(VoidCallback apply) {
    Navigator.of(context, rootNavigator: true).pop();
    apply();
  }

  return GlazeBottomSheet.show<void>(
    context,
    title: 'catalog_sort_window_title'.tr(),
    items: [
      for (final field in datacatSortFields)
        BottomSheetItem(
          section: 'sort_by'.tr(),
          icon: datacatSortIconFor(field),
          iconColor: field == filters.sort
              ? context.cs.primary
              : context.cs.onSurfaceVariant,
          label: datacatSortOptions()[field] ?? field,
          actions: field == filters.sort
              ? [
                  BottomSheetAction(
                    icon: Icons.check_rounded,
                    color: context.cs.primary,
                    onTap: () => select(() => onSort(field)),
                  ),
                ]
              : const [],
          onTap: () => select(() => onSort(field)),
        ),
      for (final window in datacatWindows)
        BottomSheetItem(
          section: 'catalog_window_title'.tr(),
          icon: datacatWindowIconFor(window),
          iconColor: window == filters.window
              ? context.cs.primary
              : context.cs.onSurfaceVariant,
          label: datacatWindowOptions()[window] ?? window,
          actions: window == filters.window
              ? [
                  BottomSheetAction(
                    icon: Icons.check_rounded,
                    color: context.cs.primary,
                    onTap: () => select(() => onWindow(window)),
                  ),
                ]
              : const [],
          onTap: () => select(() => onWindow(window)),
        ),
    ],
  );
}
