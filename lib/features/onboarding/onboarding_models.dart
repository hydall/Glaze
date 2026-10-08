import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Onboarding slide data — the flow's content, shared by the phone layout and
// the desktop wizard.
// ---------------------------------------------------------------------------

enum OnboardingSlideType {
  welcome,
  features,
  glossary,
  dataImport,
  api,
  persona,
  preset,
  layout,
  notifications,
  allSet,
}

class OnboardingSlideData {
  final OnboardingSlideType type;
  final String title;
  final String? desc;
  final IconData? icon;
  const OnboardingSlideData({
    required this.type,
    required this.title,
    this.desc,
    this.icon,
  });
}

class OnboardingInfoBlock {
  final IconData icon;
  final String title;
  final String desc;
  const OnboardingInfoBlock({
    required this.icon,
    required this.title,
    required this.desc,
  });
}

/// The flow, in order.
///
/// Computed rather than `const` because the notification slide only exists on
/// the platforms that put a permission dialog in front of the user. Asking for
/// it used to happen at startup, unannounced (see
/// `MessageNotificationPresenter.requestPermission`); it is a slide now so the
/// dialog arrives with its reason next to it and a way past it.
///
/// [includeNotifications] is passed in rather than read here — the caller owns
/// the platform question, and this file stays content.
List<OnboardingSlideData> buildOnboardingSlides({
  required bool includeNotifications,
}) => <OnboardingSlideData>[
  for (final slide in _allOnboardingSlides)
    if (slide.type != OnboardingSlideType.notifications || includeNotifications)
      slide,
];

const _allOnboardingSlides = <OnboardingSlideData>[
  OnboardingSlideData(
    type: OnboardingSlideType.welcome,
    title: 'onboarding_welcome_title',
    desc: 'onboarding_welcome_desc',
  ),
  OnboardingSlideData(
    type: OnboardingSlideType.features,
    title: 'onboarding_features_title',
  ),
  // Its own slide rather than a block on Features: as one line in that list
  // it went unread, and the questions it answers kept arriving at support.
  OnboardingSlideData(
    type: OnboardingSlideType.glossary,
    title: 'onboarding_feature_glossary_title',
    desc: 'onboarding_glossary_slide_desc',
    icon: Icons.menu_book_outlined,
  ),
  OnboardingSlideData(
    type: OnboardingSlideType.dataImport,
    title: 'onboarding_import_title',
    desc: 'onboarding_import_slide_desc',
    icon: Icons.download_rounded,
  ),
  OnboardingSlideData(
    type: OnboardingSlideType.api,
    title: 'onboarding_api_title',
    desc: 'onboarding_preset_slide_desc',
    icon: Icons.dns_outlined,
  ),
  OnboardingSlideData(
    type: OnboardingSlideType.persona,
    title: 'onboarding_persona_title',
    desc: 'onboarding_persona_slide_desc',
    icon: Icons.person_outline_rounded,
  ),
  OnboardingSlideData(
    type: OnboardingSlideType.preset,
    title: 'onboarding_slide_preset_title',
    desc: 'onboarding_slide_preset_desc',
    icon: Icons.tune_rounded,
  ),
  OnboardingSlideData(
    type: OnboardingSlideType.layout,
    title: 'onboarding_layout_title',
    desc: 'onboarding_layout_slide_desc',
    icon: Icons.view_quilt_outlined,
  ),
  OnboardingSlideData(
    type: OnboardingSlideType.notifications,
    title: 'onboarding_notifications_title',
    desc: 'onboarding_notifications_slide_desc',
    icon: Icons.notifications_active_outlined,
  ),
  OnboardingSlideData(
    type: OnboardingSlideType.allSet,
    title: 'onboarding_allset_title',
    desc: 'onboarding_allset_slide_desc',
    icon: Icons.check_circle_outline_rounded,
  ),
];

const onboardingFeaturesContent = <OnboardingInfoBlock>[
  OnboardingInfoBlock(
    icon: Icons.layers_outlined,
    title: 'onboarding_feature_friendly_title',
    desc: 'onboarding_feature_friendly_desc',
  ),
  OnboardingInfoBlock(
    icon: Icons.link_rounded,
    title: 'onboarding_feature_rules_title',
    desc: 'onboarding_feature_rules_desc',
  ),
  OnboardingInfoBlock(
    icon: Icons.verified_outlined,
    title: 'onboarding_feature_privacy_title',
    desc: 'onboarding_feature_privacy_desc',
  ),
  OnboardingInfoBlock(
    icon: Icons.travel_explore_rounded,
    title: 'onboarding_feature_catalog_title',
    desc: 'onboarding_feature_catalog_desc',
  ),
  OnboardingInfoBlock(
    icon: Icons.image_outlined,
    title: 'onboarding_feature_imggen_title',
    desc: 'onboarding_feature_imggen_desc',
  ),
  OnboardingInfoBlock(
    icon: Icons.palette_outlined,
    title: 'onboarding_feature_custom_title',
    desc: 'onboarding_feature_custom_desc',
  ),
  OnboardingInfoBlock(
    icon: Icons.description_outlined,
    title: 'onboarding_feature_st_title',
    desc: 'onboarding_feature_st_desc',
  ),
];
