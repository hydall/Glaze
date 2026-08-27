import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/platform/haptics.dart';
import '../../catalog/widgets/third_party_providers_screen.dart';
import '../menu_actions.dart';
import 'menu_search_entry.dart';

/// Every row the More tab search can find, in menu order.
///
/// Rebuilt on each query so labels follow the active locale. Keep it in sync
/// with `menu_screen.dart` and `app_settings_screen.dart`: an entry that points
/// at a row which no longer exists is worse than no entry at all.
List<MenuSearchEntry> buildMenuSearchIndex() => [
  ..._menuEntries(),
  ..._settingsEntries(),
  ..._interfaceEntries(),
];

/// Deep-links into a section of the App Settings screen, flashing [highlight]
/// once it is on screen.
void _openSettings(
  BuildContext context, {
  String section = 'main',
  String? highlight,
}) {
  final query = <String, String>{
    if (section != 'main') 'section': section,
    'highlight': ?highlight,
  };
  context.push(
    query.isEmpty
        ? '/menu/settings'
        : Uri(path: '/menu/settings', queryParameters: query).toString(),
  );
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
      open: (context) => _openSettings(context),
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

// ── More › Settings ──────────────────────────────────────────────────────────

List<MenuSearchEntry> _settingsEntries() {
  final settings = ['menu_menu_title'.tr(), 'section_settings'.tr()];
  return [
    MenuSearchEntry(
      title: 'theme_presets'.tr(),
      breadcrumb: settings,
      icon: Icons.palette_outlined,
      keywords: const ['theme', 'colors', 'тема', 'цвета', 'оформление'],
      open: (context) => context.push('/menu/themes'),
    ),
    MenuSearchEntry(
      title: 'theme_title'.tr(),
      breadcrumb: settings,
      icon: Icons.brightness_6_outlined,
      keywords: const ['dark', 'light', 'тёмная', 'светлая', 'тема'],
      open: (context) => _openSettings(context, highlight: 'theme_mode'),
    ),
    MenuSearchEntry(
      title: 'menu_language'.tr(),
      breadcrumb: settings,
      icon: Icons.language_outlined,
      keywords: const ['language', 'english', 'русский', 'язык', 'локаль'],
      open: (context) => _openSettings(context, highlight: 'language'),
    ),
    MenuSearchEntry(
      title: 'menu_notifications'.tr(),
      breadcrumb: settings,
      icon: Icons.notifications_none_outlined,
      keywords: const ['notifications', 'уведомления'],
      open: (context) => _openSettings(context, highlight: 'notifications'),
    ),
    MenuSearchEntry(
      title: 'menu_interface_settings'.tr(),
      breadcrumb: settings,
      icon: Icons.settings_outlined,
      keywords: const ['interface', 'ui', 'интерфейс'],
      open: (context) => _openSettings(context, section: 'interface'),
    ),
    MenuSearchEntry(
      title: 'experimental_features_title'.tr(),
      breadcrumb: settings,
      icon: Icons.science_outlined,
      keywords: const [
        'extensions',
        'experimental',
        'расширения',
        'эксперименты',
      ],
      open: (context) => context.push('/extensions'),
    ),
  ];
}

// ── More › Settings › Interface ──────────────────────────────────────────────

List<MenuSearchEntry> _interfaceEntries() {
  final interface = [
    'menu_menu_title'.tr(),
    'section_settings'.tr(),
    'menu_interface_settings'.tr(),
  ];

  MenuSearchEntry item(
    String id,
    String labelKey,
    String? descKey,
    IconData icon,
    List<String> keywords,
  ) => MenuSearchEntry(
    title: labelKey.tr(),
    description: descKey?.tr(),
    breadcrumb: interface,
    icon: icon,
    keywords: keywords,
    open: (context) =>
        _openSettings(context, section: 'interface', highlight: id),
  );

  return [
    item(
      'battery_saver_ui',
      'menu_battery_saver_ui',
      'desc_battery_saver_ui',
      Icons.battery_saver_outlined,
      const ['battery', 'performance', 'батарея', 'производительность'],
    ),
    if (Haptics.isConfigurable)
      item(
        'haptic_feedback',
        'menu_haptic_feedback',
        'desc_haptic_feedback',
        Icons.vibration_rounded,
        const ['haptics', 'vibration', 'вибрация', 'отклик'],
      ),
    item(
      'hide_help_tips',
      'menu_hide_help_tips',
      'desc_hide_help_tips',
      Icons.help_outline_rounded,
      const ['tooltips', 'hints', 'подсказки'],
    ),
    item(
      'show_our_picks',
      'menu_show_our_picks',
      'desc_show_our_picks',
      Icons.star_outline_rounded,
      const ['picks', 'подборка'],
    ),
    item(
      'open_card_after_import',
      'menu_open_card_after_import',
      'desc_open_card_after_import',
      Icons.file_download_outlined,
      const ['import', 'card', 'импорт', 'карточка'],
    ),
    item(
      'use_standard_randomizer',
      'menu_use_standard_randomizer',
      'desc_use_standard_randomizer',
      Icons.casino_outlined,
      const ['random', 'случайный', 'рандом'],
    ),
    item(
      'dialog_grouping',
      'menu_dialog_grouping',
      'desc_dialog_grouping',
      Icons.forum_outlined,
      const ['chats', 'grouping', 'чаты', 'группировка'],
    ),
    item(
      'chat_layout',
      'menu_chat_layout',
      null,
      Icons.view_agenda_outlined,
      const ['bubble', 'layout', 'пузыри', 'вид', 'макет'],
    ),
    item(
      'disable_swipe_regeneration',
      'menu_disable_swipe_regeneration',
      'desc_disable_swipe_regeneration',
      Icons.swipe_outlined,
      const ['swipe', 'regenerate', 'свайп', 'регенерация'],
    ),
    item(
      'allow_message_scripts',
      'menu_allow_message_scripts',
      'desc_allow_message_scripts',
      Icons.code_rounded,
      const ['scripts', 'javascript', 'скрипты'],
    ),
    item(
      'virtual_keyboard_send',
      'menu_virtual_keyboard_send',
      'desc_virtual_keyboard_send',
      Icons.keyboard_outlined,
      const ['keyboard', 'send', 'клавиатура', 'отправка'],
    ),
    if (Haptics.isMessageVibrationConfigurable)
      item(
        'message_vibration',
        'menu_message_vibration',
        'desc_message_vibration',
        Icons.vibration_rounded,
        const ['vibration', 'вибрация', 'сообщение'],
      ),
    item(
      'hide_msg_id',
      'menu_hide_msg_id',
      'desc_hide_msg_id',
      Icons.tag_rounded,
      const ['id', 'номер'],
    ),
    item(
      'hide_gen_time',
      'menu_hide_gen_time',
      'desc_hide_gen_time',
      Icons.timer_outlined,
      const ['time', 'время', 'генерация'],
    ),
    item(
      'hide_token_count',
      'menu_hide_token_count',
      'desc_hide_token_count',
      Icons.numbers_rounded,
      const ['tokens', 'токены'],
    ),
    item(
      'add_block_at_top',
      'menu_add_block_at_top',
      'desc_add_block_at_top',
      Icons.vertical_align_top_rounded,
      const ['blocks', 'блоки'],
    ),
    item(
      'enter_to_send',
      'menu_enter_to_send',
      'desc_enter_to_send',
      Icons.subdirectory_arrow_left_rounded,
      const ['enter', 'send', 'ввод', 'отправка'],
    ),
    item(
      'force_mobile_layout',
      'menu_force_mobile_layout',
      'desc_force_mobile_layout',
      Icons.phone_android_rounded,
      const ['desktop', 'mobile', 'мобильный', 'десктоп'],
    ),
  ];
}
