import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/composer_pins_provider.dart';
import '../../settings/app_settings_provider.dart';
import '../guide_anchor.dart';
import '../guide_tour.dart';
import '../widgets/guide_widgets.dart';

String _pin(ComposerAction action) =>
    GuideIds.chatPin(ComposerPin.action(action).encode());

/// The chat screen: header, search, the gestures on messages (which live in
/// the WebView, so those steps are unlit), the composer and its button row,
/// and replies that keep generating in the background.
List<GuideTourStep> chatTourSteps() => [
  GuideTourStep.tr('guide_chat_header', target: GuideIds.chatHeader),
  GuideTourStep.tr(
    'guide_chat_search',
    target: GuideIds.chatSearch,
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_chat_swipes',
    content: const _SwipeRegenerationToggle(),
  ),
  GuideTourStep.tr(
    'guide_chat_messages',
    content: GuideTipList(
      tips: [
        GuideTip.tr(Icons.more_horiz_rounded, 'guide_chat_msg_menu'),
        GuideTip.tr(Icons.checklist_rounded, 'guide_chat_msg_select'),
        GuideTip.tr(Icons.refresh_rounded, 'guide_chat_msg_regen'),
      ],
    ),
  ),
  GuideTourStep.tr('guide_chat_composer', target: GuideIds.chatComposer),
  GuideTourStep.tr('guide_chat_send', target: GuideIds.chatSend),
  GuideTourStep.tr(
    'guide_chat_drawer',
    target: _pin(ComposerAction.drawer),
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_chat_guidance',
    target: _pin(ComposerAction.guidance),
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_chat_fullscreen',
    target: _pin(ComposerAction.fullscreen),
    optional: true,
  ),
  GuideTourStep.tr('guide_chat_background'),
];

/// The same switch as Settings → Chat → Swipe to regenerate.
class _SwipeRegenerationToggle extends ConsumerWidget {
  const _SwipeRegenerationToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings =
        ref.watch(appSettingsProvider).value ?? const AppSettings();
    return GuideSwitchRow(
      icon: Icons.swipe_left_rounded,
      title: 'menu_swipe_regeneration'.tr(),
      body: 'guide_chat_swipe_regen_body'.tr(),
      value: !settings.disableSwipeRegeneration,
      onChanged: (v) => ref
          .read(appSettingsProvider.notifier)
          .save(settings.copyWith(disableSwipeRegeneration: !v)),
    );
  }
}
