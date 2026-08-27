import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The switch lives in the settings screen's Chat group; its handler is only
// observable through a live tap on a built screen, so these read the source as
// a string (same reasoning as `message_scripts_prompt_test.dart`).
void main() {
  group('message script security setting UI', () {
    final source = File(
      'lib/features/settings/widgets/app_settings_behavior_groups.dart',
    ).readAsStringSync();

    /// The `_setScripts` handler, up to the widget's `build`.
    String handler() {
      final start = source.indexOf('Future<void> _setScripts(');
      expect(start, isNonNegative);
      final end = source.indexOf('Widget build(', start);
      expect(end, isNonNegative);
      return source.substring(start, end);
    }

    test('the switch is wired to the guarded handler', () {
      final start = source.indexOf("id: 'allow_message_scripts'");
      expect(start, isNonNegative);
      // Up to the row's own closing paren — the one at the row's indentation,
      // not the `.tr(),` ones inside it.
      final end = source.indexOf('\n        ),', start);
      expect(end, isNonNegative);
      final block = source.substring(start, end);
      expect(block, contains('_setScripts(context, ref, v)'));
    });

    test('enabling requires an explicit warning confirmation', () {
      final block = handler();
      expect(block, contains('showDialog<bool>'));
      expect(block, contains("'message_scripts_warning_title'.tr()"));
      expect(block, contains("'message_scripts_warning_desc'.tr()"));
      expect(block, contains('confirmed != true'));
      expect(block, contains('allowMessageScripts: true'));
    });

    test('disabling does not require confirmation', () {
      final block = handler();
      final off = block.indexOf('allowMessageScripts: false');
      final dialog = block.indexOf('showDialog<bool>');
      expect(off, isNonNegative);
      expect(dialog, isNonNegative);
      // The "off" path returns before the dialog is ever built.
      expect(off, lessThan(dialog));
    });
  });
}
