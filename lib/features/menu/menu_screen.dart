import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/chat_message.dart';
import '../../core/services/onboarding_service.dart';
import '../chat/widgets/triggered_items_sheet.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../core/state/dev_mode_provider.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/shell/nav_retap_provider.dart';
import '../../shared/shell/shell_header_provider.dart';
import '../../shared/widgets/menu_group.dart';
import '../backup/backup_screen.dart';
import '../catalog/widgets/janitor_extract_sheet.dart';
import '../catalog/widgets/third_party_providers_screen.dart';
import '../cloud_sync/widgets/sync_sheet.dart';
import '../dev/menu_group_demo_screen.dart';
import '../lorebooks/lorebook_connections_sheet.dart';
import '../personas/persona_connections_sheet.dart';
import '../personas/persona_list_provider.dart';
import '../presets/preset_connections_sheet.dart';
import '../presets/preset_list_provider.dart';
import '../../core/state/lorebook_provider.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../settings/app_settings_provider.dart';
import 'update_dialog.dart';
import '../../core/services/update_check_service.dart';

class MenuScreen extends ConsumerStatefulWidget {
  const MenuScreen({super.key});

  @override
  ConsumerState<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends ConsumerState<MenuScreen> with ShellHeaderMixin {
  final ScrollController _scrollController = ScrollController();

  @override
  int get headerBranchIndex => 3;

  @override
  ShellHeaderConfig buildShellHeader() =>
      ShellHeaderConfig(title: 'menu_menu_title'.tr());

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Dev-only: opens a connections sheet for the first available entity so the
  /// shared connection-sheet widgets can be eyeballed. Toasts when the list is
  /// empty (nothing to bind against yet).
  void _openConnectionsTest({
    required String? id,
    required String emptyMsg,
    required void Function(String id) open,
  }) {
    if (id == null) {
      GlazeToast.show(context, emptyMsg);
      return;
    }
    open(id);
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Animates the menu list back to the top (guarded against a detached /
  /// multiply attached controller).
  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.positions.length != 1) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final navHeight = ref.watch(navHeightProvider);
    final topPad = MediaQuery.of(context).padding.top + 66.0;
    final lang = ref.watch(appSettingsProvider).value?.language ?? 'en';

    // Re-tap on the active Menu navbar tab → scroll to top (sub-routes are
    // already popped by the shell's goBranch(initialLocation: true)).
    ref.listen(navReTapProvider, (_, next) {
      if (next.branchIndex == kMenuBranchIndex) _scrollToTop();
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          ListView(
            controller: _scrollController,
            padding: EdgeInsets.only(
              top: topPad + 8,
              bottom: navHeight + 20,
            ),
            children: [
                MenuGroup(
                  header: 'section_settings'.tr(),
                  headerIcon: Icons.settings_rounded,
                  items: [
                    MenuItem(
                      icon: Icons.settings_outlined,
                      label: 'menu_app_settings'.tr(),
                      subtitle: 'menu_app_settings_hint'.tr(),
                      onTap: () => context.push('/menu/settings'),
                    ),
                    MenuItem(
                      icon: Icons.extension_outlined,
                      label: 'menu_third_party_providers'.tr(),
                      subtitle: 'menu_third_party_providers_hint'.tr(),
                      onTap: () => openThirdPartyProvidersScreen(context),
                    ),
                  ],
                ),
                MenuGroup(
                  header: 'section_data'.tr(),
                  headerIcon: Icons.storage_rounded,
                  items: [
                    MenuItem(
                      icon: Icons.backup_outlined,
                      label: 'menu_backups'.tr(),
                      subtitle: 'menu_backups_hint'.tr(),
                      onTap: () => showModalBottomSheet<void>(
                        context: context,
                        useRootNavigator: true,
                        useSafeArea: true,
                        backgroundColor: Colors.transparent,
                        barrierColor: Colors.black54,
                        isScrollControlled: true,
                        builder: (_) => const BackupScreen(),
                      ),
                    ),
                    MenuItem(
                      icon: Icons.sync_rounded,
                      label: 'menu_cloud_sync'.tr(),
                      subtitle: 'menu_cloud_sync_hint'.tr(),
                      onTap: () => showModalBottomSheet<void>(
                        context: context,
                        useRootNavigator: true,
                        useSafeArea: true,
                        backgroundColor: Colors.transparent,
                        barrierColor: Colors.black54,
                        isScrollControlled: true,
                        builder: (sheetContext) => Padding(
                          padding: EdgeInsets.only(
                            bottom: MediaQuery.viewPaddingOf(sheetContext).bottom,
                          ),
                          child: const SyncSheet(),
                        ),
                      ),
                    ),
                  ],
                ),
                if (ref.watch(devModeProvider))
                  MenuGroup(
                    header: 'menu_dev_header'.tr(),
                    headerIcon: Icons.developer_mode_rounded,
                    items: [
                      MenuSwitchItem(
                        label: 'menu_hide_build_date_watermark'.tr(),
                        value: ref.watch(hideBuildWatermarkProvider),
                        onChanged: (v) => ref
                            .read(hideBuildWatermarkProvider.notifier)
                            .set(v),
                      ),
                      MenuItem(
                        icon: Icons.widgets_outlined,
                        label: 'menu_menu_group_demo'.tr(),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const MenuGroupDemoScreen(),
                        )),
                      ),
                      const MenuSubHeader('Connections sheets'),
                      MenuItem(
                        icon: Icons.person_outline,
                        label: 'Persona connections',
                        onTap: () => _openConnectionsTest(
                          id: ref
                              .read(personaListProvider)
                              .value
                              ?.firstOrNull
                              ?.id,
                          emptyMsg: 'No personas to preview',
                          open: (id) => showPersonaConnections(context, id),
                        ),
                      ),
                      MenuItem(
                        icon: Icons.tune,
                        label: 'Preset connections',
                        onTap: () => _openConnectionsTest(
                          id: ref
                              .read(presetListProvider)
                              .value
                              ?.firstOrNull
                              ?.id,
                          emptyMsg: 'No presets to preview',
                          open: (id) => showPresetConnections(context, id),
                        ),
                      ),
                      MenuItem(
                        icon: Icons.menu_book_outlined,
                        label: 'Lorebook connections',
                        onTap: () => _openConnectionsTest(
                          id: ref
                              .read(lorebooksProvider)
                              .value
                              ?.firstOrNull
                              ?.id,
                          emptyMsg: 'No lorebooks to preview',
                          open: (id) => showLorebookConnections(context, id),
                        ),
                      ),
                      MenuItem(
                        icon: Icons.auto_stories_outlined,
                        label: 'Janitor: extract card + lorebook',
                        onTap: () => showJanitorExtractSheet(context),
                      ),
                      MenuItem(
                        icon: Icons.bookmarks_outlined,
                        label: 'Triggered Items Sheet',
                        onTap: () => showTriggeredItemsSheet(
                          context,
                          lorebooks: const [
                            TriggeredEntry(
                              id: 'lb1',
                              name: 'Kingdom of Eldoria',
                              lorebookName: 'World Lore',
                              source: 'keyword',
                            ),
                            TriggeredEntry(
                              id: 'lb2',
                              name: 'Ancient Prophecy',
                              lorebookName: 'World Lore',
                              source: 'vector',
                            ),
                          ],
                          memories: const [
                            TriggeredEntry(
                              id: 'mem1',
                              name: 'First meeting at the tavern',
                              source: 'memory',
                            ),
                          ],
                          regexes: const [
                            TriggeredEntry(
                              id: 'rx1',
                              name: 'Strip OOC blocks',
                              source: 'regex',
                              pattern: r'\(\(.*?\)\)',
                            ),
                            TriggeredEntry(
                              id: 'rx2',
                              name: 'Trim trailing whitespace',
                              source: 'regex',
                            ),
                          ],
                        ),
                      ),
                      MenuItem(
                        icon: Icons.warning_amber_rounded,
                        label: 'menu_test_error_dialog'.tr(),
                        onTap: () => GlazeErrorDialog.show(
                          context,
                          Exception(
                            'HTTP 401: Invalid API key\n\n'
                            'The request was rejected by the remote server. '
                            'Please verify that your API key is correct and has '
                            'not expired. Keys can be revoked from the provider '
                            'dashboard at any time without notice.\n\n'
                            'Endpoint:  https://api.openai.com/v1/chat/completions\n'
                            'Model:     gpt-4o\n'
                            'Status:    401 Unauthorized\n'
                            'Request:   POST /v1/chat/completions\n'
                            'Trace-ID:  req_abc123def456ghi789\n\n'
                            '{"error":{"message":"Incorrect API key provided: '
                            'sk-proj-...xXxX. You can find your API key at '
                            'https://platform.openai.com/account/api-keys.",'
                            '"type":"invalid_request_error","param":null,'
                            '"code":"invalid_api_key"}}',
                          ),
                        ),
                      ),
                      MenuItem(
                        icon: Icons.system_update_alt_rounded,
                        label: 'menu_test_update_dialog'.tr(),
                        onTap: () => showUpdateDialog(
                          context,
                          UpdateInfo(
                            source: UpdateSource.ciBuild,
                            dismissId:
                                'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
                            label: '#123',
                            createdAt: DateTime.now().toUtc(),
                            url: 'https://github.com/hydall/Glaze/actions',
                            notes: const [
                              'folders ux/ui',
                              'fix random character button',
                              'Fix extblock image generation races',
                              'tools screen expansion, chat list fix',
                              'Update Lucy pick card',
                            ],
                            totalNotes: 13,
                          ),
                        ),
                      ),
                      MenuItem(
                        icon: Icons.new_releases_outlined,
                        label: 'menu_test_update_dialog_release'.tr(),
                        onTap: () => showUpdateDialog(
                          context,
                          UpdateInfo(
                            source: UpdateSource.release,
                            dismissId: 'v0.8.0',
                            label: 'v0.8.0',
                            createdAt: DateTime.now().toUtc(),
                            url:
                                'https://github.com/hydall/Glaze/releases/latest',
                            notes: const [
                              'Memory book rework',
                              'Cloud sync conflict resolution',
                              'Studio agent presets',
                            ],
                            totalNotes: 3,
                          ),
                        ),
                      ),
                    ],
                  ),
                MenuGroup(
                  header: 'section_info'.tr(),
                  headerIcon: Icons.info_rounded,
                  items: [
                    MenuItem(
                      icon: Icons.info_outline_rounded,
                      label: 'menu_about'.tr(),
                      subtitle: 'menu_about_hint'.tr(),
                      onTap: () => context.push('/menu/about'),
                    ),
                    MenuItem(
                      icon: Icons.menu_book_rounded,
                      label: 'menu_glossary'.tr(),
                      subtitle: 'menu_glossary_hint'.tr(),
                      onTap: () => context.push('/menu/glossary'),
                    ),
                    if (lang == 'en')
                      MenuItem(
                        iconWidget: SvgPicture.asset(
                          'assets/logos/discord.svg',
                          colorFilter: const ColorFilter.mode(
                            Color(0xFF5865F2),
                            BlendMode.srcIn,
                          ),
                        ),
                        label: 'about_discord'.tr(),
                        subtitle: 'about_join_community'.tr(),
                        onTap: () => _openLink('https://discord.gg/jnGhd7p6Ht'),
                      )
                    else
                      MenuItem(
                        iconWidget: SvgPicture.asset(
                          'assets/logos/telegram.svg',
                          colorFilter: const ColorFilter.mode(
                            Color(0xFF2AABEE),
                            BlendMode.srcIn,
                          ),
                        ),
                        label: 'about_telegram'.tr(),
                        subtitle: 'about_join_community'.tr(),
                        onTap: () => _openLink('https://t.me/glazeapp'),
                      ),
                    MenuItem(
                      icon: Icons.replay_rounded,
                      label: 'onboarding_replay'.tr(),
                      subtitle: 'onboarding_replay_hint'.tr(),
                      onTap: () async {
                        await resetOnboarding();
                        if (context.mounted) showOnboarding(context);
                      },
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }
}
