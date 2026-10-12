import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/widgets/catalog_onboarding_sheet.dart';
import 'package:glaze_flutter/features/character_list/widgets/character_hiding_onboarding_sheet.dart';
import 'package:glaze_flutter/features/guides/guide_anchor.dart';
import 'package:glaze_flutter/features/guides/guide_service.dart';
import 'package:glaze_flutter/features/guides/guide_tour.dart';
import 'package:glaze_flutter/features/onboarding/onboarding_screen.dart';
import 'package:glaze_flutter/features/onboarding/widgets/onboarding_desktop_wizard.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_layout_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_stepper_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/pump_localized.dart';

/// Every one-time onboarding must present correctly when the window is wide
/// enough for the desktop layout — either its own wide build (the first-run
/// wizard) or the desktop window the sheet system substitutes for a bottom
/// sheet. These run at a desktop viewport so `isDesktopLayout` is true.
void main() {
  const desktop = Size(1280, 800);

  /// Pumps at a desktop viewport with a real (English) locale. [child] is
  /// built under the shell's [DesktopScope], so `showGlazeSheet` picks its
  /// window path and, inside the wizard, the wide build is selected.
  Future<void> pumpDesktop(
    WidgetTester tester,
    Widget child, {
    Map<String, Object> prefs = const {},
  }) async {
    await pumpLocalized(
      tester,
      DesktopScope(isDesktop: true, child: child),
      locale: const Locale('en'),
      prefs: prefs,
      surfaceSize: desktop,
    );
  }

  /// A frame or two for a pushed route's transition (180ms) to finish without
  /// `pumpAndSettle`, which would run forever against the guide tour's pulse.
  Future<void> settleRoute(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The guide tour polls for its anchors on real time, so interleave real
  /// async rounds with pumps (the same pattern `app_guides_test` uses).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  group('first-run wizard', () {
    testWidgets('uses the wide wizard, not the phone flow', (tester) async {
      await pumpDesktop(tester, const OnboardingScreen());

      expect(find.byType(OnboardingDesktopWizard), findsOneWidget);
      expect(find.text('Welcome\nto Glaze'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('advances and goes back through the slides', (tester) async {
      await pumpDesktop(tester, const OnboardingScreen());

      await tester.tap(find.text('Next'));
      await settleRoute(tester);
      expect(find.text('Glaze Features'), findsOneWidget);

      // Back returns to the first slide.
      await tester.tap(find.byIcon(Icons.arrow_back).first);
      await settleRoute(tester);
      expect(find.text('Welcome\nto Glaze'), findsOneWidget);
    });

    testWidgets('lays out at the narrowest desktop window', (tester) async {
      // 768px is the desktop breakpoint; just past it is the tightest window
      // the wide wizard has to fit into.
      await pumpLocalized(
        tester,
        const DesktopScope(isDesktop: true, child: OnboardingScreen()),
        locale: const Locale('en'),
        surfaceSize: const Size(800, 600),
      );

      expect(find.byType(OnboardingDesktopWizard), findsOneWidget);
    });

    testWidgets('skip confirmation opens as a desktop window', (tester) async {
      await pumpDesktop(tester, const OnboardingScreen());

      await tester.tap(find.text('Skip Onboarding'));
      await settleRoute(tester);

      expect(find.text('Skip Onboarding?'), findsOneWidget);
      expect(find.byType(GlazeSheetWindow), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  group('catalog explainer', () {
    testWidgets('opens as a desktop window and pages through', (tester) async {
      await pumpDesktop(
        tester,
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () => unawaited(showCatalogOnboarding(context)),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('open')));
      await settleRoute(tester);

      expect(find.byType(GlazeSheetWindow), findsOneWidget);
      expect(find.byType(GlazeStepperSheet), findsOneWidget);
      expect(find.text('Characters from across the web'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  group('character-hiding explainer', () {
    testWidgets('opens chrome-less (no title bar / close button)', (
      tester,
    ) async {
      await pumpDesktop(
        tester,
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () =>
                  unawaited(maybeShowCharacterHidingOnboarding(context)),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('open')));
      await settleRoute(tester);

      expect(find.text('Character hidden'), findsOneWidget);
      final window = tester.widget<GlazeSheetWindow>(
        find.byType(GlazeSheetWindow),
      );
      expect(
        window.chrome,
        isFalse,
        reason: 'the explainer supplies its own chrome and dims the app behind '
            'it; a titled window would add a close button to a sheet that is '
            'deliberately non-dismissible for a few seconds',
      );
    });
  });

  group('janitor lorebook capture tour', () {
    testWidgets('opens as a spotlight tour on desktop', (tester) async {
      resetGuideSession();
      late BuildContext host;
      await pumpDesktop(
        tester,
        Builder(
          builder: (context) {
            host = context;
            return const SizedBox.expand();
          },
        ),
        prefs: const {'onboarding_complete': true},
      );

      await tester.runAsync(() async {
        unawaited(maybeShowGuide(host, AppGuide.lorebookCapture));
        await Future<void>.delayed(const Duration(milliseconds: 1700));
      });
      await settle(tester);

      expect(find.byType(GuideTourView), findsOneWidget);
      expect(
        find.text('Lorebooks this character carries'),
        findsOneWidget,
      );
    });
  });

  group('guides', () {
    setUp(resetGuideSession);

    test('tabs, characters and tools fold into one tour on desktop', () {
      for (final guide in [
        AppGuide.tabs,
        AppGuide.characters,
        AppGuide.tools,
      ]) {
        expect(guide.forLayout(desktop: true), AppGuide.desktop);
        expect(guide.forLayout(desktop: false), guide);
      }
      expect(AppGuide.chat.forLayout(desktop: true), AppGuide.chat);
      expect(AppGuide.more.forLayout(desktop: true), AppGuide.more);
      expect(AppGuide.desktop.forLayout(desktop: false), isNull);
    });

    testWidgets('the first of the three triggers shows the desktop tour once', (
      tester,
    ) async {
      late BuildContext host;
      await pumpDesktop(
        tester,
        Builder(
          builder: (context) {
            host = context;
            return const SizedBox.expand();
          },
        ),
        prefs: const {'onboarding_complete': true},
      );

      await tester.runAsync(() async {
        unawaited(maybeShowGuide(host, AppGuide.tabs));
        // Its anchors are not on screen here, so it waits out the full poll.
        await Future<void>.delayed(const Duration(milliseconds: 1700));
      });
      await settle(tester);

      expect(find.byType(GuideTourView), findsOneWidget);
      expect(find.text('Three columns'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppGuide.desktop.shownKey), isTrue);
      expect(
        prefs.getBool(AppGuide.tabs.shownKey),
        isNull,
        reason: 'the phone tours stay unseen for the phone layout',
      );

      await tester.tap(find.text('Skip'));
      await settle(tester);
      expect(find.byType(GuideTourView), findsNothing);

      // Characters and Tools opening afterwards do not start a second tour.
      await tester.runAsync(() async {
        unawaited(maybeShowGuide(host, AppGuide.characters));
        unawaited(maybeShowGuide(host, AppGuide.tools));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settle(tester);
      expect(find.byType(GuideTourView), findsNothing);
    });

    testWidgets('the desktop tour is not offered in the phone layout', (
      tester,
    ) async {
      late BuildContext host;
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) {
            host = context;
            return const SizedBox.expand();
          },
        ),
        locale: const Locale('en'),
        prefs: const {'onboarding_complete': true},
        surfaceSize: const Size(430, 932),
      );

      await tester.runAsync(() async {
        unawaited(maybeShowGuide(host, AppGuide.desktop));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settle(tester);

      expect(find.byType(GuideTourView), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppGuide.desktop.shownKey), isNull);
    });

    testWidgets('a spotlight tour runs over a desktop screen', (tester) async {
      late BuildContext host;
      await pumpDesktop(
        tester,
        Builder(
          builder: (context) {
            host = context;
            return const Column(
              children: [
                SizedBox(height: 200),
                GuideAnchor(id: 'a', child: SizedBox(width: 80, height: 40)),
                SizedBox(height: 200),
                GuideAnchor(id: 'b', child: SizedBox(width: 80, height: 40)),
              ],
            );
          },
        ),
      );

      await tester.runAsync(() async {
        unawaited(
          showGuideTour(host, const [
            GuideTourStep(target: 'a', title: 'First', body: 'one'),
            GuideTourStep(target: 'b', title: 'Second', body: 'two'),
          ]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await settle(tester);

      expect(find.text('First'), findsOneWidget);
      await tester.tap(find.byTooltip('Next'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Second'), findsOneWidget);

      await tester.tap(find.byTooltip('Got it'));
      await settle(tester);
      expect(find.byType(GuideTourView), findsNothing);
    });
  });
}
