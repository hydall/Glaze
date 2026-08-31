import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/core/models/persona.dart';

void main() {
  group('AppSettings SharedPrefs keys (Phase 1.2 characterization)', () {
    const expectedKeys = <String, Type>{
      'enterToSend': bool,
      'hideMessageId': bool,
      'hideGenerationTime': bool,
      'hideTokenCount': bool,
      'dialogGrouping': bool,
      'batterySaver': bool,
      'hideTooltips': bool,
      'disableSwipeRegeneration': bool,
      'allowMessageScripts': bool,
      'language': String,
      'virtualKeyboardSend': bool,
      'tokenizerHidePercent': double,
      'tokenizerHistoryFillThreshold': double,
      'showOurPicks': bool,
      'gz_force_mobile_layout': bool,
      'gz_chat_max_width': double,
      'addBlockAtTop': bool,
      'openCardAfterImport': bool,
      'hapticFeedback': bool,
      'messageVibration': bool,
      'extractJanitorLocally': bool,
      'lorebookBuildPrompt': String,
      'lorebookBuildPromptJs': String,
      'useStandardRandomizer': bool,
    };

    test('AppSettings defaults match SharedPrefs fallbacks', () {
      final defaults = AppSettings();
      final mockValues = <String, Object>{};
      SharedPreferences.setMockInitialValues(mockValues);

      for (final entry in expectedKeys.entries) {
        switch (entry.value) {
          // ignore: type_literal_in_constant_pattern
          case bool:
            // gz_force_mobile_layout defaults to FALSE: wide windows get the
            // desktop three-column layout unless the user opts back out.
            if (entry.key == 'enterToSend' ||
                entry.key == 'showOurPicks' ||
                entry.key == 'batterySaver' ||
                entry.key == 'openCardAfterImport' ||
                entry.key == 'hapticFeedback' ||
                entry.key == 'messageVibration') {
              expect(
                _getBoolDefault(defaults, entry.key),
                isTrue,
                reason: '${entry.key} default should be true',
              );
            } else {
              expect(
                _getBoolDefault(defaults, entry.key),
                isFalse,
                reason: '${entry.key} default should be false',
              );
            }
          // ignore: type_literal_in_constant_pattern
          case String:
            if (entry.key == 'language') {
              expect(defaults.language, 'en');
            }
          // ignore: type_literal_in_constant_pattern
          case double:
            if (entry.key == 'tokenizerHidePercent') {
              expect(defaults.tokenizerHidePercent, 30);
            } else if (entry.key == 'tokenizerHistoryFillThreshold') {
              expect(defaults.tokenizerHistoryFillThreshold, 85);
            } else if (entry.key == 'gz_chat_max_width') {
              expect(defaults.chatMaxWidth, 900);
            }
        }
      }
    });

    test('AppSettings.copyWith preserves all fields', () {
      const original = AppSettings(
        enterToSend: false,
        hideMessageId: true,
        language: 'ru',
        tokenizerHidePercent: 50,
      );
      final copy = original.copyWith();
      expect(copy.enterToSend, original.enterToSend);
      expect(copy.hideMessageId, original.hideMessageId);
      expect(copy.language, original.language);
      expect(copy.tokenizerHidePercent, original.tokenizerHidePercent);
    });

    test('all expected SharedPrefs keys are covered', () {
      expect(expectedKeys.keys.toSet(), AppSettingsPreferences.keys);
    });

    test('legacy string values are accepted', () async {
      SharedPreferences.setMockInitialValues({
        'enterToSend': 'false',
        'hideMessageId': '1',
        'tokenizerHidePercent': '45.5',
        'tokenizerHistoryFillThreshold': '90',
        'gz_force_mobile_layout': '0',
        'addBlockAtTop': 'true',
        'allowMessageScripts': 'true',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final settings = await container.read(appSettingsProvider.future);

      expect(settings.enterToSend, isFalse);
      expect(settings.hideMessageId, isTrue);
      expect(settings.tokenizerHidePercent, 45.5);
      expect(settings.tokenizerHistoryFillThreshold, 90);
      expect(settings.forceMobileLayout, isFalse);
      expect(settings.addBlockAtTop, isTrue);
      expect(settings.allowMessageScripts, isTrue);
    });

    test(
      'message scripts are disabled when the preference is absent',
      () async {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final settings = await container.read(appSettingsProvider.future);

        expect(settings.allowMessageScripts, isFalse);
      },
    );

    test('message script preference persists explicitly', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final settings = await container.read(appSettingsProvider.future);

      await container
          .read(appSettingsProvider.notifier)
          .save(settings.copyWith(allowMessageScripts: true));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('allowMessageScripts'), isTrue);
    });

    test('unsupported saved language falls back to English', () async {
      SharedPreferences.setMockInitialValues({'language': 'es'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final settings = await container.read(appSettingsProvider.future);

      expect(settings.language, 'en');
    });

    test(
      'dialogGrouping key in SharedPrefs is "dialogGrouping" not "groupDialogs"',
      () {
        SharedPreferences.setMockInitialValues({'dialogGrouping': true});
        SharedPreferences.getInstance().then((prefs) {
          expect(prefs.getBool('dialogGrouping'), isTrue);
          expect(prefs.containsKey('groupDialogs'), isFalse);
        });
      },
    );
  });

  group('ActiveSelection SharedPrefs keys (Phase 1.2 characterization)', () {
    test('activePresetId key is "activePresetId"', () async {
      SharedPreferences.setMockInitialValues({'activePresetId': 'preset_123'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('activePresetId'), 'preset_123');
    });

    test('activePersonaId key is "activePersonaId"', () async {
      SharedPreferences.setMockInitialValues({
        'activePersonaId': 'persona_456',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('activePersonaId'), 'persona_456');
    });

    test('globalVars key stores JSON-encoded Map<String, String>', () async {
      final vars = {'key1': 'value1', 'key2': 'value2'};
      SharedPreferences.setMockInitialValues({'globalVars': jsonEncode(vars)});
      final prefs = await SharedPreferences.getInstance();
      final decoded =
          jsonDecode(prefs.getString('globalVars')!) as Map<String, dynamic>;
      expect(decoded['key1'], 'value1');
      expect(decoded['key2'], 'value2');
    });

    test(
      'personaConnections key stores JSON-encoded PersonaConnections',
      () async {
        final conns = PersonaConnections(
          character: {'char1': 'persona1'},
          chat: {'session1': 'persona2'},
        );
        SharedPreferences.setMockInitialValues({
          'personaConnections': jsonEncode(conns.toJson()),
        });
        final prefs = await SharedPreferences.getInstance();
        final decoded =
            jsonDecode(prefs.getString('personaConnections')!)
                as Map<String, dynamic>;
        expect(decoded['character'], isA<Map<String, dynamic>>());
        expect(decoded['chat'], isA<Map<String, dynamic>>());
      },
    );
  });

  group('SharedPrefs key consistency (Phase 1.2 characterization)', () {
    test('all known SharedPrefs keys are documented and unique', () {
      final allKeys = <String>{
        'enterToSend',
        'hideMessageId',
        'hideGenerationTime',
        'hideTokenCount',
        'dialogGrouping',
        'batterySaver',
        'hideTooltips',
        'disableSwipeRegeneration',
        'language',
        'virtualKeyboardSend',
        'tokenizerHidePercent',
        'tokenizerHistoryFillThreshold',
        'showOurPicks',
        'gz_force_mobile_layout',
        'addBlockAtTop',
        'activeApiConfigId',
        'activePresetId',
        'activePersonaId',
        'globalVars',
        'personaConnections',
        'presetOrder',
        'memorySettings',
        'lorebookActivations',
        'lorebookSettings',
        'gz_global_regex_scripts',
        'gz_studio_regex_scripts',
        'gz_imggen_settings',
        'gz_sync_provider',
        'gz_sync_auto',
        'gz_sync_last',
        'gz_sync_tokens',
        'gz_sync_manifest_v2',
        'gz_sync_device_id',
        'gz_sync_deleted_entries',
        'gz_sync_auto_count',
        'gz_sync_include_api_keys',
        'gz_sync_pending_pull_manifest',
        'gz_catalog_provider',
        'gz_catalog_filters',
        'gz_janny_token',
        'gz_dc_device',
        'gz_dc_token',
        'gz_thumb_v2_migrated',
        'gz_migration_done',
        'defaultPresetsSeeded',
        'onboarding_complete',
        'chat_last_keyboard_height',
        'magic_drawer_items',
        'magic_drawer_deleted_items',
        'feature_studio_enabled',
        'theme_presets',
        'theme_active_preset',
        'gz_embedding_max_chunk_tokens',
        'presetsConnections',
      };
      final deduped = allKeys.toSet();
      expect(deduped.length, allKeys.length, reason: 'All keys must be unique');
      expect(allKeys.length, greaterThanOrEqualTo(44));
    });
  });
}

bool _getBoolDefault(AppSettings s, String key) {
  switch (key) {
    case 'enterToSend':
      return s.enterToSend;
    case 'hideMessageId':
      return s.hideMessageId;
    case 'hideGenerationTime':
      return s.hideGenerationTime;
    case 'hideTokenCount':
      return s.hideTokenCount;
    case 'dialogGrouping':
      return s.groupDialogs;
    case 'batterySaver':
      return s.batterySaver;
    case 'hideTooltips':
      return s.hideTooltips;
    case 'disableSwipeRegeneration':
      return s.disableSwipeRegeneration;
    case 'virtualKeyboardSend':
      return s.virtualKeyboardSend;
    case 'showOurPicks':
      return s.showOurPicks;
    case 'gz_force_mobile_layout':
      return s.forceMobileLayout;
    case 'addBlockAtTop':
      return s.addBlockAtTop;
    case 'openCardAfterImport':
      return s.openCardAfterImport;
    case 'hapticFeedback':
      return s.hapticFeedback;
    case 'messageVibration':
      return s.messageVibration;
    case 'extractJanitorLocally':
      return s.extractJanitorLocally;
    case 'useStandardRandomizer':
      return s.useStandardRandomizer;
    default:
      return false;
  }
}
