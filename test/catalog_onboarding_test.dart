import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/widgets/catalog_onboarding_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/pump_localized.dart';

/// Runs with real (English) translations, so the assertions read the same
/// strings the user sees.
///
/// The default provider state enables JanitorAI only; the `prefs` seeds below
/// choose other subsets by writing the disabled-provider list directly.
void main() {
  List<String> disabled({required bool chub, required bool janitor}) => [
    if (!janitor) 'janitor',
    'janny',
    'datacat',
    if (!chub) 'chub',
    'saucepan',
  ];

  /// Provider writes (and the prefs-backed provider loads) do not complete
  /// under the fake clock alone, so real async rounds are interleaved with
  /// pumps — the same pattern the summary sheet tests use.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpSheet(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
  }) async {
    await pumpLocalized(
      tester,
      const CatalogOnboardingSheet(),
      locale: const Locale('en'),
      prefs: prefs,
      surfaceSize: const Size(430, 1400),
    );
    await settle(tester);
  }

  Future<void> tapNext(WidgetTester tester) async {
    await tester.tap(find.text('Next'));
    await settle(tester);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await settle(tester);
  }

  testWidgets('Janitor only: source step, then Local adds the login step', (
    tester,
  ) async {
    await pumpSheet(tester);
    expect(find.text('Characters from across the web'), findsOneWidget);

    await tapNext(tester);
    expect(find.text('Choose your catalogs'), findsOneWidget);
    expect(find.text('JanitorAI'), findsOneWidget);
    expect(find.text('Chub'), findsOneWidget);

    await tapNext(tester);
    expect(find.text('Reading JanitorAI cards'), findsOneWidget);
    expect(find.text('Datacat'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    // No Chub step in this run.
    expect(find.text('Unlock NSFL on Chub'), findsNothing);
    // Last step: it offers to finish, not to advance.
    expect(find.text('Start browsing'), findsOneWidget);
    expect(find.text('Next'), findsNothing);

    await tapText(tester, 'Local');
    // Picking Local appends the login step, so there is somewhere to go again.
    expect(find.text('Next'), findsOneWidget);

    await tapNext(tester);
    expect(find.text('Sign in to JanitorAI'), findsOneWidget);
    expect(find.text('Start browsing'), findsOneWidget);
  });

  testWidgets('Chub only: NSFL is the third step and there is no Janitor step', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      prefs: {
        'gz_disabled_third_party_providers': disabled(
          chub: true,
          janitor: false,
        ),
      },
    );

    await tapNext(tester);
    expect(find.text('Choose your catalogs'), findsOneWidget);
    expect(find.text('Chub'), findsOneWidget);

    await tapNext(tester);
    expect(find.text('Unlock NSFL on Chub'), findsOneWidget);
    expect(find.text('Sign in to Chub'), findsOneWidget);
    expect(find.text('Reading JanitorAI cards'), findsNothing);
    expect(find.text('Start browsing'), findsOneWidget);
  });

  testWidgets('Chub and Janitor: NSFL is step three, the source follows', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      prefs: {
        'gz_disabled_third_party_providers': disabled(
          chub: true,
          janitor: true,
        ),
      },
    );

    await tapNext(tester);
    await tapNext(tester);
    expect(find.text('Unlock NSFL on Chub'), findsOneWidget);

    await tapNext(tester);
    expect(find.text('Reading JanitorAI cards'), findsOneWidget);

    await tapText(tester, 'Local');
    await tapNext(tester);
    expect(find.text('Sign in to JanitorAI'), findsOneWidget);
  });

  testWidgets('picking a Janitor source persists it', (tester) async {
    await pumpSheet(tester);
    await tapNext(tester);
    await tapNext(tester);

    await tapText(tester, 'Local');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('janitorSource'), 'local');
  });

  testWidgets('an already signed-in Chub account shows the NSFL toggle', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      prefs: {
        'gz_disabled_third_party_providers': disabled(
          chub: true,
          janitor: false,
        ),
        'gz_chub_api_key': 'test-key',
        'gz_chub_user_name': 'tester',
      },
    );
    await tapNext(tester);
    await tapNext(tester);

    expect(find.text('Sign in to Chub'), findsNothing);
    expect(find.text('Show NSFL'), findsOneWidget);
  });
}
