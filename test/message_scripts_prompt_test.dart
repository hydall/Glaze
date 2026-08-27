// Guards the "a message tried to run JavaScript" offer: the JS→Dart callback
// must stay registered and wired, the settings switch must record an explicit
// choice before it saves, and both locales must carry the sheet's copy.
//
// The wiring assertions are static-analysis style (they read the source as a
// string) for the same reason as `webview_assets_test.dart`: the callback is
// only observable through a live WebView, which unit tests cannot host.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/bridge/bridge_handlers.dart';

String _source(String path) => File(path).readAsStringSync();

Map<String, dynamic> _translations(String locale) =>
    jsonDecode(_source('assets/translations/$locale.json'))
        as Map<String, dynamic>;

void main() {
  group('blocked message script callback', () {
    test('is declared as a no-arg bridge handler', () {
      expect(
        bridgeHandlers['onMessageScriptBlocked']?.kind,
        HandlerKind.noArgs,
      );
    });

    test('dispatches to the controller callback', () {
      final source = _source(
        'lib/features/chat/bridge/chat_bridge_controller.dart',
      );
      expect(source, contains('void Function()? onMessageScriptBlocked;'));
      expect(source, contains("case 'onMessageScriptBlocked':"));
      expect(source, contains('onMessageScriptBlocked?.call();'));
    });

    test('is wired everywhere the bridge is bound', () {
      for (final path in [
        'lib/features/chat/widgets/chat_webview_widget.dart',
        'lib/features/chat/widgets/chat_webview_surface.dart',
      ]) {
        final source = _source(path);
        expect(
          source,
          contains('bridge.onMessageScriptBlocked = ()'),
          reason: '$path must wire the blocked-script callback',
        );
        expect(source, contains('maybeShowMessageScriptsPrompt(context, ref)'));
      }
    });
  });

  group('message scripts prompt', () {
    final source = _source(
      'lib/features/chat/widgets/message_scripts_prompt_sheet.dart',
    );

    test('never offers again once the user has answered', () {
      expect(source, contains("'messageScriptsChoiceMade'"));
      expect(
        source,
        contains('prefs.getBool(kMessageScriptsChoiceMadeKey) ?? false'),
      );
      expect(
        source,
        contains('prefs.setBool(kMessageScriptsChoiceMadeKey, true)'),
      );
    });

    test('offers nothing while message scripts are already allowed', () {
      expect(
        source,
        contains(
          'ref.read(appSettingsProvider).value?.allowMessageScripts ?? false',
        ),
      );
    });

    test('enabling goes through the settings notifier', () {
      expect(source, contains('allowMessageScripts: true'));
      expect(source, contains('appSettingsProvider.notifier'));
    });

    test('the settings switch records the choice before saving', () {
      final settings = _source(
        'lib/features/settings/widgets/app_settings_behavior_groups.dart',
      );
      final mark = settings.indexOf('await markMessageScriptsChoiceMade(ref);');
      final save = settings.indexOf('allowMessageScripts: false');
      expect(mark, isNonNegative);
      expect(mark, lessThan(save));
    });

    test('both locales carry the sheet copy', () {
      const keys = [
        'message_scripts_detected_title',
        'message_scripts_detected_body',
        'message_scripts_detected_enable',
        'message_scripts_detected_keep_off',
      ];
      for (final locale in ['en', 'ru']) {
        final map = _translations(locale);
        for (final key in keys) {
          expect(
            map[key],
            isA<String>().having((s) => s.isNotEmpty, 'is not empty', isTrue),
            reason: '$locale.json is missing $key',
          );
        }
      }
    });
  });
}
