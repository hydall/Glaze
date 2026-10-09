import 'package:flutter/material.dart';

import '../guide_anchor.dart';
import '../guide_tour.dart';
import '../widgets/guide_widgets.dart';

/// The four main tabs, walked along the navbar, then the header search and
/// the three steps to a first chat. Each tab has its own tour for the details.
List<GuideTourStep> tabsTourSteps() => [
  GuideTourStep.tr('guide_tabs_nav', target: GuideIds.navBar),
  GuideTourStep.tr('guide_tabs_chats', target: GuideIds.navTab(0)),
  GuideTourStep.tr('guide_tabs_characters', target: GuideIds.navTab(1)),
  GuideTourStep.tr('guide_tabs_tools', target: GuideIds.navTab(2)),
  GuideTourStep.tr('guide_tabs_more', target: GuideIds.navTab(3)),
  GuideTourStep.tr(
    'guide_tabs_search',
    target: GuideIds.chatsSearch,
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_tabs_start',
    content: GuideTipList(
      tips: [
        GuideTip.tr(Icons.build_rounded, 'guide_tabs_start_api'),
        GuideTip.tr(Icons.person_add_rounded, 'guide_tabs_start_char'),
        GuideTip.tr(Icons.forum_rounded, 'guide_tabs_start_chat'),
      ],
    ),
  ),
];
