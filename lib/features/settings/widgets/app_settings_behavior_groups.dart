import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/haptics.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../chat/widgets/message_scripts_prompt_sheet.dart';
import 'settings_group_base.dart';

/// The behaviour half of the settings screen: what the app does, as opposed to
/// how it looks. Assembled by `appSettingsGroups` in `app_settings_groups.dart`.

// ── Chat ─────────────────────────────────────────────────────────────────────

class ChatGroup extends SettingsGroup {
  const ChatGroup({
    super.key,
    required super.settings,
    required super.highlightId,
  });

  /// Turning scripts *on* is the dangerous direction, so it asks first; turning
  /// them off is taken as an explicit answer and silences the in-chat offer.
  Future<void> _setScripts(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    if (!enabled) {
      await markMessageScriptsChoiceMade(ref);
      await notifierOf(ref).save(settings.copyWith(allowMessageScripts: false));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('message_scripts_warning_title'.tr()),
        content: Text('message_scripts_warning_desc'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('action_cancel'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('message_scripts_enable_action'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await markMessageScriptsChoiceMade(ref);
    await notifierOf(ref).save(settings.copyWith(allowMessageScripts: true));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuGroup(
      header: 'settings_group_chat'.tr(),
      headerIcon: Icons.chat_bubble_outline_rounded,
      items: [
        toggle(
          id: 'dialog_grouping',
          label: 'menu_dialog_grouping'.tr(),
          description: 'desc_dialog_grouping'.tr(),
          helpTerm: 'chat-session',
          value: settings.groupDialogs,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(groupDialogs: v)),
        ),
        toggle(
          id: 'swipe_regeneration',
          label: 'menu_swipe_regeneration'.tr(),
          description: 'desc_swipe_regeneration'.tr(),
          helpTerm: 'swipes',
          value: !settings.disableSwipeRegeneration,
          onChanged: (v) => notifierOf(
            ref,
          ).save(settings.copyWith(disableSwipeRegeneration: !v)),
        ),
        toggle(
          id: 'show_msg_id',
          label: 'menu_show_msg_id'.tr(),
          description: 'desc_show_msg_id'.tr(),
          value: !settings.hideMessageId,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(hideMessageId: !v)),
        ),
        toggle(
          id: 'show_gen_time',
          label: 'menu_show_gen_time'.tr(),
          description: 'desc_show_gen_time'.tr(),
          value: !settings.hideGenerationTime,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(hideGenerationTime: !v)),
        ),
        toggle(
          id: 'show_token_count',
          label: 'menu_show_token_count'.tr(),
          description: 'desc_show_token_count'.tr(),
          helpTerm: 'token',
          value: !settings.hideTokenCount,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(hideTokenCount: !v)),
        ),
        toggle(
          id: 'allow_message_scripts',
          label: 'menu_allow_message_scripts'.tr(),
          description: 'desc_allow_message_scripts'.tr(),
          value: settings.allowMessageScripts,
          onChanged: (v) => _setScripts(context, ref, v),
        ),
      ],
    );
  }
}

// ── Characters ───────────────────────────────────────────────────────────────

class CharactersGroup extends SettingsGroup {
  const CharactersGroup({
    super.key,
    required super.settings,
    required super.highlightId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuGroup(
      header: 'settings_group_characters'.tr(),
      headerIcon: Icons.people_alt_outlined,
      items: [
        toggle(
          id: 'show_our_picks',
          label: 'menu_show_our_picks'.tr(),
          description: 'desc_show_our_picks'.tr(),
          value: settings.showOurPicks,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(showOurPicks: v)),
        ),
        toggle(
          id: 'open_card_after_import',
          label: 'menu_open_card_after_import'.tr(),
          description: 'desc_open_card_after_import'.tr(),
          value: settings.openCardAfterImport,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(openCardAfterImport: v)),
        ),
        toggle(
          id: 'use_standard_randomizer',
          label: 'menu_use_standard_randomizer'.tr(),
          description: 'desc_use_standard_randomizer'.tr(),
          value: settings.useStandardRandomizer,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(useStandardRandomizer: v)),
        ),
      ],
    );
  }
}

// ── Input & feedback ─────────────────────────────────────────────────────────

class InputGroup extends SettingsGroup {
  const InputGroup({
    super.key,
    required super.settings,
    required super.highlightId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuGroup(
      header: 'settings_group_input'.tr(),
      headerIcon: Icons.touch_app_outlined,
      items: [
        if (Haptics.isConfigurable)
          toggle(
            id: 'haptic_feedback',
            label: 'menu_haptic_feedback'.tr(),
            description: 'desc_haptic_feedback'.tr(),
            value: settings.hapticFeedback,
            onChanged: (v) =>
                notifierOf(ref).save(settings.copyWith(hapticFeedback: v)),
          ),
        if (Haptics.isMessageVibrationConfigurable)
          toggle(
            id: 'message_vibration',
            label: 'menu_message_vibration'.tr(),
            description: 'desc_message_vibration'.tr(),
            value: settings.messageVibration,
            onChanged: (v) =>
                notifierOf(ref).save(settings.copyWith(messageVibration: v)),
          ),
        toggle(
          id: 'virtual_keyboard_send',
          label: 'menu_virtual_keyboard_send'.tr(),
          description: 'desc_virtual_keyboard_send'.tr(),
          value: settings.virtualKeyboardSend,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(virtualKeyboardSend: v)),
        ),
      ],
    );
  }
}

// ── Prompts ──────────────────────────────────────────────────────────────────

class PromptsGroup extends SettingsGroup {
  const PromptsGroup({
    super.key,
    required super.settings,
    required super.highlightId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuGroup(
      header: 'settings_group_prompts'.tr(),
      headerIcon: Icons.view_list_outlined,
      helpTerm: 'preset',
      items: [
        toggle(
          id: 'add_block_at_top',
          label: 'menu_add_block_at_top'.tr(),
          description: 'desc_add_block_at_top'.tr(),
          value: settings.addBlockAtTop,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(addBlockAtTop: v)),
        ),
      ],
    );
  }
}

// ── Performance ──────────────────────────────────────────────────────────────

class PerformanceGroup extends SettingsGroup {
  const PerformanceGroup({
    super.key,
    required super.settings,
    required super.highlightId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuGroup(
      header: 'settings_group_performance'.tr(),
      headerIcon: Icons.speed_rounded,
      items: [
        toggle(
          id: 'battery_saver_ui',
          label: 'menu_battery_saver_ui'.tr(),
          description: 'desc_battery_saver_ui'.tr(),
          value: settings.batterySaver,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(batterySaver: v)),
        ),
      ],
    );
  }
}

// ── Desktop ──────────────────────────────────────────────────────────────────

class DesktopGroup extends SettingsGroup {
  const DesktopGroup({
    super.key,
    required super.settings,
    required super.highlightId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuGroup(
      header: 'settings_group_desktop'.tr(),
      headerIcon: Icons.desktop_windows_outlined,
      items: [
        toggle(
          id: 'enter_to_send',
          label: 'menu_enter_to_send'.tr(),
          description: 'desc_enter_to_send'.tr(),
          value: settings.enterToSend,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(enterToSend: v)),
        ),
        toggle(
          id: 'force_mobile_layout',
          label: 'menu_force_mobile_layout'.tr(),
          description: 'desc_force_mobile_layout'.tr(),
          value: settings.forceMobileLayout,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(forceMobileLayout: v)),
        ),
      ],
    );
  }
}
