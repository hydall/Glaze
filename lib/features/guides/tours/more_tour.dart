import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_provider.dart';
import '../../settings/app_settings_provider.dart';
import '../guide_anchor.dart';
import '../guide_tour.dart';
import '../widgets/guide_widgets.dart';

/// The «More» tab: where the settings live, the search over them, the theme,
/// the reader's data, and help.
List<GuideTourStep> moreTourSteps() => [
  GuideTourStep.tr('guide_more_settings', target: GuideIds.moreSettings),
  GuideTourStep.tr(
    'guide_more_search',
    target: GuideIds.moreSearch,
    optional: true,
  ),
  GuideTourStep.tr('guide_more_theme', content: const _FollowSystemToggle()),
  GuideTourStep.tr('guide_more_data', target: GuideIds.moreData),
  GuideTourStep.tr(
    'guide_more_help',
    target: GuideIds.moreHelp,
    content: const _HelpTipsToggle(),
  ),
];

/// The same switch as Settings → Appearance → Follow the device theme.
class _FollowSystemToggle extends ConsumerWidget {
  const _FollowSystemToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final follow = ref.watch(themeProvider.select((t) => t.followSystem));
    return GuideSwitchRow(
      icon: Icons.brightness_auto_rounded,
      title: 'theme_follow_system'.tr(),
      body: 'desc_theme_follow_system'.tr(),
      value: follow,
      onChanged: (v) => ref.read(themeProvider.notifier).setFollowSystem(v),
    );
  }
}

class _HelpTipsToggle extends ConsumerWidget {
  const _HelpTipsToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings =
        ref.watch(appSettingsProvider).value ?? const AppSettings();
    return GuideSwitchRow(
      icon: Icons.help_outline_rounded,
      title: 'menu_show_help_tips'.tr(),
      body: 'guide_more_help_tips_body'.tr(),
      // Stored as "hide", shown as "show" — as on the settings screen.
      value: !settings.hideTooltips,
      onChanged: (v) => ref
          .read(appSettingsProvider.notifier)
          .save(settings.copyWith(hideTooltips: !v)),
    );
  }
}
