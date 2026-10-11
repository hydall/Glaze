import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/onboarding_service.dart' show isOnboardingComplete;
import '../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../shared/widgets/glaze_toast.dart';
import 'guide_tour.dart';
import 'tours/characters_tour.dart';
import 'tours/chat_tour.dart';
import 'tours/desktop_tour.dart';
import 'tours/more_tour.dart';
import 'tours/setup_tours.dart';
import 'tours/tabs_tour.dart';
import 'tours/tools_tour.dart';

/// The in-app guides: spotlight tours over the real screen, each shown once,
/// the first time its part of the app opens, and replayable from
/// More → Guides.
enum AppGuide {
  /// The four main tabs. Walks the phone navbar.
  tabs('guide_tabs_shown'),
  chat('guide_chat_shown'),
  characters('guide_characters_shown'),
  tools('guide_tools_shown'),
  more('guide_more_shown'),

  /// The screens behind the API, Presets and Personas tiles. Each runs the
  /// first time its screen opens, from Tools or as a sheet over a chat.
  api('guide_api_shown', route: '/tools/api'),
  presets('guide_presets_shown', route: '/tools/presets'),
  personas('guide_personas_shown', route: '/tools/personas'),

  /// The desktop layout in one pass: the left sidebar, the Characters column
  /// and the Tools sidebar. On a computer all three are on screen at once, so
  /// it stands in for [tabs], [characters] and [tools] there.
  desktop('guide_desktop_shown');

  const AppGuide(this.shownKey, {this.route});

  /// Persisted flag: the guide has been shown and never appears on its own
  /// again.
  final String shownKey;

  /// The Tools sub-route the guide's screen lives on, for a replay to open.
  final String? route;

  /// The guide that covers this one in the given layout: on desktop the tabs,
  /// characters and tools tours fold into [desktop], and [desktop] has no
  /// phone counterpart (null).
  AppGuide? forLayout({required bool desktop}) => switch (this) {
    AppGuide.tabs ||
    AppGuide.characters ||
    AppGuide.tools => desktop ? AppGuide.desktop : this,
    AppGuide.desktop => desktop ? this : null,
    AppGuide.chat ||
    AppGuide.more ||
    AppGuide.api ||
    AppGuide.presets ||
    AppGuide.personas => this,
  };

  List<GuideTourStep> get steps => switch (this) {
    AppGuide.tabs => tabsTourSteps(),
    AppGuide.chat => chatTourSteps(),
    AppGuide.characters => charactersTourSteps(),
    AppGuide.tools => toolsTourSteps(),
    AppGuide.more => moreTourSteps(),
    AppGuide.api => apiTourSteps(),
    AppGuide.presets => presetsTourSteps(),
    AppGuide.personas => personasTourSteps(),
    AppGuide.desktop => desktopTourSteps(),
  };
}

/// Guides whose check already ran this session, so a screen that rebuilds or
/// re-opens never re-reads the flag.
final Set<AppGuide> _checked = {};

/// Guides a replay asked for: they run on their screen's next open even with
/// the interactive guides turned off.
final Set<AppGuide> _armed = {};

/// Persisted answer to the onboarding's "turn on interactive guides?" step.
const guidesEnabledKey = 'guides_enabled';

Future<bool> guidesEnabled([SharedPreferences? prefs]) async {
  prefs ??= await SharedPreferences.getInstance();
  return prefs.getBool(guidesEnabledKey) ?? true;
}

Future<void> setGuidesEnabled(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(guidesEnabledKey, enabled);
}

/// Whether a tour is running. A second trigger meanwhile backs off without
/// marking its guide seen, and gets another chance later.
bool _guideOpen = false;

/// Shows [guide] if it has never been shown. Waits out the first-run
/// onboarding — a tour over it would point at screens the reader has not
/// reached yet — and marks the guide seen up front, so a skipped or
/// half-finished tour never reappears.
///
/// On desktop the tabs, characters and tools triggers all resolve to the one
/// [AppGuide.desktop] tour, so whichever fires first shows it and the others
/// back off.
Future<void> maybeShowGuide(BuildContext context, AppGuide requested) async {
  final guide = requested.forLayout(desktop: isDesktopLayout(context));
  if (guide == null || _checked.contains(guide) || _guideOpen) return;
  _checked.add(guide);

  final prefs = await SharedPreferences.getInstance();
  final armed = _armed.remove(guide);
  if (!armed) {
    // Turned off on the onboarding's guides step: nothing appears on its own,
    // and nothing is marked seen either — the list in Help still has them.
    if (!await guidesEnabled(prefs)) return;
    if (prefs.getBool(guide.shownKey) ?? false) return;
  }
  if (_guideOpen || !await isOnboardingComplete(prefs) || !context.mounted) {
    if (armed) _armed.add(guide);
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
  _armed.clear();
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
/// switch to, so its tour is armed for the next chat the reader opens; a
/// setup screen's tour is armed and its screen opened, so it runs there.
Future<void> replayGuide(BuildContext context, AppGuide guide) async {
  switch (guide) {
    case AppGuide.chat:
      _arm(guide);
      GlazeToast.show(context, 'guides_chat_armed'.tr());
    case AppGuide.api:
    case AppGuide.presets:
    case AppGuide.personas:
      _arm(guide);
      context.go('/tools');
      unawaited(context.push(guide.route!));
    case AppGuide.characters:
      context.go('/characters');
      await showGuide(context, guide);
    case AppGuide.tools:
      context.go('/tools');
      await showGuide(context, guide);
    case AppGuide.desktop:
      // The tour points at the main window's columns; a floating window (the
      // Menu the list was opened from) would sit over them.
      final container = ProviderScope.containerOf(context, listen: false);
      final windows = container.read(desktopWindowsProvider.notifier);
      for (final window in container.read(desktopWindowsProvider)) {
        windows.minimize(window.id);
      }
      context.go('/characters');
      await showGuide(context, guide);
    case AppGuide.tabs:
    case AppGuide.more:
      await showGuide(context, guide);
  }
}

void _arm(AppGuide guide) {
  _checked.remove(guide);
  _armed.add(guide);
}
