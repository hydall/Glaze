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
      hideTooltips: true,
      disableSwipeRegeneration: true,
      allowMessageScripts: true,
      language: 'ru',
      virtualKeyboardSend: true,
      tokenizerHidePercent: 42.5,
      tokenizerHistoryFillThreshold: 91.5,
      showOurPicks: false,
      forceMobileLayout: false,
      addBlockAtTop: true,
      openCardAfterImport: false,
      hapticFeedback: false,
      messageVibration: false,
      janitorLorebookSource: ExtractionSource.local,
      janitorCardSource: ExtractionSource.datacat,
      janitorCharacterSource: ExtractionSource.local,
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

  group('legacy extractJanitorLocally migration', () {
    test('the opt-in carries over to the lorebook and character sources', () {
      SharedPreferences.setMockInitialValues({'extractJanitorLocally': true});
      return SharedPreferences.getInstance().then((prefs) {
        final settings = AppSettingsPreferences.read(prefs);
        expect(settings.janitorLorebookSource, ExtractionSource.local);
        expect(settings.janitorCharacterSource, ExtractionSource.local);
        // Card loading was never governed by the old toggle, so it keeps its
        // own default.
        expect(settings.janitorCardSource, ExtractionSource.local);
      });
    });

    test('the opt-in being off carries over as DataCat', () async {
      SharedPreferences.setMockInitialValues({'extractJanitorLocally': false});
      final prefs = await SharedPreferences.getInstance();
      final settings = AppSettingsPreferences.read(prefs);
      expect(settings.janitorLorebookSource, ExtractionSource.datacat);
      expect(settings.janitorCharacterSource, ExtractionSource.datacat);
    });

    test('an explicit new value outranks the legacy key', () async {
      SharedPreferences.setMockInitialValues({
        'extractJanitorLocally': true,
        'janitorLorebookSource': 'datacat',
      });
      final prefs = await SharedPreferences.getInstance();
      final settings = AppSettingsPreferences.read(prefs);
      expect(settings.janitorLorebookSource, ExtractionSource.datacat);
      expect(settings.janitorCharacterSource, ExtractionSource.local);
    });

    test('an unknown source name falls back to the default', () async {
      SharedPreferences.setMockInitialValues({
        'janitorCardSource': 'not-a-source',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        AppSettingsPreferences.read(prefs).janitorCardSource,
        const AppSettings().janitorCardSource,
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
