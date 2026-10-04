import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/menu/search/menu_search_index.dart';

/// The index is a hand-maintained mirror of the settings screen, so these guard
/// the two mistakes that break it silently: a duplicated highlight id, which
/// flashes the wrong row, and a settings entry that never made it into the
/// More tab's index.
///
/// Localization is not initialized here — `tr()` then returns the key itself,
/// which is all these structural checks need.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('settings entries carry unique highlight ids', () {
    final entries = buildSettingsSearchIndex();
    expect(entries, isNotEmpty);

    final ids = entries.map((e) => e.settingId).whereType<String>().toList();
    expect(ids, isNotEmpty);
    expect(ids.toSet().length, ids.length, reason: 'duplicate highlight id');

    for (final entry in entries) {
      expect(entry.title, isNotEmpty);
      expect(entry.breadcrumb, isNotEmpty);
    }
  });

  test('every platform-independent settings row is indexed', () {
    final ids = buildSettingsSearchIndex()
        .map((e) => e.settingId)
        .whereType<String>()
        .toSet();

    // The rows that exist on every platform and window size. Haptics,
    // message vibration and the notifications row are platform-gated, so they
    // are deliberately absent from this list.
    const expected = {
      'theme_mode',
      'chat_layout',
      'show_help_tips',
      'dialog_grouping',
      'swipe_regeneration',
      'show_msg_id',
      'show_gen_time',
      'show_token_count',
      'allow_message_scripts',
      'show_our_picks',
      'open_card_after_import',
      'use_standard_randomizer',
      'virtual_keyboard_send',
      'add_block_at_top',
      'battery_saver_ui',
      'enter_to_send',
      'force_mobile_layout',
      'language',
      'reset_settings',
    };
    expect(
      ids.containsAll(expected),
      isTrue,
      reason: '${expected.difference(ids)}',
    );
  });

  test('the More index carries the settings entries too', () {
    final settings = buildSettingsSearchIndex();
    final all = buildMenuSearchIndex();
    expect(all.length, greaterThan(settings.length));
    for (final entry in settings) {
      expect(
        all.any(
          (e) => e.settingId == entry.settingId && e.title == entry.title,
        ),
        isTrue,
        reason: '${entry.title} missing from the More index',
      );
    }
  });
}
