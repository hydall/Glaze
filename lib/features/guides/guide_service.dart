import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/onboarding_service.dart' show isOnboardingComplete;
import '../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../shared/widgets/glaze_toast.dart';
import 'guide_tour.dart';
import 'tours/characters_tour.dart';
import 'tours/chat_tour.dart';
import 'tours/more_tour.dart';
import 'tours/tabs_tour.dart';
import 'tours/tools_tour.dart';

/// The in-app guides: spotlight tours over the real screen, each shown once,
/// the first time its part of the app opens, and replayable from
/// More → Guides.
enum AppGuide {
  /// The four main tabs. Walks the phone navbar, so it is not offered in the
  /// desktop layout.
  tabs('guide_tabs_shown', mobileOnly: true),
  chat('guide_chat_shown'),
  characters('guide_characters_shown'),
  tools('guide_tools_shown'),
  more('guide_more_shown');

  const AppGuide(this.shownKey, {this.mobileOnly = false});

  /// Persisted flag: the guide has been shown and never appears on its own
  /// again.
  final String shownKey;
  final bool mobileOnly;

  List<GuideTourStep> get steps => switch (this) {
    AppGuide.tabs => tabsTourSteps(),
    AppGuide.chat => chatTourSteps(),
    AppGuide.characters => charactersTourSteps(),
    AppGuide.tools => toolsTourSteps(),
    AppGuide.more => moreTourSteps(),
  };
}

/// Guides whose check already ran this session, so a screen that rebuilds or
/// re-opens never re-reads the flag.
final Set<AppGuide> _checked = {};

/// Whether a tour is running. A second trigger meanwhile backs off without
/// marking its guide seen, and gets another chance later.
bool _guideOpen = false;

/// Shows [guide] if it has never been shown. Waits out the first-run
/// onboarding — a tour over it would point at screens the reader has not
/// reached yet — and marks the guide seen up front, so a skipped or
/// half-finished tour never reappears.
Future<void> maybeShowGuide(BuildContext context, AppGuide guide) async {
  if (_checked.contains(guide) || _guideOpen) return;
  _checked.add(guide);
  if (guide.mobileOnly && isDesktopLayout(context)) return;

  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(guide.shownKey) ?? false) return;
  if (_guideOpen || !await isOnboardingComplete(prefs) || !context.mounted) {
    _checked.remove(guide);
    return;
  }
  await prefs.setBool(guide.shownKey, true);
  if (!context.mounted) return;
  await showGuide(context, guide);
}

/// Forgets this session's checks, so a test can trigger a guide again.
@visibleForTesting
void resetGuideSession() {
  _checked.clear();
  _guideOpen = false;
}

/// Runs [guide]'s tour over whatever is on screen, whether or not it was seen.
Future<void> showGuide(BuildContext context, AppGuide guide) async {
  _guideOpen = true;
  try {
    await showGuideTour(context, guide.steps);
  } finally {
    _guideOpen = false;
  }
}

/// Replays [guide] from the guides list, which lives on the More tab: a tour
/// of another tab switches to it first. The chat has no single screen to
/// switch to, so its tour is re-armed for the next chat the reader opens.
Future<void> replayGuide(BuildContext context, AppGuide guide) async {
  switch (guide) {
    case AppGuide.chat:
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(guide.shownKey);
      _checked.remove(guide);
      if (context.mounted) GlazeToast.show(context, 'guides_chat_armed'.tr());
    case AppGuide.characters:
      context.go('/characters');
      await showGuide(context, guide);
    case AppGuide.tools:
      context.go('/tools');
      await showGuide(context, guide);
    case AppGuide.tabs:
    case AppGuide.more:
      await showGuide(context, guide);
  }
}
