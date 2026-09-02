import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/platform/haptics.dart';
import '../../../core/platform/system_settings.dart';
import '../../catalog/widgets/third_party_providers_screen.dart';
import '../menu_actions.dart';
import 'menu_search_entry.dart';

/// Every row the More tab search can find, in menu order.
///
/// Rebuilt on each query so labels follow the active locale. Keep it in sync
/// with `menu_screen.dart` and the settings groups in
/// `features/settings/widgets/app_settings_groups.dart`: an entry pointing at a
/// row that no longer exists is worse than no entry at all.
List<MenuSearchEntry> buildMenuSearchIndex() => [
  ..._menuEntries(),
  ...buildSettingsSearchIndex(),
];

/// Just the App Settings rows — what the settings screen's own search covers.
List<MenuSearchEntry> buildSettingsSearchIndex() {
  final settings = ['menu_menu_title'.tr(), 'section_settings'.tr()];

  /// A row that lives on the settings screen. [id] is its highlight id: the
  /// settings screen flashes it in place, the More tab deep-links to it.
  MenuSearchEntry row(
    String id,
    String labelKey,
    String? descKey,
    IconData icon,
    List<String> keywords, {
    String? groupKey,
  }) => MenuSearchEntry(
    title: labelKey.tr(),
    description: descKey?.tr(),
    breadcrumb: groupKey == null ? settings : [...settings, groupKey.tr()],
    icon: icon,
    keywords: keywords,
    settingId: id,
    open: (context) => context.push(
      Uri(
        path: '/menu/settings',
        queryParameters: {'highlight': id},
      ).toString(),
    ),
  );

  return [
    // ── Appearance ──────────────────────────────────────────────────────────
    MenuSearchEntry(
      title: 'theme_presets'.tr(),
      breadcrumb: [...settings, 'settings_group_appearance'.tr()],
      icon: Icons.palette_outlined,
      keywords: const ['theme', 'colors', 'тема', 'цвета', 'оформление'],
      open: (context) => context.push('/menu/themes'),
    ),
    row(
      'theme_mode',
      'theme_title',
      null,
      Icons.brightness_6_outlined,
      const ['dark', 'light', 'тёмная', 'светлая', 'тема'],
      groupKey: 'settings_group_appearance',
    ),
    row(
      'chat_layout',
      'menu_chat_layout',
      'desc_chat_layout',
      Icons.view_agenda_outlined,
      const ['bubble', 'layout', 'пузыри', 'вид', 'макет'],
      groupKey: 'settings_group_appearance',
    ),
    row(
      'show_help_tips',
      'menu_show_help_tips',
      'desc_show_help_tips',
      Icons.help_outline_rounded,
      const ['tooltips', 'hints', 'подсказки'],
      groupKey: 'settings_group_appearance',
    ),
    // ── Chat ────────────────────────────────────────────────────────────────
    row(
      'dialog_grouping',
      'menu_dialog_grouping',
      'desc_dialog_grouping',
      Icons.forum_outlined,
      const ['chats', 'grouping', 'чаты', 'группировка'],
      groupKey: 'settings_group_chat',
    ),
    row(
      'swipe_regeneration',
      'menu_swipe_regeneration',
      'desc_swipe_regeneration',
      Icons.swipe_outlined,
      const ['swipe', 'regenerate', 'свайп', 'регенерация'],
      groupKey: 'settings_group_chat',
    ),
    row(
      'show_msg_id',
      'menu_show_msg_id',
      'desc_show_msg_id',
      Icons.tag_rounded,
      const ['id', 'номер'],
      groupKey: 'settings_group_chat',
    ),
    row(
      'show_gen_time',
      'menu_show_gen_time',
      'desc_show_gen_time',
      Icons.timer_outlined,
      const ['time', 'время', 'генерация'],
      groupKey: 'settings_group_chat',
    ),
    row(
      'show_token_count',
      'menu_show_token_count',
      'desc_show_token_count',
      Icons.numbers_rounded,
      const ['tokens', 'токены'],
      groupKey: 'settings_group_chat',
    ),
    row(
      'allow_message_scripts',
      'menu_allow_message_scripts',
      'desc_allow_message_scripts',
      Icons.code_rounded,
      const ['scripts', 'javascript', 'скрипты'],
      groupKey: 'settings_group_chat',
    ),
    // ── Characters ──────────────────────────────────────────────────────────
    row(
      'show_our_picks',
      'menu_show_our_picks',
      'desc_show_our_picks',
      Icons.star_outline_rounded,
      const ['picks', 'подборка'],
      groupKey: 'settings_group_characters',
    ),
    row(
      'open_card_after_import',
      'menu_open_card_after_import',
      'desc_open_card_after_import',
      Icons.file_download_outlined,
      const ['import', 'card', 'импорт', 'карточка'],
      groupKey: 'settings_group_characters',
    ),
    row(
      'use_standard_randomizer',
      'menu_use_standard_randomizer',
      'desc_use_standard_randomizer',
      Icons.casino_outlined,
      const ['random', 'случайный', 'рандом'],
      groupKey: 'settings_group_characters',
    ),
    // ── Input & feedback ────────────────────────────────────────────────────
    if (Haptics.isConfigurable)
      row(
        'haptic_feedback',
        'menu_haptic_feedback',
        'desc_haptic_feedback',
        Icons.vibration_rounded,
        const ['haptics', 'vibration', 'вибрация', 'отклик'],
        groupKey: 'settings_group_input',
      ),
    if (Haptics.isMessageVibrationConfigurable)
      row(
        'message_vibration',
        'menu_message_vibration',
        'desc_message_vibration',
        Icons.vibration_rounded,
        const ['vibration', 'вибрация', 'сообщение'],
        groupKey: 'settings_group_input',
      ),
    row(
      'virtual_keyboard_send',
      'menu_virtual_keyboard_send',
      'desc_virtual_keyboard_send',
      Icons.keyboard_outlined,
      const ['keyboard', 'send', 'клавиатура', 'отправка'],
      groupKey: 'settings_group_input',
    ),
    row(
      'composer_actions',
      'composer_actions_title',
      'composer_actions_desc',
      Icons.tune_rounded,
      const [
        'composer',
        'buttons',
        'input',
        'кнопки',
        'ввод',
        'поле',
      ],
      groupKey: 'settings_group_input',
    ),
    // ── Prompts ─────────────────────────────────────────────────────────────
    row(
      'add_block_at_top',
      'menu_add_block_at_top',
      'desc_add_block_at_top',
      Icons.vertical_align_top_rounded,
      const ['blocks', 'блоки', 'промпт'],
      groupKey: 'settings_group_prompts',
    ),
    // ── Performance ─────────────────────────────────────────────────────────
    row(
      'battery_saver_ui',
      'menu_battery_saver_ui',
      'desc_battery_saver_ui',
      Icons.speed_rounded,
      const ['battery', 'performance', 'батарея', 'производительность'],
      groupKey: 'settings_group_performance',
    ),
    // ── Desktop ─────────────────────────────────────────────────────────────
    // Indexed on every platform: the group is hidden on a narrow window, but a
    // search is exactly how someone on a phone-sized window looks for it.
    row(
      'enter_to_send',
      'menu_enter_to_send',
      'desc_enter_to_send',
      Icons.subdirectory_arrow_left_rounded,
      const ['enter', 'send', 'ввод', 'отправка'],
      groupKey: 'settings_group_desktop',
    ),
    row(
      'force_mobile_layout',
      'menu_force_mobile_layout',
      'desc_force_mobile_layout',
      Icons.phone_android_rounded,
      const ['desktop', 'mobile', 'мобильный', 'десктоп'],
      groupKey: 'settings_group_desktop',
    ),
    // ── General ─────────────────────────────────────────────────────────────
    row(
      'language',
      'menu_language',
      null,
      Icons.language_outlined,
      const ['language', 'english', 'русский', 'язык', 'локаль'],
      groupKey: 'settings_group_general',
    ),
    if (SystemSettings.canOpenNotificationSettings)
      row(
        'notifications',
        'menu_notifications',
        null,
        Icons.notifications_none_outlined,
        const ['notifications', 'уведомления'],
        groupKey: 'settings_group_general',
      ),
    // ── Advanced ────────────────────────────────────────────────────────────
    MenuSearchEntry(
      title: 'experimental_features_title'.tr(),
      breadcrumb: [...settings, 'settings_group_advanced'.tr()],
      icon: Icons.science_outlined,
      keywords: const [
        'extensions',
        'experimental',
        'расширения',
        'эксперименты',
      ],
      open: (context) => context.push('/extensions'),
    ),
    row(
      'reset_settings',
      'settings_reset_title',
      'settings_reset_hint',
      Icons.restart_alt_rounded,
      const ['reset', 'defaults', 'сброс', 'по умолчанию'],
      groupKey: 'settings_group_advanced',
    ),
  ];
}

// ── More tab, top level ──────────────────────────────────────────────────────

List<MenuSearchEntry> _menuEntries() {
  final more = ['menu_menu_title'.tr()];
  return [
    MenuSearchEntry(
      title: 'menu_app_settings'.tr(),
      description: 'menu_app_settings_hint'.tr(),
      breadcrumb: more,
      icon: Icons.settings_outlined,
      keywords: const ['settings', 'настройки'],
      open: (context) => context.push('/menu/settings'),
    ),
    MenuSearchEntry(
      title: 'menu_third_party_providers'.tr(),
      description: 'menu_third_party_providers_hint'.tr(),
      breadcrumb: more,
      icon: Icons.extension_outlined,
      keywords: const [
        'janitor',
        'janny',
        'datacat',
        'chub',
        'saucepan',
        'catalog',
        'каталог',
        'провайдеры',
      ],
      open: (context) => openThirdPartyProvidersScreen(context),
    ),
    MenuSearchEntry(
      title: 'menu_backups'.tr(),
      description: 'menu_backups_hint'.tr(),
      breadcrumb: more,
      icon: Icons.backup_outlined,
      keywords: const ['backup', 'export', 'import', 'бэкап', 'резервная'],
      open: (context) => openBackupsSheet(context),
    ),
    MenuSearchEntry(
      title: 'menu_cloud_sync'.tr(),
      description: 'menu_cloud_sync_hint'.tr(),
      breadcrumb: more,
      icon: Icons.sync_rounded,
      keywords: const ['sync', 'cloud', 'синхронизация', 'облако'],
      open: (context) => openCloudSyncSheet(context),
    ),
    MenuSearchEntry(
      title: 'menu_about'.tr(),
      description: 'menu_about_hint'.tr(),
      breadcrumb: more,
      icon: Icons.info_outline_rounded,
      keywords: const ['version', 'версия', 'о приложении'],
      open: (context) => context.push('/menu/about'),
    ),
    MenuSearchEntry(
      title: 'update_section_header'.tr(),
      breadcrumb: [...more, 'menu_about'.tr()],
      icon: Icons.system_update_alt_rounded,
      keywords: const ['update', 'обновление'],
      open: (context) => context.push('/menu/about'),
    ),
    MenuSearchEntry(
      title: 'about_hall_of_fame'.tr(),
      breadcrumb: [...more, 'menu_about'.tr()],
      icon: Icons.emoji_events_outlined,
      keywords: const ['donators', 'зал славы'],
      open: (context) => context.push('/menu/about/hall-of-fame'),
    ),
    MenuSearchEntry(
      title: 'about_license_header'.tr(),
      breadcrumb: [...more, 'menu_about'.tr()],
      icon: Icons.gavel_rounded,
      keywords: const ['agpl', 'licence', 'лицензия'],
      open: (context) => context.push('/menu/about'),
    ),
    MenuSearchEntry(
      title: 'menu_glossary'.tr(),
      description: 'menu_glossary_hint'.tr(),
      breadcrumb: more,
      icon: Icons.menu_book_rounded,
      keywords: const ['glossary', 'terms', 'глоссарий', 'термины'],
      open: (context) => context.push('/menu/glossary'),
    ),
    MenuSearchEntry(
      title: 'onboarding_replay'.tr(),
      description: 'onboarding_replay_hint'.tr(),
      breadcrumb: more,
      icon: Icons.replay_rounded,
      keywords: const ['tutorial', 'onboarding', 'обучение'],
      open: (context) => replayOnboarding(context),
    ),
  ];
}
