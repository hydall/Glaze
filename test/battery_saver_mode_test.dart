import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/settings/app_settings_provider.dart';

/// Battery Saver UI used to be one bool defaulting to **on**, so every install
/// ran the reduced chat rendering whether or not the phone was saving power.
/// It is three states now — System / On / Off, defaulting to System — and the
/// bool survives as the *resolved* answer the rest of the app reads.
///
/// The interesting part is the migration: a stored bool cannot say whether it
/// was chosen or inherited, and the two halves of that have to be treated
/// differently.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppSettings> readWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return AppSettingsPreferences.read(await SharedPreferences.getInstance());
  }

  test('a fresh install follows the system', () async {
    final settings = await readWith({});
    expect(settings.batterySaverMode, BatterySaverMode.system);
  });

  test('the old default is indistinguishable from a choice, so it migrates '
      'to System', () async {
    // `true` was what every install had without doing anything, so it cannot
    // be read as an answer — it takes the new default.
    final settings = await readWith({'batterySaver': true});
    expect(settings.batterySaverMode, BatterySaverMode.system);
  });

  test('an install that turned it off keeps it off', () async {
    // `false` could only be reached deliberately. Under System it would have
    // flipped itself on the next time the phone started saving power.
    final settings = await readWith({'batterySaver': false});
    expect(settings.batterySaverMode, BatterySaverMode.off);
  });

  test('an explicit mode wins over the legacy bool', () async {
    final settings = await readWith({
      'batterySaver': true,
      'batterySaverMode': 'off',
    });
    expect(settings.batterySaverMode, BatterySaverMode.off);
  });

  test('a mode name this build does not know keeps the local value', () async {
    // A newer client, or a corrupted backup. Resetting to the default here
    // would quietly undo the reader's choice on every sync.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await AppSettingsPreferences.write(
      prefs,
      const AppSettings(batterySaverMode: BatterySaverMode.on),
    );

    await AppSettingsPreferences.applyPartial(prefs, {
      'batterySaverMode': 'hyperdrive',
    });

    expect(
      AppSettingsPreferences.read(prefs).batterySaverMode,
      BatterySaverMode.on,
    );
  });

  test('a known mode from a partial restore is applied', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await AppSettingsPreferences.write(prefs, const AppSettings());

    await AppSettingsPreferences.applyPartial(prefs, {
      'batterySaverMode': 'on',
    });

    expect(
      AppSettingsPreferences.read(prefs).batterySaverMode,
      BatterySaverMode.on,
    );
  });

  test('parse accepts its own names and refuses anything else', () {
    expect(BatterySaverMode.parse('system'), BatterySaverMode.system);
    expect(BatterySaverMode.parse(' ON '), BatterySaverMode.on);
    expect(BatterySaverMode.parse('off'), BatterySaverMode.off);
    expect(BatterySaverMode.parse('true'), isNull);
    expect(BatterySaverMode.parse(1), isNull);
    expect(BatterySaverMode.parse(null), isNull);
  });
}
