import 'package:flutter/material.dart';

import '../guide_anchor.dart';
import '../guide_tour.dart';
import '../widgets/guide_widgets.dart';
import 'characters_tour.dart';
import 'tools_tour.dart';

/// The desktop layout in one tour. On a phone the tabs, Characters and Tools
/// are three screens with a tour each; on a computer they share one window —
/// chats on the left, Characters in the middle, Tools on the right — so they
/// are walked together, left to right, ending on where to start.
List<GuideTourStep> desktopTourSteps() => [
  GuideTourStep.tr('guide_desktop_layout'),
  GuideTourStep.tr('guide_desktop_chats', target: GuideIds.desktopChats),
  GuideTourStep.tr(
    'guide_desktop_search',
    target: GuideIds.chatsSearch,
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_desktop_characters',
    target: GuideIds.desktopCharacters,
  ),
  ...charactersTourSteps(),
  GuideTourStep.tr('guide_desktop_tools', target: GuideIds.desktopTools),
  ...toolsTourSteps(editOptional: true),
  GuideTourStep.tr('guide_desktop_glossary', target: GuideIds.desktopGlossary),
  GuideTourStep.tr('guide_desktop_more', target: GuideIds.desktopMore),
  GuideTourStep.tr(
    'guide_desktop_start',
    content: GuideTipList(
      tips: [
        GuideTip.tr(Icons.cloud_rounded, 'guide_desktop_start_api'),
        GuideTip.tr(Icons.person_add_rounded, 'guide_tabs_start_char'),
        GuideTip.tr(Icons.forum_rounded, 'guide_desktop_start_chat'),
      ],
    ),
  ),
];
