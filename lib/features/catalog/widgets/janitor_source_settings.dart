import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/list_controls.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../settings/app_settings_provider.dart';
import '../third_party_providers_provider.dart';
import 'provider_logo.dart';

/// The single "where does this come from" choice of the JanitorAI flow, as a
/// menu row: the catalog card, its closed definition and its closed lorebooks
/// all come from either the local Janitor.AI session or DataCat's scraped copy.
///
/// Shared because both places that own this setting must offer exactly the same
/// choice: the content providers screen (JanitorAI group) and the extraction
/// settings sheet reachable from the lorebook capture flow.
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
      label: 'janitor_source_label'.tr(),
      description: 'janitor_source_label_desc'.tr(),
      value: settings.janitorSource,
      // DataCat first: it needs no account, and it is the default.
      order: const [ExtractionSource.datacat, ExtractionSource.local],
      hints: {
        ExtractionSource.datacat: 'janitor_source_datacat_hint'.tr(),
        ExtractionSource.local: 'janitor_source_local_hint'.tr(),
      },
      onSelect: (v) => save(settings.copyWith(janitorSource: v)),
    ),
  ];
}

/// Display name of [source] — the same word in the collapsed row and in the
/// picker it opens.
String janitorSourceLabel(ExtractionSource source) => switch (source) {
  ExtractionSource.local => 'janitor_source_local'.tr(),
  ExtractionSource.datacat => 'janitor_source_datacat'.tr(),
};

IconData? _sourceIcon(ExtractionSource source) => switch (source) {
  ExtractionSource.local => Icons.devices_rounded,
  // DataCat carries its real logo, so it needs no material glyph.
  ExtractionSource.datacat => null,
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
            iconWidget: s == ExtractionSource.datacat
                ? ProviderLogo(provider: ThirdPartyProvider.datacat, size: 20)
                : null,
            isActive: s == value,
            value: s,
          ),
      ],
      onSelect: (v) => onSelect(v as ExtractionSource),
    ),
  );
}
