import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../../core/platform/system_settings.dart';
import '../../../core/services/generation_notification_service.dart';
import '../../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/theme_provider.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../app_settings_provider.dart';
import 'app_settings_behavior_groups.dart';
import 'settings_group_base.dart';
import 'settings_highlight.dart';
import 'settings_pickers.dart';

/// The settings screen's content, in reading order.
///
/// One flat screen of themed groups rather than the old General/Interface
/// split: that split made every setting an unanswerable "which of the two is
/// this?" question, and both halves were shallow enough to sit together.
///
/// [highlightId] names the row a search hit deep-linked to, if any.
List<Widget> appSettingsGroups({
  required BuildContext context,
  required AppSettings settings,
  required VoidCallback onReset,
  String? highlightId,
}) => [
  _AppearanceGroup(settings: settings, highlightId: highlightId),
  ChatGroup(settings: settings, highlightId: highlightId),
  CharactersGroup(settings: settings, highlightId: highlightId),
  InputGroup(settings: settings, highlightId: highlightId),
  PromptsGroup(settings: settings, highlightId: highlightId),
  PerformanceGroup(settings: settings, highlightId: highlightId),
  // Gated on the raw window width, not [isDesktopLayout]: that one already
  // honours "force mobile layout", which lives in this very group — the switch
  // would hide the group holding it, leaving no way back.
  if (isWideViewport(context))
    DesktopGroup(settings: settings, highlightId: highlightId),
  _GeneralGroup(settings: settings, highlightId: highlightId),
  _AdvancedGroup(highlightId: highlightId, onReset: onReset),
];

// ── Appearance ───────────────────────────────────────────────────────────────

class _AppearanceGroup extends SettingsGroup {
  const _AppearanceGroup({required super.settings, required super.highlightId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    return MenuGroup(
      header: 'settings_group_appearance'.tr(),
      headerIcon: Icons.palette_rounded,
      helpTerm: 'themes',
      items: [
        MenuItem(
          icon: Icons.palette_outlined,
          label: 'theme_presets'.tr(),
          trailing: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: context.cs.primary,
              shape: BoxShape.circle,
            ),
          ),
          onTap: () => goOrFloat(context, ref, 'theme-settings', push: true),
        ),
        highlightIf(
          'theme_mode',
          highlightId,
          MenuItem(
            icon: Icons.brightness_6_outlined,
            label: 'theme_title'.tr(),
            value: themeModeLabel(theme.mode),
            onTap: () => showThemeModePicker(context, ref),
          ),
        ),
        highlightIf(
          'chat_layout',
          highlightId,
          MenuItem(
            icon: Icons.view_agenda_outlined,
            label: 'menu_chat_layout'.tr(),
            subtitle: 'desc_chat_layout'.tr(),
            value: theme.activePreset.chatLayout == 'bubble'
                ? 'layout_bubble'.tr()
                : 'layout_default'.tr(),
            onTap: () => showLayoutPicker(context, ref),
          ),
        ),
        toggle(
          id: 'show_help_tips',
          label: 'menu_show_help_tips'.tr(),
          description: 'desc_show_help_tips'.tr(),
          // Stored as "hide", shown as "show": a switch whose off state means
          // "not hidden" reads as a double negative on every glance.
          value: !settings.hideTooltips,
          onChanged: (v) =>
              notifierOf(ref).save(settings.copyWith(hideTooltips: !v)),
        ),
      ],
    );
  }
}

// ── General ──────────────────────────────────────────────────────────────────

class _GeneralGroup extends SettingsGroup {
  const _GeneralGroup({required super.settings, required super.highlightId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuGroup(
      header: 'settings_group_general'.tr(),
      headerIcon: Icons.tune_rounded,
      items: [
        highlightIf(
          'language',
          highlightId,
          MenuItem(
            icon: Icons.language_outlined,
            label: 'menu_language'.tr(),
            value: settings.language == 'en' ? 'English' : 'Русский',
            onTap: () => showLanguagePicker(context, ref, settings),
          ),
        ),
        // Hidden where no host implements the channel: the row would otherwise
        // be a tap that does nothing at all.
        if (SystemSettings.canOpenNotificationSettings)
          highlightIf(
            'notifications',
            highlightId,
            MenuItem(
              icon: Icons.notifications_none_outlined,
              label: 'menu_notifications'.tr(),
              trailing: const Icon(
                Icons.open_in_new_rounded,
                size: 18,
                color: Color(0xFF99A2AD),
              ),
              onTap: SystemSettings.openNotificationSettings,
            ),
          ),
        highlightIf(
          'notifications_test',
          highlightId,
          MenuItem(
            icon: Icons.notifications_active_outlined,
            label: 'menu_notifications_test'.tr(),
            onTap: () => _sendTestNotification(context),
          ),
        ),
      ],
    );
  }

  /// Posts a message notification on demand and reports what the OS did with
  /// it. Delivery depends on platform state this app cannot read back — a
  /// revoked permission, a resource the notification plugin cannot resolve, a
  /// channel the user silenced — and every one of those failures is otherwise
  /// invisible: the reply simply arrives with no notification and no error.
  Future<void> _sendTestNotification(BuildContext context) async {
    final service = GenerationNotificationService.instance;
    if (!service.notificationsSupported) {
      GlazeToast.show(context, 'notification_test_unsupported'.tr());
      return;
    }

    final enabled = await service.areNotificationsEnabled();
    if (!context.mounted) return;
    if (enabled == false) {
      GlazeToast.show(
        context,
        'notification_test_blocked'.tr(),
        isError: true,
        duration: 5000,
      );
      return;
    }

    final sent = await service.sendTestNotification(
      'Glaze',
      'menu_notifications_test'.tr(),
    );
    if (!context.mounted) return;
    if (sent) {
      GlazeToast.show(context, 'notification_test_sent'.tr());
    } else {
      GlazeToast.show(
        context,
        'notification_test_failed'.tr(
          args: [service.lastNotificationError ?? '—'],
        ),
        isError: true,
        duration: 8000,
        showCopyButton: true,
      );
    }
  }
}

// ── Advanced ─────────────────────────────────────────────────────────────────

class _AdvancedGroup extends ConsumerWidget {
  final String? highlightId;
  final VoidCallback onReset;

  const _AdvancedGroup({required this.highlightId, required this.onReset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuGroup(
      header: 'settings_group_advanced'.tr(),
      headerIcon: Icons.science_outlined,
      items: [
        MenuItem(
          icon: Icons.science_outlined,
          label: 'experimental_features_title'.tr(),
          trailing: const Icon(
            Icons.chevron_right,
            size: 20,
            color: Color(0xFF99A2AD),
          ),
          onTap: () => context.push('/extensions'),
        ),
        highlightIf(
          'reset_settings',
          highlightId,
          MenuItem(
            icon: Icons.restart_alt_rounded,
            label: 'settings_reset_title'.tr(),
            subtitle: 'settings_reset_hint'.tr(),
            onTap: onReset,
          ),
        ),
      ],
    );
  }
}
