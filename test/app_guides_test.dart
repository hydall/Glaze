import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/guides/guide_anchor.dart';
import 'package:glaze_flutter/features/guides/guide_service.dart';
import 'package:glaze_flutter/features/guides/guide_tour.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/pump_localized.dart';

/// Runs with real (English) translations, so the assertions read the same
/// strings the user sees.
const followSystem = 'Follow Device Theme';

void main() {
  setUp(resetGuideSession);

  /// Provider writes (and the prefs-backed provider loads) do not complete
  /// under the fake clock alone, so real async rounds are interleaved with
  /// pumps — the same pattern the catalog onboarding tests use.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Pumps [screen] and returns a context inside it to start tours from.
  Future<BuildContext> pumpScreen(
    WidgetTester tester, {
    Widget screen = const SizedBox.expand(),
    Map<String, Object> prefs = const {},
  }) async {
    await pumpLocalized(
      tester,
      KeyedSubtree(key: const ValueKey('host'), child: screen),
      locale: const Locale('en'),
      prefs: prefs,
      surfaceSize: const Size(430, 932),
    );
    return tester.element(find.byKey(const ValueKey('host')));
  }

  /// Starts a tour without awaiting it — the future only completes once the
  /// tour is closed — and lets its overlay come up. The anchor wait polls on
  /// real time, hence the real delay.
  Future<void> start(
    WidgetTester tester,
    Future<void> Function() open, {
    Duration wait = const Duration(milliseconds: 50),
  }) async {
    await tester.runAsync(() async {
      unawaited(open());
      await Future<void>.delayed(wait);
    });
    await settle(tester);
  }

  Future<void> tapNext(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Next'));
    await settle(tester);
  }

  group('tour', () {
    testWidgets('spotlights each anchor and moves through the steps', (
      tester,
    ) async {
      final context = await pumpScreen(
        tester,
        screen: const Column(
          children: [
            SizedBox(height: 300),
            GuideAnchor(id: 'a', child: SizedBox(width: 80, height: 40)),
            SizedBox(height: 300),
            GuideAnchor(id: 'b', child: SizedBox(width: 80, height: 40)),
          ],
        ),
      );
      await start(
        tester,
        () => showGuideTour(context, const [
          GuideTourStep(target: 'a', title: 'First', body: 'one'),
          GuideTourStep(target: 'b', title: 'Second', body: 'two'),
          GuideTourStep(title: 'Third', body: 'three'),
        ]),
      );

      expect(find.text('First'), findsOneWidget);
      expect(find.text('Step 1 of 3'), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing);

      await tapNext(tester);
      expect(find.text('Second'), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);

      await tapNext(tester);
      expect(find.text('Third'), findsOneWidget);
      expect(find.byTooltip('Next'), findsNothing);
      expect(find.text('Skip'), findsNothing);

      await tester.tap(find.byTooltip('Got it'));
      await settle(tester);
      expect(find.byType(GuideTourView), findsNothing);
    });

    testWidgets('drops optional steps whose control is not on screen', (
      tester,
    ) async {
      final context = await pumpScreen(
        tester,
        screen: const Center(
          child: GuideAnchor(
            id: 'here',
            child: SizedBox(width: 50, height: 50),
          ),
        ),
      );
      await start(
        tester,
        () => showGuideTour(context, const [
          GuideTourStep(target: 'here', title: 'Here', body: ''),
          GuideTourStep(
            target: 'gone',
            title: 'Gone',
            body: '',
            optional: true,
          ),
          GuideTourStep(title: 'End', body: ''),
        ]),
      );

      expect(find.text('Step 1 of 2'), findsOneWidget);
      await tapNext(tester);
      expect(find.text('End'), findsOneWidget);
    });

    testWidgets('Skip closes the tour', (tester) async {
      final context = await pumpScreen(tester);
      await start(
        tester,
        () => showGuideTour(context, const [
          GuideTourStep(title: 'One', body: ''),
          GuideTourStep(title: 'Two', body: ''),
        ]),
      );
      await tester.tap(find.text('Skip'));
      await settle(tester);
      expect(find.byType(GuideTourView), findsNothing);
    });
  });

  group('guides', () {
    // With no screen behind them, only the steps that are not optional stay.
    for (final guide in AppGuide.values) {
      testWidgets('${guide.name} tour runs to the end', (tester) async {
        final required = guide.steps.where((s) => !s.optional).length;
        final context = await pumpScreen(tester);
        await start(
          tester,
          () => showGuide(context, guide),
          wait: const Duration(milliseconds: 1700),
        );
        var steps = 1;
        while (find.byTooltip('Next').evaluate().isNotEmpty) {
          await tapNext(tester);
          steps++;
        }
        expect(find.byTooltip('Got it'), findsOneWidget);
        expect(steps, required);
      });
    }

    testWidgets('chat tour flips Swipe to Regenerate in place', (tester) async {
      final context = await pumpScreen(tester);
      await start(
        tester,
        () => showGuide(context, AppGuide.chat),
        wait: const Duration(milliseconds: 1700),
      );
      while (find.text('Swipe to Regenerate').evaluate().isEmpty) {
        await tapNext(tester);
      }
      await tester.tap(find.byType(Switch).first, warnIfMissed: false);
      await settle(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('disableSwipeRegeneration'), isTrue);
    });

    testWidgets('more tour flips Follow the device theme in place', (
      tester,
    ) async {
      final context = await pumpScreen(tester);
      await start(
        tester,
        () => showGuide(context, AppGuide.more),
        wait: const Duration(milliseconds: 1700),
      );
      while (find.text(followSystem).evaluate().isEmpty) {
        await tapNext(tester);
      }
      await tester.tap(find.byType(Switch).first, warnIfMissed: false);
      await settle(tester);

      final container = ProviderScope.containerOf(
        tester.element(find.text(followSystem)),
      );
      expect(container.read(themeProvider).followSystem, isTrue);
    });
  });

  group('maybeShowGuide', () {
    Future<void> trigger(WidgetTester tester, BuildContext context) => start(
      tester,
      () => maybeShowGuide(context, AppGuide.tabs),
      wait: const Duration(milliseconds: 1700),
    );

    testWidgets('waits out the first-run onboarding', (tester) async {
      final context = await pumpScreen(tester);
      await trigger(tester, context);

      expect(find.byType(GuideTourView), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppGuide.tabs.shownKey), isNull);
    });

    testWidgets('shows once and marks the guide seen', (tester) async {
      final context = await pumpScreen(
        tester,
        prefs: const {'onboarding_complete': true},
      );
      await trigger(tester, context);

      expect(find.byType(GuideTourView), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppGuide.tabs.shownKey), isTrue);
    });

    testWidgets('stays away once seen', (tester) async {
      final context = await pumpScreen(
        tester,
        prefs: {'onboarding_complete': true, AppGuide.tabs.shownKey: true},
      );
      await trigger(tester, context);

      expect(find.byType(GuideTourView), findsNothing);
    });
  });
}
