import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/list_controls.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../settings/app_settings_provider.dart';

/// The three "where does this come from" choices of the JanitorAI flow, as menu
/// rows: the closed lorebook, the catalog card, and the closed character
/// definition. Each is independently either the local Janitor.AI session or
/// DataCat's scraped copy.
///
/// Shared because both places that own these settings must offer exactly the
/// same choices: the Third-Party providers screen (JanitorAI group) and the
/// extraction settings sheet reachable from the lorebook capture flow.
List<Widget> janitorSourceMenuItems(
  BuildContext context,
  WidgetRef ref,
  AppSettings settings,
) {
  void save(AppSettings next) =>
      ref.read(appSettingsProvider.notifier).save(next);

  return [
    _sourceItem(
      context,
      label: 'janitor_source_lorebooks'.tr(),
      description: 'janitor_source_lorebooks_desc'.tr(),
      value: settings.janitorLorebookSource,
      // DataCat first: it needs no account, and it is the default.
      order: const [ExtractionSource.datacat, ExtractionSource.local],
      hints: {
        ExtractionSource.datacat: 'janitor_source_lorebooks_datacat_hint'.tr(),
        ExtractionSource.local: 'janitor_source_lorebooks_local_hint'.tr(),
      },
      onSelect: (v) => save(settings.copyWith(janitorLorebookSource: v)),
    ),
    _sourceItem(
      context,
      label: 'janitor_source_cards'.tr(),
      description: 'janitor_source_cards_desc'.tr(),
      value: settings.janitorCardSource,
      order: const [ExtractionSource.local, ExtractionSource.datacat],
      hints: {
        ExtractionSource.local: 'janitor_source_cards_local_hint'.tr(),
        ExtractionSource.datacat: 'janitor_source_cards_datacat_hint'.tr(),
      },
      onSelect: (v) => save(settings.copyWith(janitorCardSource: v)),
    ),
    _sourceItem(
      context,
      label: 'janitor_source_characters'.tr(),
      description: 'janitor_source_characters_desc'.tr(),
      value: settings.janitorCharacterSource,
      order: const [ExtractionSource.local, ExtractionSource.datacat],
      hints: {
        ExtractionSource.local: 'janitor_source_characters_local_hint'.tr(),
        ExtractionSource.datacat: 'janitor_source_characters_datacat_hint'.tr(),
      },
      onSelect: (v) => save(settings.copyWith(janitorCharacterSource: v)),
    ),
  ];
}

/// Display name of [source] — the same word in the collapsed row and in the
/// picker it opens.
String janitorSourceLabel(ExtractionSource source) => switch (source) {
  ExtractionSource.local => 'janitor_source_local'.tr(),
  ExtractionSource.datacat => 'janitor_source_datacat'.tr(),
};

IconData _sourceIcon(ExtractionSource source) => switch (source) {
  ExtractionSource.local => Icons.devices_rounded,
  ExtractionSource.datacat => Icons.pets_outlined,
};

Widget _sourceItem(
  BuildContext context, {
  required String label,
  required String description,
  required ExtractionSource value,
  required List<ExtractionSource> order,
  required Map<ExtractionSource, String> hints,
  required ValueChanged<ExtractionSource> onSelect,
}) {
  return MenuSelectorItem(
    label: label,
    description: description,
    currentValue: janitorSourceLabel(value),
    onTap: () => showGlazePickerSheet(
      context,
      title: label,
      items: [
        for (final s in order)
          GlazePickerItem(
            label: janitorSourceLabel(s),
            hint: hints[s],
            icon: _sourceIcon(s),
            isActive: s == value,
            value: s,
          ),
      ],
      onSelect: (v) => onSelect(v as ExtractionSource),
    ),
  );
}
