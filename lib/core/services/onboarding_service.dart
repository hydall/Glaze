import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../navigation/router.dart' show rootNavigatorKey;
import '../../features/onboarding/onboarding_screen.dart';

const _onboardingCompleteKey = 'onboarding_complete';

Future<bool> isOnboardingComplete([SharedPreferences? prefs]) async {
  prefs ??= await SharedPreferences.getInstance();
  return prefs.getBool(_onboardingCompleteKey) ?? false;
}

Future<void> markOnboardingComplete([SharedPreferences? prefs]) async {
  prefs ??= await SharedPreferences.getInstance();
  await prefs.setBool(_onboardingCompleteKey, true);
}

Future<void> resetOnboarding([SharedPreferences? prefs]) async {
  prefs ??= await SharedPreferences.getInstance();
  await prefs.setBool(_onboardingCompleteKey, false);
}

Future<void> checkAndShowOnboarding(BuildContext context) async {
  if (await isOnboardingComplete()) return;
  if (!context.mounted) return;
  showOnboarding(context);
}

void showOnboarding(BuildContext context) {
  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;
  nav.push(
    PageRouteBuilder<void>(
      opaque: true,
      fullscreenDialog: true,
      pageBuilder: (_, _, _) => const OnboardingScreen(),
      transitionsBuilder: (_, anim, _, child) =>
          FadeTransition(opacity: anim, child: child),
    ),
  );
}
