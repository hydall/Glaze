import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/preset_repo.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/state/active_regex_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/global_regex_provider.dart';
import 'package:glaze_flutter/core/state/studio_feature_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A chat preset and an agentic (Studio) preset are mutually exclusive, so the
/// chat preset's scripts must not reach any pass while Studio is on.
///
/// These live in their own file on purpose: [SharedPreferences] caches the
/// instance it hands out for the lifetime of the test isolate, so a file that
/// has already resolved preferences with the switch *off* cannot turn it on
/// again part-way through.
class _SlowGlobalRegexNotifier extends GlobalRegexNotifier {
  @override
  Future<List<PresetRegex>> build() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return const [
      PresetRegex(
        id: 'global-display',
        name: 'Global card',
        regex: '/CARD/g',
        ephemerality: [1],
      ),
    ];
  }
}

const _presetDisplay = PresetRegex(
  id: 'preset-display',
  name: 'Preset card',
  regex: '/TRK/g',
  ephemerality: [1],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'feature_studio_enabled': true});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await PresetRepo(db).put(
      const Preset(id: 'p1', name: 'Preset', regexes: [_presetDisplay]),
    );
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        globalRegexProvider.overrideWith(_SlowGlobalRegexNotifier.new),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    return db.close();
  });

  test('the stored switch is what the notifier settles on', () async {
    // Pins the fixture itself: if this one fails, the tests below are failing
    // over preferences, not over the resolver they are about.
    await container.read(studioFeatureEnabledProvider.notifier).ready;

    expect(container.read(studioFeatureEnabledProvider), isTrue);
  });

  test('the settled switch is what a resolver can branch on', () async {
    // The middle link: if this passes and the two below fail, the resolver is
    // reading the switch wrong rather than the switch reading itself wrong.
    expect(
      await container.read(studioFeatureSettledProvider.future),
      isTrue,
    );
  });

  test('a runtime toggle re-resolves the settled switch', () async {
    // The settled switch does not watch the switch's value, so this is the
    // path that carries a toggle from Settings to everything that branches on
    // it. Nothing else proves that wiring.
    SharedPreferences.setMockInitialValues({'feature_studio_enabled': false});
    final toggled = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        globalRegexProvider.overrideWith(_SlowGlobalRegexNotifier.new),
      ],
    );
    addTearDown(toggled.dispose);

    expect(await toggled.read(studioFeatureSettledProvider.future), isFalse);

    await toggled.read(studioFeatureEnabledProvider.notifier).setEnabled(true);

    expect(await toggled.read(studioFeatureSettledProvider.future), isTrue);
  });

  test('Studio drops the chat preset scripts and keeps the global ones',
      () async {
    final active = await container.read(activeRegexesProvider.future);

    expect(
      active.map((r) => r.id),
      isNot(contains('preset-display')),
      reason:
          'an agentic preset replaces the chat preset, so its scripts belong '
          'to a prompt this turn never builds',
    );
    expect(active.map((r) => r.id), contains('global-display'));
  });

  test('the resolved list waits for the switch to be read', () async {
    // The switch is a StateNotifier that starts at `false` and flips once
    // SharedPreferences answers. Asking straight away — which is what the
    // chat's first paint does — must not catch that window and hand back the
    // chat preset's scripts for a Studio session.
    final display = await container.read(displayRegexesProvider.future);

    expect(display.map((r) => r.id), ['global-display']);
  });
}
