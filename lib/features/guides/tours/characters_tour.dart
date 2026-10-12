import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/app_settings_provider.dart';
import '../guide_anchor.dart';
import '../guide_tour.dart';
import '../widgets/guide_widgets.dart';

/// The Characters tab, top to bottom. The catalog has its own explainer,
/// shown on the first visit to «Discover», so this tour only points at it.
///
/// Most steps are optional: an empty library has no random button, filter
/// row or card to point at, and those steps simply drop out.
List<GuideTourStep> charactersTourSteps() => [
  GuideTourStep.tr(
    'guide_chars_tabs',
    target: GuideIds.charsTabs,
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_chars_search',
    target: GuideIds.charsSearch,
    optional: true,
  ),
  GuideTourStep.tr('guide_chars_add', target: GuideIds.charsAdd),
  GuideTourStep.tr(
    'guide_chars_folders',
    target: GuideIds.charsFolders,
    optional: true,
    content: const _OurPicksToggle(),
  ),
  GuideTourStep.tr(
    'guide_chars_random',
    target: GuideIds.charsRandom,
    optional: true,
    content: const _StandardRandomizerToggle(),
  ),
  GuideTourStep.tr(
    'guide_chars_filter',
    target: GuideIds.charsFilter,
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_chars_card',
    target: GuideIds.charsCard,
    optional: true,
  ),
];

class _OurPicksToggle extends ConsumerWidget {
  const _OurPicksToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings =
        ref.watch(appSettingsProvider).value ?? const AppSettings();
    return GuideSwitchRow(
      icon: Icons.star_rounded,
      title: 'menu_show_our_picks'.tr(),
      body: 'guide_chars_picks_body'.tr(),
      value: settings.showOurPicks,
      onChanged: (v) => ref
          .read(appSettingsProvider.notifier)
          .save(settings.copyWith(showOurPicks: v)),
    );
  }
}

class _StandardRandomizerToggle extends ConsumerWidget {
  const _StandardRandomizerToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings =
        ref.watch(appSettingsProvider).value ?? const AppSettings();
    return GuideSwitchRow(
      icon: Icons.casino_rounded,
      title: 'menu_use_standard_randomizer'.tr(),
      body: 'guide_chars_standard_random_body'.tr(),
      value: settings.useStandardRandomizer,
      onChanged: (v) => ref
          .read(appSettingsProvider.notifier)
          .save(settings.copyWith(useStandardRandomizer: v)),
    );
  }
}
