import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Onboarding slide data — the flow's content, shared by the phone layout and
// the desktop wizard.
// ---------------------------------------------------------------------------

enum OnboardingSlideType {
  welcome,
  features,
  dataImport,
  api,
  persona,
  layout,
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

const onboardingSlides = <OnboardingSlideData>[
  OnboardingSlideData(
    type: OnboardingSlideType.welcome,
    title: 'onboarding_welcome_title',
  ),
  OnboardingSlideData(
    type: OnboardingSlideType.features,
    title: 'onboarding_features_title',
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
    type: OnboardingSlideType.layout,
    title: 'onboarding_layout_title',
    desc: 'onboarding_layout_slide_desc',
    icon: Icons.view_quilt_outlined,
  ),
  OnboardingSlideData(
    type: OnboardingSlideType.allSet,
    title: 'onboarding_allset_title',
    desc: 'onboarding_allset_slide_desc',
    icon: Icons.check_circle_outline_rounded,
  ),
];

const onboardingIntroContent = <OnboardingInfoBlock>[
  OnboardingInfoBlock(
    icon: Icons.layers_outlined,
    title: 'onboarding_feature_roleplay_title',
    desc: 'onboarding_feature_roleplay_desc',
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
];

const onboardingFeaturesContent = <OnboardingInfoBlock>[
  OnboardingInfoBlock(
    icon: Icons.image_outlined,
    title: 'onboarding_feature_imggen_title',
    desc: 'onboarding_feature_imggen_desc',
  ),
  OnboardingInfoBlock(
    icon: Icons.menu_book_outlined,
    title: 'onboarding_feature_glossary_title',
    desc: 'onboarding_feature_glossary_desc',
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
