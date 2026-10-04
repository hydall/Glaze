import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/settings/app_settings_provider.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('round-trips every app setting through the canonical codec', () async {
    const expected = AppSettings(
      enterToSend: false,
      hideMessageId: true,
      hideGenerationTime: true,
      hideTokenCount: true,
      groupDialogs: true,
      batterySaver: false,
      batterySaverMode: BatterySaverMode.off,
      hideTooltips: true,
      disableSwipeRegeneration: true,
      allowMessageScripts: true,
      language: 'ru',
      virtualKeyboardSend: true,
      showOurPicks: false,
      forceMobileLayout: false,
      addBlockAtTop: true,
      openCardAfterImport: false,
      hapticFeedback: false,
      messageVibration: false,
      janitorSource: ExtractionSource.local,
      lorebookBuildPrompt: 'closed prompt',
      lorebookBuildPromptJs: 'script prompt',
      useStandardRandomizer: true,
      hideContextCard: true,
    );
    final prefs = await SharedPreferences.getInstance();

    await AppSettingsPreferences.write(prefs, expected);

    expect(AppSettingsPreferences.read(prefs), expected);
    expect(
      AppSettingsPreferences.encode(expected).keys.toSet(),
      AppSettingsPreferences.keys,
    );
  });

  test(
    'partial cloud settings preserve omitted and invalid local values',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await AppSettingsPreferences.write(
        prefs,
        const AppSettings(hideMessageId: true, language: 'ru'),
      );

      await AppSettingsPreferences.applyPartial(prefs, {
        'enterToSend': false,
        'hideMessageId': <String>[],
      });

      final result = AppSettingsPreferences.read(prefs);
      expect(result.enterToSend, isFalse);
      expect(result.hideMessageId, isTrue);
      expect(result.language, 'ru');
    },
  );

  group('legacy JanitorAI source migration', () {
    test('the pre-split opt-in carries over as Local', () {
      SharedPreferences.setMockInitialValues({'extractJanitorLocally': true});
      return SharedPreferences.getInstance().then((prefs) {
        expect(
          AppSettingsPreferences.read(prefs).janitorSource,
          ExtractionSource.local,
        );
      });
    });

    test('the pre-split opt-in being off carries over as DataCat', () async {
      SharedPreferences.setMockInitialValues({'extractJanitorLocally': false});
      final prefs = await SharedPreferences.getInstance();
      expect(
        AppSettingsPreferences.read(prefs).janitorSource,
        ExtractionSource.datacat,
      );
    });

    test('a Local split source outranks its own DataCat default', () async {
      SharedPreferences.setMockInitialValues({
        'janitorCardSource': 'local',
        'janitorCharacterSource': 'local',
        'janitorLorebookSource': 'datacat',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        AppSettingsPreferences.read(prefs).janitorSource,
        ExtractionSource.local,
      );
    });

    test('all-DataCat split sources merge to DataCat', () async {
      // The card source was Local by default and so carries no choice of its
      // own; the extraction and lorebook defaults are DataCat.
      SharedPreferences.setMockInitialValues({
        'janitorCardSource': 'local',
        'janitorCharacterSource': 'datacat',
        'janitorLorebookSource': 'datacat',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        AppSettingsPreferences.read(prefs).janitorSource,
        ExtractionSource.datacat,
      );
    });

    test('an explicit new value outranks the legacy keys', () async {
      SharedPreferences.setMockInitialValues({
        'janitorSource': 'local',
        'extractJanitorLocally': false,
        'janitorCharacterSource': 'datacat',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        AppSettingsPreferences.read(prefs).janitorSource,
        ExtractionSource.local,
      );
    });

    test('an unknown source name falls back to the default', () async {
      SharedPreferences.setMockInitialValues({'janitorSource': 'not-a-source'});
      final prefs = await SharedPreferences.getInstance();
      expect(
        AppSettingsPreferences.read(prefs).janitorSource,
        const AppSettings().janitorSource,
      );
    });
  });

  test('removeAll clears the legacy opt-in too', () async {
    SharedPreferences.setMockInitialValues({'extractJanitorLocally': true});
    final prefs = await SharedPreferences.getInstance();

    await AppSettingsPreferences.removeAll(prefs);

    expect(AppSettingsPreferences.read(prefs), const AppSettings());
  });

  test('removeAll restores defaults', () async {
    final prefs = await SharedPreferences.getInstance();
    await AppSettingsPreferences.write(
      prefs,
      const AppSettings(hideMessageId: true, language: 'ru'),
    );

    await AppSettingsPreferences.removeAll(prefs);

    expect(AppSettingsPreferences.read(prefs), const AppSettings());
  });
}
