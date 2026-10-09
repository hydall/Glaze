import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../catalog/widgets/catalog_onboarding_sheet.dart';
import '../../menu/menu_actions.dart' show replayOnboarding;
import '../guide_service.dart';

/// More → Help → Replay onboarding: the first-run setup and every in-app
/// guide, replayable on demand. The catalog explainer is listed with the
/// guides, in the order the tabs come.
Future<void> showGuidesList(BuildContext context) {
  void open(Future<void> Function(BuildContext) show) {
    Navigator.of(context, rootNavigator: true).pop();
    show(context);
  }

  BottomSheetItem guide(AppGuide guide, IconData icon, String key) =>
      BottomSheetItem(
        label: key.tr(),
        hint: '${key}_hint'.tr(),
        icon: icon,
        onTap: () => open((c) => replayGuide(c, guide)),
      );

  return GlazeBottomSheet.show<void>(
    context,
    title: 'guides_title'.tr(),
    items: [
      BottomSheetItem(
        label: 'guides_setup'.tr(),
        hint: 'guides_setup_hint'.tr(),
        icon: Icons.replay_rounded,
        onTap: () => open(replayOnboarding),
      ),
      if (!isDesktopLayout(context))
        guide(AppGuide.tabs, Icons.explore_rounded, 'guides_tabs'),
      guide(AppGuide.chat, Icons.forum_rounded, 'guides_chat'),
      guide(AppGuide.characters, Icons.people_alt_rounded, 'guides_characters'),
      BottomSheetItem(
        label: 'catalog_onboarding_replay'.tr(),
        hint: 'catalog_onboarding_replay_hint'.tr(),
        icon: Icons.travel_explore_rounded,
        onTap: () => open(replayCatalogOnboarding),
      ),
      guide(AppGuide.tools, Icons.handyman_rounded, 'guides_tools'),
      guide(AppGuide.api, Icons.cloud_rounded, 'guides_api'),
      guide(AppGuide.presets, Icons.tune_rounded, 'guides_presets'),
      guide(AppGuide.personas, Icons.person_rounded, 'guides_personas'),
      guide(AppGuide.more, Icons.settings_rounded, 'guides_more'),
    ],
  );
}
