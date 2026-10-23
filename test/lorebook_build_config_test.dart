import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_lorebook_rebuilder.dart';
import 'package:glaze_flutter/features/catalog/widgets/janitor_phase_label.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const active = ApiConfig(id: 'chat', endpoint: 'chat.test', model: 'chat-m');
  const other = ApiConfig(id: 'build', endpoint: 'build.test', model: 'b-m');
  const embedding = ApiConfig(id: 'emb', mode: 'embedding', model: 'e');
  const configs = [active, other, embedding];

  group('resolveLorebookBuildConfig', () {
    test('an unset slot runs on the chat connection', () {
      final config = resolveLorebookBuildConfig(
        const AppSettings(),
        configs: configs,
        active: active,
      );
      expect(config?.id, 'chat');
      expect(config?.model, 'chat-m');
    });

    test('the picked connection and model override win', () {
      final config = resolveLorebookBuildConfig(
        const AppSettings(
          lorebookBuildApiConfigId: 'build',
          lorebookBuildModel: ' big-model ',
        ),
        configs: configs,
        active: active,
      );
      expect(config?.id, 'build');
      expect(config?.endpoint, 'build.test');
      expect(config?.model, 'big-model');
    });

    test('a deleted connection falls back to the chat one', () {
      final config = resolveLorebookBuildConfig(
        const AppSettings(lorebookBuildApiConfigId: 'gone'),
        configs: configs,
        active: active,
      );
      expect(config?.id, 'chat');
    });

    test('an embedding connection never runs a build', () {
      final config = resolveLorebookBuildConfig(
        const AppSettings(lorebookBuildApiConfigId: 'emb'),
        configs: configs,
        active: active,
      );
      expect(config, isNull);
    });
  });

  group('janitorPhaseLabel', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await EasyLocalization.ensureInitialized();
    });

    test('blank stays blank, unknown stays raw', () {
      expect(janitorPhaseLabel(null), '');
      expect(janitorPhaseLabel('  '), '');
      expect(janitorPhaseLabel('something new'), 'something new');
    });

    test('known phases are mapped to a translation key', () {
      // No locale is loaded here, so `tr()` hands back the key itself.
      expect(janitorPhaseLabel('configuring proxy'), 'janitor_phase_account');
      expect(janitorPhaseLabel('triggering (card)'), 'janitor_phase_card');
      expect(
        janitorPhaseLabel('triggering (lorebook, pass 2/5)'),
        'janitor_phase_trigger_pass',
      );
    });
  });
}
