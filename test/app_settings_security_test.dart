import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('message script security setting UI', () {
    final source = File(
      'lib/features/settings/app_settings_screen.dart',
    ).readAsStringSync();

    test('enabling requires an explicit warning confirmation', () {
      final start = source.indexOf("label: 'menu_allow_message_scripts'.tr()");
      expect(start, isNonNegative);
      final block = source.substring(
        start,
        source.indexOf('MenuSwitchItem(', start + 1),
      );
      expect(block, contains('showDialog<bool>'));
      expect(block, contains("'message_scripts_warning_title'.tr()"));
      expect(block, contains("'message_scripts_warning_desc'.tr()"));
      expect(block, contains('confirmed == true'));
      expect(block, contains('allowMessageScripts: true'));
    });

    test('disabling does not require confirmation', () {
      expect(source, contains('if (!v)'));
      expect(source, contains('allowMessageScripts: false'));
    });
  });
}
