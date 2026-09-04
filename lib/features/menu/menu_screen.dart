import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../shared/shell/desktop/desktop_glossary_popup.dart';
import '../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../core/models/chat_message.dart';
import '../chat/widgets/triggered_items_sheet.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../core/services/generation_notification_service.dart';
import '../../core/state/dev_mode_provider.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/shell/nav_retap_provider.dart';
import '../../shared/shell/shell_header_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/menu_group.dart';
import '../catalog/widgets/janitor_extract_sheet.dart';
import '../catalog/widgets/third_party_providers_screen.dart';
import '../dev/menu_group_demo_screen.dart';
import '../dev/spinner_demo_screen.dart';
import '../lorebooks/lorebook_connections_sheet.dart';
import '../personas/persona_connections_sheet.dart';
import '../personas/persona_list_provider.dart';
import '../presets/preset_connections_sheet.dart';
import '../presets/preset_list_provider.dart';
import '../../core/state/lorebook_provider.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../settings/app_settings_provider.dart';
import 'menu_actions.dart';
import 'search/menu_search_entry.dart';
import 'search/menu_search_index.dart';
import 'search/menu_search_results.dart';
import 'update_dialog.dart';
import '../../core/services/update_check_service.dart';

class MenuScreen extends ConsumerStatefulWidget {
  const MenuScreen({super.key});

  @override
  ConsumerState<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends ConsumerState<MenuScreen> with ShellHeaderMixin {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _searchScrollController = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  bool _searchExpanded = false;
  String _searchQuery = '';

  @override
  int get headerBranchIndex => 3;

  @override
  ShellHeaderConfig buildShellHeader() => ShellHeaderConfig(
    title: _searchExpanded ? null : 'menu_menu_title'.tr(),
    titleWidget: _searchExpanded ? _buildSearchField(context) : null,
    actions: [
      SizedBox(
        width: 44,
        height: 44,
        child: IconButton(
          icon: Icon(
            _searchExpanded ? Icons.close_rounded : Icons.search_rounded,
            size: 22,
          ),
          color: context.cs.primary,
          onPressed: _searchExpanded ? _closeSearch : _openSearch,
        ),
      ),
    ],
  );

  @override
  void dispose() {
    _scrollController.dispose();
    _searchScrollController.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searchExpanded = true);
    refreshShellHeader();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  void _closeSearch() {
    _searchCtrl.clear();
    setState(() {
      _searchExpanded = false;
      _searchQuery = '';
    });
    refreshShellHeader();
  }

  Widget _buildSearchField(BuildContext context) => TextField(
    controller: _searchCtrl,
    focusNode: _searchFocus,
    autofocus: true,
    onChanged: (value) => setState(() => _searchQuery = value),
    textInputAction: TextInputAction.search,
    cursorColor: context.cs.primary,
    style: TextStyle(color: context.cs.onSurface, fontSize: 16),
    decoration: InputDecoration(
      isDense: true,
      border: InputBorder.none,
      hintText: 'menu_search_hint'.tr(),
      hintStyle: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 16),
    ),
  );

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

  /// Posts a message notification on demand and reports what the OS did with
  /// it. Delivery depends on platform state the app cannot read back — a
  /// revoked permission, a drawable the notification plugin cannot resolve, a
  /// channel the user silenced — and every one of those failures is otherwise
  /// invisible: the reply simply arrives with no notification and no error.
  Future<void> _sendTestNotification() async {
    final service = GenerationNotificationService.instance;
    if (!service.notificationsSupported) {
      GlazeToast.show(context, 'notification_test_unsupported'.tr());
      return;
    }

    final enabled = await service.areNotificationsEnabled();
    if (!mounted) return;
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
    if (!mounted) return;
    if (sent) {
      GlazeToast.show(
        context,
        'notification_test_sent'.tr(
          args: [service.lastDeliveredNotificationForm ?? '—'],
        ),
      );
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
    // No shell header above us inside the desktop floating window, so nothing
    // to reserve room for.
    final topPad = DetachedShellHost.of(context)
        ? 0.0
        : MediaQuery.of(context).padding.top + 66.0;
    final lang = ref.watch(appSettingsProvider).value?.language ?? 'en';

    // Re-tap on the active Menu navbar tab → drop out of search, then scroll to
    // top (sub-routes are already popped by the shell's
    // goBranch(initialLocation: true)).
    ref.listen(navReTapProvider, (_, next) {
      if (next.branchIndex != kMenuBranchIndex) return;
      if (_searchExpanded) {
        _closeSearch();
      } else {
        _scrollToTop();
      }
    });

    final listPadding = EdgeInsets.only(
      top: topPad + 8,
      bottom: navHeight + 20,
    );

    if (_searchQuery.trim().isNotEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: MenuSearchResults(
          controller: _searchScrollController,
          padding: listPadding,
          results: filterMenuSearchEntries(
            buildMenuSearchIndex(),
            _searchQuery,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          ListView(
            controller: _scrollController,
            padding: listPadding,
            children: [
              MenuGroup(
                header: 'section_settings'.tr(),
                headerIcon: Icons.settings_rounded,
                items: [
                  MenuItem(
                    icon: Icons.settings_outlined,
                    label: 'menu_app_settings'.tr(),
                    subtitle: 'menu_app_settings_hint'.tr(),
                    onTap: () =>
                        goOrFloat(context, ref, 'settings', push: true),
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
                    onTap: () => isDesktopLayout(context)
                        ? goOrFloat(context, ref, 'backup', push: true)
                        : openBackupsSheet(context),
                  ),
                  MenuItem(
                    icon: Icons.sync_rounded,
                    label: 'menu_cloud_sync'.tr(),
                    subtitle: 'menu_cloud_sync_hint'.tr(),
                    onTap: () => isDesktopLayout(context)
                        ? goOrFloat(context, ref, 'sync', push: true)
                        : openCloudSyncSheet(context),
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
                      onChanged: (v) =>
                          ref.read(hideBuildWatermarkProvider.notifier).set(v),
                    ),
                    MenuItem(
                      icon: Icons.widgets_outlined,
                      label: 'menu_menu_group_demo'.tr(),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const MenuGroupDemoScreen(),
                        ),
                      ),
                    ),
                    MenuItem(
                      icon: Icons.refresh_rounded,
                      label: 'menu_spinner_demo'.tr(),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SpinnerDemoScreen(),
                        ),
                      ),
                    ),
                    MenuItem(
                      icon: Icons.notifications_active_outlined,
                      label: 'menu_notifications_test'.tr(),
                      onTap: _sendTestNotification,
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
                        id: ref.read(presetListProvider).value?.firstOrNull?.id,
                        emptyMsg: 'No presets to preview',
                        open: (id) => showPresetConnections(context, id),
                      ),
                    ),
                    MenuItem(
                      icon: Icons.menu_book_outlined,
                      label: 'Lorebook connections',
                      onTap: () => _openConnectionsTest(
                        id: ref.read(lorebooksProvider).value?.firstOrNull?.id,
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
                          dismissId: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
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
                    onTap: () => goOrFloat(context, ref, 'about', push: true),
                  ),
                  MenuItem(
                    icon: Icons.menu_book_rounded,
                    label: 'menu_glossary'.tr(),
                    subtitle: 'menu_glossary_hint'.tr(),
                    onTap: () {
                      if (!isDesktopLayout(context)) {
                        context.push('/menu/glossary');
                      } else if (ref.read(glossaryPopupVisibleProvider)) {
                        ref.read(glossaryPopupVisibleProvider.notifier).state =
                            false;
                      } else {
                        openGlossaryPopup(ref);
                      }
                    },
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
                    onTap: () => replayOnboarding(context),
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
