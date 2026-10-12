import 'package:flutter/material.dart';

import '../guide_anchor.dart';
import '../guide_tour.dart';
import '../widgets/guide_widgets.dart';

// The screens behind the Tools tab's API, Presets and Personas tiles — the
// setup the first-run onboarding used to ask for. Each tour runs over the real
// screen, whether it was opened from Tools or as a sheet over a chat, and its
// steps follow what the screen shows: an empty API list has only its Add
// button, a filled one the connection form.

/// API settings: add a connection, switch between them, fill in the form.
List<GuideTourStep> apiTourSteps() => [
  GuideTourStep.tr('guide_api_add', target: GuideIds.apiAdd, optional: true),
  GuideTourStep.tr(
    'guide_api_switcher',
    target: GuideIds.apiSwitcher,
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_api_connection',
    target: GuideIds.apiConnection,
    optional: true,
    content: GuideTipList(
      tips: [
        GuideTip.tr(Icons.hub_outlined, 'guide_api_protocol'),
        GuideTip.tr(Icons.key_rounded, 'guide_api_key'),
        GuideTip.tr(Icons.list_rounded, 'guide_api_model'),
      ],
    ),
  ),
  GuideTourStep.tr('guide_api_tabs', target: GuideIds.apiTabs, optional: true),
  GuideTourStep.tr('guide_api_rest'),
];

/// The preset list: the built-in presets are already in it.
List<GuideTourStep> presetsTourSteps() => [
  GuideTourStep.tr(
    'guide_presets_row',
    target: GuideIds.presetsRow,
    optional: true,
    content: GuideTipList(
      tips: [
        GuideTip.tr(Icons.edit_outlined, 'guide_presets_edit'),
        GuideTip.tr(Icons.link_rounded, 'guide_presets_link'),
      ],
    ),
  ),
  GuideTourStep.tr(
    'guide_presets_controls',
    target: GuideIds.presetsControls,
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_presets_add',
    target: GuideIds.presetsAdd,
    optional: true,
  ),
];

/// The persona list: create one, make it active, bind it.
List<GuideTourStep> personasTourSteps() => [
  GuideTourStep.tr(
    'guide_personas_add',
    target: GuideIds.personasAdd,
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_personas_row',
    target: GuideIds.personasRow,
    optional: true,
    content: GuideTipList(
      tips: [
        GuideTip.tr(Icons.link_rounded, 'guide_personas_link'),
        GuideTip.tr(Icons.more_horiz_rounded, 'guide_personas_more'),
      ],
    ),
  ),
  GuideTourStep.tr(
    'guide_personas_folder',
    target: GuideIds.personasFolder,
    optional: true,
  ),
];
