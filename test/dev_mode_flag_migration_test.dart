import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/services/dev_mode_flag_migration.dart';
import 'package:glaze_flutter/core/state/dev_mode_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('clears a dev mode flag left over from the old channel defaults',
      () async {
    final prefs = await prefsWith({DevModeNotifier.prefsKey: true});

    await resetLegacyDevModeFlag(preferences: prefs);

    expect(prefs.containsKey(DevModeNotifier.prefsKey), isFalse);
  });

  test('runs once — a later unlock survives the next startup', () async {
    final prefs = await prefsWith({DevModeNotifier.prefsKey: true});

    await resetLegacyDevModeFlag(preferences: prefs);
    await prefs.setBool(DevModeNotifier.prefsKey, true);
    await resetLegacyDevModeFlag(preferences: prefs);

    expect(prefs.getBool(DevModeNotifier.prefsKey), isTrue);
  });

  test('is a no-op when nothing was stored', () async {
    final prefs = await prefsWith({});

    await resetLegacyDevModeFlag(preferences: prefs);

    expect(prefs.containsKey(DevModeNotifier.prefsKey), isFalse);
  });
}
