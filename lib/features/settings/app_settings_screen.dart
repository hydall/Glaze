import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform/haptics.dart';
import '../../core/platform/system_settings.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/theme/theme_provider.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/menu_group.dart';
import '../chat/widgets/message_scripts_prompt_sheet.dart';
import 'app_settings_provider.dart';
import 'widgets/chat_layout_picker.dart';
import 'widgets/settings_highlight.dart';

class AppSettingsScreen extends ConsumerStatefulWidget {
  /// Sub-screen to open on: `'main'` or `'interface'`. Set by the More-tab
  /// search when a hit lives under Interface settings.
  final String initialSection;

  /// Id of the row to scroll to and flash once — the ids the More-tab search
  /// index (`menu_search_index.dart`) deep-links with.
  final String? highlightId;

  const AppSettingsScreen({
    super.key,
    this.initialSection = 'main',
    this.highlightId,
  });

  @override
  ConsumerState<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends ConsumerState<AppSettingsScreen> {
  late String _currentScreen = widget.initialSection == 'interface'
      ? 'interface'
      : 'main';

  /// Wraps the row [id] in a scroll-to-and-flash when it is the deep-link
  /// target, and leaves every other row untouched. The lists build all of their
  /// rows eagerly (hence [SingleChildScrollView] rather than a lazy
  /// [ListView]), so an off-screen target still mounts and reveals itself.
  Widget _flash(String id, Widget child) =>
      id == widget.highlightId ? SettingsHighlight(child: child) : child;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final topPad = MediaQuery.of(context).padding.top + 74.0;
    final bottomPad = ref.watch(navHeightProvider) + 20;

    return GlazeScaffold(
      title: _currentScreen == 'main'
          ? 'section_settings'.tr()
          : 'menu_interface_settings'.tr(),
      useShellHeader: true,
      headerBranchIndex: 3,
      extendBodyBehindHeader: true,
      onBack: () {
        if (_currentScreen == 'interface') {
          setState(() => _currentScreen = 'main');
        } else {
          context.go('/menu');
        }
      },
      showBackground: false,
      body: settingsAsync.when(
        loading: () => const Center(child: GlazeSpinner()),
        error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
        data: (s) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _currentScreen == 'main'
              ? _buildMainSettings(context, s, topPad, bottomPad)
              : _buildInterfaceSettings(context, s, topPad, bottomPad),
        ),
      ),
    );
  }

  Widget _buildMainSettings(
    BuildContext context,
    AppSettings s,
    double topPad,
    double bottomPad,
  ) {
    return SingleChildScrollView(
      key: const ValueKey('main'),
      padding: EdgeInsets.fromLTRB(0, topPad + 8, 0, bottomPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MenuGroup(
            header: 'tab_general'.tr(),
            headerIcon: Icons.tune_rounded,
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
                onTap: () => context.push('/menu/themes'),
              ),
              _flash(
                'theme_mode',
                MenuItem(
                  icon: Icons.brightness_6_outlined,
                  label: 'theme_title'.tr(),
                  value: _themeModeLabel(ref.watch(themeProvider).mode),
                  onTap: () => _showThemeModePicker(context, ref),
                ),
              ),
              _flash(
                'language',
                MenuItem(
                  icon: Icons.language_outlined,
                  label: 'menu_language'.tr(),
                  value: s.language == 'en' ? 'English' : 'Русский',
                  onTap: () => _showLanguagePicker(context, ref, s),
                ),
              ),
              _flash(
                'notifications',
                MenuItem(
                  icon: Icons.notifications_none_outlined,
                  label: 'menu_notifications'.tr(),
                  onTap: SystemSettings.openNotificationSettings,
                ),
              ),
              MenuItem(
                icon: Icons.settings_outlined,
                label: 'menu_interface_settings'.tr(),
                trailing: const Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: Color(0xFF99A2AD),
                ),
                onTap: () => setState(() => _currentScreen = 'interface'),
              ),
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
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInterfaceSettings(
    BuildContext context,
    AppSettings s,
    double topPad,
    double bottomPad,
  ) {
    final notifier = ref.read(appSettingsProvider.notifier);
    return SingleChildScrollView(
      key: const ValueKey('interface'),
      padding: EdgeInsets.fromLTRB(0, topPad + 8, 0, bottomPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── General interface ────────────────────────────────────────────
          // App-wide UI behaviour that isn't tied to a specific area.
          MenuGroup(
            header: 'settings_group_general_ui'.tr(),
            headerIcon: Icons.tune_rounded,
            items: [
              _flash(
                'battery_saver_ui',
                MenuSwitchItem(
                  label: 'menu_battery_saver_ui'.tr(),
                  description: 'desc_battery_saver_ui'.tr(),
                  value: s.batterySaver,
                  onChanged: (v) => notifier.save(s.copyWith(batterySaver: v)),
                ),
              ),
              if (Haptics.isConfigurable)
                _flash(
                  'haptic_feedback',
                  MenuSwitchItem(
                    label: 'menu_haptic_feedback'.tr(),
                    description: 'desc_haptic_feedback'.tr(),
                    value: s.hapticFeedback,
                    onChanged: (v) =>
                        notifier.save(s.copyWith(hapticFeedback: v)),
                  ),
                ),
              _flash(
                'hide_help_tips',
                MenuSwitchItem(
                  label: 'menu_hide_help_tips'.tr(),
                  description: 'desc_hide_help_tips'.tr(),
                  value: s.hideTooltips,
                  onChanged: (v) => notifier.save(s.copyWith(hideTooltips: v)),
                ),
              ),
            ],
          ),
          // ── Characters ───────────────────────────────────────────────────
          // Behaviour around browsing, importing and picking characters.
          MenuGroup(
            header: 'settings_group_characters'.tr(),
            headerIcon: Icons.people_alt_outlined,
            items: [
              _flash(
                'show_our_picks',
                MenuSwitchItem(
                  label: 'menu_show_our_picks'.tr(),
                  description: 'desc_show_our_picks'.tr(),
                  value: s.showOurPicks,
                  onChanged: (v) => notifier.save(s.copyWith(showOurPicks: v)),
                ),
              ),
              _flash(
                'open_card_after_import',
                MenuSwitchItem(
                  label: 'menu_open_card_after_import'.tr(),
                  description: 'desc_open_card_after_import'.tr(),
                  value: s.openCardAfterImport,
                  onChanged: (v) =>
                      notifier.save(s.copyWith(openCardAfterImport: v)),
                ),
              ),
              _flash(
                'use_standard_randomizer',
                MenuSwitchItem(
                  label: 'menu_use_standard_randomizer'.tr(),
                  description: 'desc_use_standard_randomizer'.tr(),
                  value: s.useStandardRandomizer,
                  onChanged: (v) =>
                      notifier.save(s.copyWith(useStandardRandomizer: v)),
                ),
              ),
            ],
          ),
          // ── Chat ─────────────────────────────────────────────────────────
          // Everything scoped to the chat screen and message rendering.
          MenuGroup(
            header: 'settings_group_chat'.tr(),
            headerIcon: Icons.chat_bubble_outline_rounded,
            items: [
              _flash(
                'dialog_grouping',
                MenuSwitchItem(
                  label: 'menu_dialog_grouping'.tr(),
                  description: 'desc_dialog_grouping'.tr(),
                  value: s.groupDialogs,
                  onChanged: (v) => notifier.save(s.copyWith(groupDialogs: v)),
                ),
              ),
              _flash(
                'chat_layout',
                MenuItem(
                  label: 'menu_chat_layout'.tr(),
                  value:
                      ref.watch(themeProvider).activePreset.chatLayout ==
                          'bubble'
                      ? 'layout_bubble'.tr()
                      : 'layout_default'.tr(),
                  onTap: () => _showLayoutPicker(context, ref),
                ),
              ),
              _flash(
                'disable_swipe_regeneration',
                MenuSwitchItem(
                  label: 'menu_disable_swipe_regeneration'.tr(),
                  description: 'desc_disable_swipe_regeneration'.tr(),
                  value: s.disableSwipeRegeneration,
                  onChanged: (v) =>
                      notifier.save(s.copyWith(disableSwipeRegeneration: v)),
                ),
              ),
              _flash(
                'allow_message_scripts',
                MenuSwitchItem(
                  label: 'menu_allow_message_scripts'.tr(),
                  description: 'desc_allow_message_scripts'.tr(),
                  value: s.allowMessageScripts,
                  onChanged: (v) async {
                    if (!v) {
                      // Flipping the switch by hand is an explicit answer, so the
                      // in-chat "a script was found" offer stays quiet afterwards.
                      // Recorded *before* the save: saving re-renders the chat
                      // under the new policy, which is what makes the WebView
                      // report the scripts it blocks.
                      await markMessageScriptsChoiceMade(ref);
                      await notifier.save(
                        s.copyWith(allowMessageScripts: false),
                      );
                      return;
                    }
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text('message_scripts_warning_title'.tr()),
                        content: Text('message_scripts_warning_desc'.tr()),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            child: Text('action_cancel'.tr()),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            child: Text('message_scripts_enable_action'.tr()),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true && context.mounted) {
                      await markMessageScriptsChoiceMade(ref);
                      await notifier.save(
                        s.copyWith(allowMessageScripts: true),
                      );
                    }
                  },
                ),
              ),
              _flash(
                'virtual_keyboard_send',
                MenuSwitchItem(
                  label: 'menu_virtual_keyboard_send'.tr(),
                  description: 'desc_virtual_keyboard_send'.tr(),
                  value: s.virtualKeyboardSend,
                  onChanged: (v) =>
                      notifier.save(s.copyWith(virtualKeyboardSend: v)),
                ),
              ),
              if (Haptics.isMessageVibrationConfigurable)
                _flash(
                  'message_vibration',
                  MenuSwitchItem(
                    label: 'menu_message_vibration'.tr(),
                    description: 'desc_message_vibration'.tr(),
                    value: s.messageVibration,
                    onChanged: (v) =>
                        notifier.save(s.copyWith(messageVibration: v)),
                  ),
                ),
              _flash(
                'hide_msg_id',
                MenuSwitchItem(
                  label: 'menu_hide_msg_id'.tr(),
                  description: 'desc_hide_msg_id'.tr(),
                  value: s.hideMessageId,
                  onChanged: (v) => notifier.save(s.copyWith(hideMessageId: v)),
                ),
              ),
              _flash(
                'hide_gen_time',
                MenuSwitchItem(
                  label: 'menu_hide_gen_time'.tr(),
                  description: 'desc_hide_gen_time'.tr(),
                  value: s.hideGenerationTime,
                  onChanged: (v) =>
                      notifier.save(s.copyWith(hideGenerationTime: v)),
                ),
              ),
              _flash(
                'hide_token_count',
                MenuSwitchItem(
                  label: 'menu_hide_token_count'.tr(),
                  description: 'desc_hide_token_count'.tr(),
                  value: s.hideTokenCount,
                  onChanged: (v) =>
                      notifier.save(s.copyWith(hideTokenCount: v)),
                ),
              ),
              _flash(
                'add_block_at_top',
                MenuSwitchItem(
                  label: 'menu_add_block_at_top'.tr(),
                  description: 'desc_add_block_at_top'.tr(),
                  value: s.addBlockAtTop,
                  onChanged: (v) => notifier.save(s.copyWith(addBlockAtTop: v)),
                ),
              ),
            ],
          ),
          // ── Desktop ──────────────────────────────────────────────────────
          // Settings that only take effect on wide / physical-keyboard setups.
          MenuGroup(
            header: 'settings_group_desktop'.tr(),
            headerIcon: Icons.desktop_windows_outlined,
            items: [
              _flash(
                'enter_to_send',
                MenuSwitchItem(
                  label: 'menu_enter_to_send'.tr(),
                  description: 'desc_enter_to_send'.tr(),
                  value: s.enterToSend,
                  onChanged: (v) => notifier.save(s.copyWith(enterToSend: v)),
                ),
              ),
              _flash(
                'force_mobile_layout',
                MenuSwitchItem(
                  label: 'menu_force_mobile_layout'.tr(),
                  description: 'desc_force_mobile_layout'.tr(),
                  value: s.forceMobileLayout,
                  onChanged: (v) =>
                      notifier.save(s.copyWith(forceMobileLayout: v)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.dark:
        return 'theme_dark'.tr();
      case ThemeMode.light:
        return 'theme_light'.tr();
      case ThemeMode.system:
        return 'theme_system'.tr();
    }
  }

  void _showThemeModePicker(BuildContext context, WidgetRef ref) {
    final current = ref.read(themeProvider).mode;
    GlazeBottomSheet.show<void>(
      context,
      title: 'theme_title'.tr(),
      items: ThemeMode.values
          .map(
            (mode) => BottomSheetItem(
              label: _themeModeLabel(mode),
              icon: mode == current
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              iconColor: mode == current
                  ? context.cs.primary
                  : context.cs.onSurfaceVariant,
              onTap: () {
                Navigator.of(context, rootNavigator: true).pop();
                ref.read(themeProvider.notifier).setMode(mode);
              },
            ),
          )
          .toList(),
    );
  }

  void _showLanguagePicker(BuildContext context, WidgetRef ref, AppSettings s) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'menu_language'.tr(),
      items: [
        BottomSheetItem(
          label: 'English',
          icon: s.language == 'en'
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
          iconColor: s.language == 'en'
              ? context.cs.primary
              : context.cs.onSurfaceVariant,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref
                .read(appSettingsProvider.notifier)
                .save(s.copyWith(language: 'en'));
          },
        ),
        BottomSheetItem(
          label: 'Русский',
          icon: s.language == 'ru'
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
          iconColor: s.language == 'ru'
              ? context.cs.primary
              : context.cs.onSurfaceVariant,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref
                .read(appSettingsProvider.notifier)
                .save(s.copyWith(language: 'ru'));
          },
        ),
      ],
    );
  }

  void _showLayoutPicker(BuildContext context, WidgetRef ref) {
    final preset = ref.read(themeProvider).activePreset;
    showChatLayoutPicker(
      context,
      current: preset.chatLayout,
      onSelect: (layout) => ref
          .read(themeProvider.notifier)
          .updatePreset(preset.copyWith(chatLayout: layout)),
    );
  }
}
