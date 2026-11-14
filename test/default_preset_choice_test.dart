import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/featured_presets.dart';
import 'package:glaze_flutter/core/services/preset_seeder.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a brand-new install generates with. It used to be "Default Chat", a
/// bare skeleton built in the seeder that nobody picked on purpose — it simply
/// sorted first.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> prefsWith(Map<String, Object> seed) async {
    SharedPreferences.setMockInitialValues(seed);
    return SharedPreferences.getInstance();
  }

  group('defaultPresetChoice', () {
    test('a first run with nothing chosen lands on the shipped preset', () {
      expect(
        defaultPresetChoice(alreadySeeded: false, activePresetId: null),
        defaultPresetId,
      );
      expect(
        defaultPresetChoice(alreadySeeded: false, activePresetId: ''),
        defaultPresetId,
      );
    });

    test('an install that has been here before is left alone', () {
      expect(
        defaultPresetChoice(alreadySeeded: true, activePresetId: null),
        isNull,
      );
      expect(
        defaultPresetChoice(alreadySeeded: true, activePresetId: 'mine'),
        isNull,
      );
    });

    test('a preset the user already has is never overwritten', () {
      // A restored backup and a migration from the Vue app both write an
      // active preset and can both leave the first-run flag clear.
      expect(
        defaultPresetChoice(alreadySeeded: false, activePresetId: 'mine'),
        isNull,
      );
    });
  });

  test('the default is a preset the app actually ships', () {
    // It is chosen by id before the featured seeding has necessarily run, so
    // nothing at runtime would catch a typo here.
    expect(
      featuredPresets.map((f) => f.id),
      contains(defaultPresetId),
    );
  });

  group('applyFirstRunPresetChoice', () {
    test('a first run is left pointing at the shipped preset', () async {
      final prefs = await prefsWith({});

      await applyFirstRunPresetChoice(preferences: prefs);

      expect(prefs.getString('activePresetId'), defaultPresetId);
      // Written before the app reads it, so the next launch is an ordinary
      // load rather than a value changing under the first frames.
      expect(prefs.getBool('defaultPresetsSeeded'), isTrue);
    });

    test('a second launch changes nothing', () async {
      final prefs = await prefsWith({
        'defaultPresetsSeeded': true,
        'activePresetId': 'mine',
      });

      await applyFirstRunPresetChoice(preferences: prefs);

      expect(prefs.getString('activePresetId'), 'mine');
    });

    test('a restored backup keeps the preset it restored', () async {
      // js_backup_importer clears the first-run flag on purpose, so this runs
      // again against an install that is anything but fresh.
      final prefs = await prefsWith({'activePresetId': 'restored'});

      await applyFirstRunPresetChoice(preferences: prefs);

      expect(prefs.getString('activePresetId'), 'restored');
      expect(prefs.getBool('defaultPresetsSeeded'), isTrue);
    });
  });
}
