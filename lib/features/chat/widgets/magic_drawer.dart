import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/platform/haptics.dart';
import '../../../core/services/chat_import_export.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../features/settings/app_settings_provider.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/chat_session_ops_provider.dart';
import '../../../core/state/studio_feature_provider.dart';
import '../../../core/state/summary_providers.dart';
import '../../../features/chat_history/chat_history_provider.dart';
import '../../../shared/utils/time_formatter.dart';
import '../../../shared/theme/app_colors.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../image_gen/widgets/image_gen_sheet.dart';
import '../chat_actions_service.dart';
import '../chat_provider.dart';
import '../../character_list/character_detail_screen.dart';
import '../../lorebooks/lorebook_list_screen.dart';
import '../../personas/persona_list_screen.dart';
import '../../presets/preset_list_screen.dart';
import '../../regex/regex_sheet.dart';
import '../../settings/api_settings_screen.dart';
import 'authors_note_sheet.dart';
import 'agentic_operations_log_dialog.dart';
import 'drawer_panel_scaffold.dart';
import 'magic_drawer_models.dart';
import '../services/magic_drawer_layout_service.dart';
import '../services/magic_drawer_stats_service.dart';
import 'magic_drawer_widgets.dart';
import 'memory_books_sheet.dart';
import 'studio_settings_sheet.dart';
import 'prompt_inspector_sheet.dart';
import 'summary_sheet.dart';
import '../state/token_breakdown_cache.dart';
import '../../glossary/glossary_sheet.dart';
import '../../extensions/models/extension_preset.dart';
import '../../extensions/models/extensions_settings.dart';
import '../../extensions/providers/extension_presets_provider.dart';
import '../../extensions/providers/extensions_settings_provider.dart';
import '../../extensions/widgets/ext_blocks_settings_sheet.dart';

class MagicDrawerPanel extends ConsumerStatefulWidget {
  final String charId;
  final bool disableEffects;

  /// Called when the drawer wants to dismiss itself: on a swipe-down of the
  /// drag handle, or before a picked item performs real navigation away from
  /// the chat (e.g. character edit -> go route). Sheets and dialogs open on
  /// top of the panel and leave it open underneath. The host owns visibility,
  /// so we ask it to hide us instead of popping a route.
  final VoidCallback? onClose;

  /// Scroll the chat webview to a message id (used by Ledger diagnostics
  /// "source-message navigation"). Null when the chat webview is not
  /// available (e.g. panel opened from a non-chat context).
  final Future<void> Function(String messageId)? onScrollToMessage;

  const MagicDrawerPanel({
    super.key,
    required this.charId,
    this.onClose,
    this.disableEffects = false,
    this.onScrollToMessage,
  });

  @override
  ConsumerState<MagicDrawerPanel> createState() => _MagicDrawerPanelState();
}

class _MagicDrawerPanelState extends ConsumerState<MagicDrawerPanel> {
  static final _allItems = <MagicDrawerItemDef>[
    MagicDrawerItemDef(
      id: 'inspector',
      label: 'Prompt Inspector',
      icon: Icons.travel_explore,
      category: MagicDrawerCategory.tools,
    ),
    MagicDrawerItemDef(
      id: 'summary',
      label: 'summary_title'.tr(),
      icon: Icons.subject,
      category: MagicDrawerCategory.session,
    ),
    MagicDrawerItemDef(
      id: 'sessions',
      label: 'history_title'.tr(),
      icon: Icons.history,
      category: MagicDrawerCategory.session,
    ),
    MagicDrawerItemDef(
      id: 'char-card',
      label: 'menu_characters'.tr(),
      icon: Icons.account_box,
      category: MagicDrawerCategory.library,
    ),
    MagicDrawerItemDef(
      id: 'lorebooks',
      label: 'label_lorebooks'.tr(),
      icon: Icons.library_books,
      category: MagicDrawerCategory.library,
    ),
    MagicDrawerItemDef(
      id: 'memory-books',
      label: 'magic_memory_books'.tr(),
      icon: Icons.add_box,
      category: MagicDrawerCategory.session,
    ),
    MagicDrawerItemDef(
      id: 'regex',
      label: 'menu_regex'.tr(),
      icon: Icons.code,
      category: MagicDrawerCategory.config,
    ),
    MagicDrawerItemDef(
      id: 'api',
      label: 'tab_api'.tr(),
      icon: Icons.cloud,
      category: MagicDrawerCategory.config,
    ),
    MagicDrawerItemDef(
      id: 'presets',
      label: 'tab_presets'.tr(),
      icon: Icons.description,
      category: MagicDrawerCategory.config,
    ),
    MagicDrawerItemDef(
      id: 'personas',
      label: 'menu_personas'.tr(),
      icon: Icons.manage_accounts,
      category: MagicDrawerCategory.library,
    ),
    MagicDrawerItemDef(
      id: 'image-gen',
      label: 'imggen_title'.tr(),
      icon: Icons.image,
      category: MagicDrawerCategory.tools,
    ),
    MagicDrawerItemDef(
      id: 'authors-note',
      label: 'magic_authors_notes'.tr(),
      icon: Icons.edit_note,
      category: MagicDrawerCategory.session,
    ),
    MagicDrawerItemDef(
      id: 'glossary',
      label: 'menu_glossary'.tr(),
      icon: Icons.menu_book,
      category: MagicDrawerCategory.library,
    ),
    MagicDrawerItemDef(
      id: 'ext-blocks',
      label: 'Ext Blocks',
      icon: Icons.extension_outlined,
      category: MagicDrawerCategory.config,
    ),
    MagicDrawerItemDef(
      id: 'studio',
      label: 'menu_studio'.tr(),
      icon: Icons.movie_filter_outlined,
      category: MagicDrawerCategory.tools,
    ),
    MagicDrawerItemDef(
      id: 'agent-ops',
      label: 'Agentic Ops',
      icon: Icons.smart_toy_outlined,
      category: MagicDrawerCategory.tools,
    ),
  ];

  final List<String> _itemIds = [];
  final Set<String> _deletedIds = {};
  bool _editing = false;
  bool _loading = true;
  bool _loadingTokens = false;
  int? _draggingIndex;
  int? _hoverIndex;
  MagicDrawerStats _stats = const MagicDrawerStats();
  int _statsRequest = 0;
  Timer? _debounceTimer;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadDrawer();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDrawer() async {
    try {
      await _loadLayout();
      await _loadStats();
    } catch (e) {
      debugPrint('[MagicDrawer] _loadDrawer error: $e');
    }
    if (mounted) {
      setState(() => _loading = false);
    }
    // Defer token stats calculation until after UI render completes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleTokenStats();
    });
  }

  Future<void> _loadLayout() async {
    final layout = await MagicDrawerLayoutService(ref).loadLayout(_allItems);
    _deletedIds
      ..clear()
      ..addAll(layout.deletedIds);
    _itemIds
      ..clear()
      ..addAll(layout.itemIds);
  }

  Future<void> _saveLayout() async {
    await MagicDrawerLayoutService(ref).saveLayout(_itemIds, _deletedIds);
  }

  Future<void> _loadStats() async {
    final request = ++_statsRequest;
    final stats = await MagicDrawerStatsService(
      ref,
    ).computeStats(widget.charId);
    if (request == _statsRequest) _stats = stats;
  }

  void _scheduleTokenStats() {
    if (!mounted) return;
    _debounceTimer?.cancel();
    final delay = ref.read(appSettingsProvider).value?.batterySaver == true
        ? const Duration(milliseconds: 700)
        : const Duration(milliseconds: 300);
    _debounceTimer = Timer(delay, _loadTokenStats);
  }

  Future<void> _loadTokenStats() async {
    if (!mounted) return;
    setState(() => _loadingTokens = true);
    final request = _statsRequest;
    MagicDrawerStats updated;
    try {
      updated = await MagicDrawerStatsService(
        ref,
      ).computeTokenStats(widget.charId, _stats);
    } catch (e) {
      debugPrint('[MagicDrawer] _loadTokenStats error: $e');
      return;
    }
    if (!mounted || request != _statsRequest) return;
    setState(() {
      _stats = updated;
      _loadingTokens = false;
    });
  }

  /// Lightweight refresh: only stats, no layout re-read from disk.
  /// Called by the debounce timer when messages change.
  Future<void> _refreshStats() async {
    TokenBreakdownCache.invalidate();
    try {
      await _loadStats();
    } catch (e) {
      debugPrint('[MagicDrawer] _refreshStats error: $e');
    }
    if (!mounted) return;
    setState(() {});
    _scheduleTokenStats();
  }

  void _scheduleRefresh() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), _refreshStats);
  }

  List<MagicDrawerCardItem> _displayItems(
    ExtensionsSettings extSettings,
    List<ExtensionPreset> extPresets,
    bool studioFeatureEnabled,
  ) {
    final list = _itemIds
        .map((id) => _allItems.where((item) => item.id == id).firstOrNull)
        .whereType<MagicDrawerItemDef>()
        .where(
          (def) => _featureVisible(def.id, extSettings, studioFeatureEnabled),
        )
        .map(
          (def) => MagicDrawerCardItem(
            def: def,
            status: _statusFor(def.id, extSettings, extPresets),
          ),
        )
        .toList();
    return list;
  }

  /// Feature-gated cards are hidden from Quick Access and the "Add Action"
  /// (Tools) list unless their Experimental Features master switch is on.
  /// Ungated items are always visible.
  bool _featureVisible(
    String id,
    ExtensionsSettings extSettings,
    bool studioFeatureEnabled,
  ) {
    return switch (id) {
      'ext-blocks' => extSettings.enabled,
      'studio' => studioFeatureEnabled,
      _ => true,
    };
  }

  bool _canAddMore(ExtensionsSettings extSettings, bool studioFeatureEnabled) =>
      _allItems.any(
        (item) =>
            !_itemIds.contains(item.id) &&
            _featureVisible(item.id, extSettings, studioFeatureEnabled),
      );

  String? _statusFor(
    String id,
    ExtensionsSettings extSettings,
    List<ExtensionPreset> extPresets,
  ) {
    return switch (id) {
      'inspector' =>
        _stats.promptTokens > 0 && _stats.contextSize > 0
            ? '${_stats.promptTokens}/${_stats.contextSize} tokens'
            : _loadingTokens && _stats.approximateHistoryTokens > 0
            ? '~${_stats.approximateHistoryTokens}/${_stats.contextSize} tokens'
            : _loadingTokens
            ? 'Calculating...'
            : null,
      'summary' =>
        _stats.summaryChars > 0
            ? '${_stats.summaryChars} chars'
            : 'Not generated',
      'sessions' => '${_stats.sessionCount} sessions',
      'char-card' =>
        _stats.characterTokens > 0
            ? '${_stats.characterTokens} tokens'
            : _stats.character?.name,
      'lorebooks' => '${_stats.lorebookEntryCount} entries',
      'memory-books' => '${_stats.memoryEntryCount} entries',
      'regex' => '${_stats.regexCount} scripts',
      'api' =>
        _stats.apiConfig?.name.isNotEmpty == true
            ? _stats.apiConfig!.name
            : _stats.apiConfig?.model,
      'presets' =>
        _stats.activePreset == null
            ? 'label_default'.tr()
            : _stats.presetTokens > 0
            ? '${_stats.activePreset!.name} • ${_stats.presetTokens} tokens'
            : _stats.activePreset!.name,
      'personas' => _stats.activePersona?.name ?? 'label_default'.tr(),
      'image-gen' => _stats.imageGenEnabled ? 'on'.tr() : 'off'.tr(),
      'authors-note' =>
        _stats.session?.authorsNote != null &&
                _stats.session!.authorsNote!.content.isNotEmpty
            ? '${_stats.session!.authorsNote!.content.length} chars'
            : 'placeholder_empty'.tr(),
      'ext-blocks' =>
        !extSettings.enabled
            ? 'off'.tr()
            : extSettings.activePresetId == null
            ? 'No preset'
            : extPresets
                      .where((p) => p.id == extSettings.activePresetId)
                      .firstOrNull
                      ?.name ??
                  'No preset',
      _ => null,
    };
  }

  void _toggleEditing() {
    setState(() => _editing = !_editing);
  }

  Future<void> _removeItem(String id) async {
    setState(() {
      _itemIds.remove(id);
      _deletedIds.add(id);
    });
    await _saveLayout();
  }

  Future<void> _moveItem(int from, int to) async {
    if (from == to ||
        from < 0 ||
        to < 0 ||
        from >= _itemIds.length ||
        to >= _itemIds.length) {
      return;
    }
    setState(() {
      final item = _itemIds.removeAt(from);
      _itemIds.insert(to, item);
      _hoverIndex = null;
    });
    await _saveLayout();
  }

  Future<void> _showAddItemSheet() async {
    final extSettings = ref.read(extensionsSettingsProvider);
    final studioFeatureEnabled = ref.read(studioFeatureEnabledProvider);
    final available = _allItems
        .where((item) => !_itemIds.contains(item.id))
        .where(
          (item) => _featureVisible(item.id, extSettings, studioFeatureEnabled),
        )
        .toList();
    if (available.isEmpty) return;

    await GlazeBottomSheet.show<MagicDrawerItemDef>(
      context,
      title: 'Add Action',
      child: MagicDrawerAddList(
        items: available,
        onSelect: (item) =>
            Navigator.of(context, rootNavigator: true).pop(item),
      ),
    ).then((selected) async {
      if (selected == null || !mounted) return;
      setState(() {
        _itemIds.add(selected.id);
        _deletedIds.remove(selected.id);
      });
      await _saveLayout();
    });
  }

  Future<void> _handleTap(MagicDrawerItemDef item) async {
    if (_editing) return;

    try {
      switch (item.id) {
        case 'inspector':
          await showPromptInspectorSheet(context, widget.charId);
          break;
        case 'summary':
          await showSummarySheet(context, widget.charId);
          break;
        case 'sessions':
          await _showSessionsSheet();
          break;
        case 'char-card':
          final result = await showModalBottomSheet<String>(
            context: context,
            isScrollControlled: true,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            builder: (_) => CharacterDetailScreen(charId: widget.charId),
          );
          if (result != null && result.isNotEmpty && mounted) {
            // Real navigation away from the chat - close the panel first.
            widget.onClose?.call();
            context.go(result);
          }
          break;
        case 'lorebooks':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black54,
            isScrollControlled: true,
            builder: (_) => const LorebookListScreen(),
          );
          break;
        case 'memory-books':
          await _showMemoryBooks();
          break;
        case 'regex':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black54,
            isScrollControlled: true,
            builder: (_) => const RegexSheet(),
          );
          break;
        case 'api':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black54,
            isScrollControlled: true,
            builder: (_) => const ApiSettingsScreen(),
          );
          break;
        case 'presets':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black54,
            isScrollControlled: true,
            builder: (_) => PresetListScreen(charId: widget.charId),
          );
          break;
        case 'personas':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => const PersonaListScreen(),
          );
          break;
        case 'image-gen':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => ImageGenSheet(charId: widget.charId),
          );
          break;
        case 'authors-note':
          await showAuthorsNoteSheet(context, widget.charId);
          break;
        case 'glossary':
          await GlossarySheet.show(context);
          break;
        case 'ext-blocks':
          await _showExtBlocksSheet();
          break;
        case 'studio':
          await _showStudioMenu();
          break;
        case 'agent-ops':
          await _showAgentOpsLog();
          break;
      }
    } finally {
      if (mounted) await _refreshStats();
    }
  }

  Future<void> _showStudioMenu() async {
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    if (session == null) return;
    await StudioSettingsSheet.show(
      context,
      charId: widget.charId,
      sessionId: session.id,
    );
  }

  Future<void> _showAgentOpsLog() async {
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    await AgenticOperationsLogDialog.show(context, sessionId: session?.id);
  }

  Future<void> _showExtBlocksSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: context.cs.surfaceContainerHigh,
      isScrollControlled: true,
      builder: (_) => const ExtBlocksSettingsSheet(),
    );
  }

  Future<void> _showMemoryBooks() async {
    final chatState = ref.read(chatProvider(widget.charId)).value;
    final session = chatState?.session;
    if (session == null) return;
    await GlazeBottomSheet.show<void>(
      context,
      child: MemoryBooksSheet(
        sessionId: session.id,
        charId: widget.charId,
        messages: session.messages,
      ),
    );
  }

  Future<void> _showSessionsSheet() async {
    final currentSession = ref.read(chatProvider(widget.charId)).value?.session;
    if (currentSession == null) return;

    if (!mounted) return;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'history_title'.tr(),
      headerAction: IconButton(
        icon: Icon(Icons.add, color: context.cs.primary),
        onPressed: _showSessionAddMenu,
      ),
      child: _SessionsSheetContent(
        charId: widget.charId,
        onSessionActions: _showSessionActions,
      ),
    );
  }

  void _showSessionAddMenu() {
    GlazeBottomSheet.show<String>(
      context,
      title: 'action_new_session'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.add_circle_outline,
          label: 'action_new_session'.tr(),
          onTap: () => Navigator.of(context, rootNavigator: true).pop('new'),
        ),
        BottomSheetItem(
          icon: Icons.file_download,
          label: 'Import Chat',
          onTap: () => Navigator.of(context, rootNavigator: true).pop('import'),
        ),
      ],
    ).then((result) async {
      if (!mounted) return;
      if (result == 'new') {
        Navigator.of(context, rootNavigator: true).pop(); // Pops Sessions Sheet
        await ref.read(chatProvider(widget.charId).notifier).newSession();
      } else if (result == 'import') {
        await _importChat();
      }
    });
  }

  void _showSessionActions(String sessionId) {
    GlazeBottomSheet.show<String>(
      context,
      title: 'Session',
      items: [
        BottomSheetItem(
          icon: Icons.upload_file,
          label: 'action_export_chat'.tr(),
          onTap: () => Navigator.of(context, rootNavigator: true).pop('export'),
        ),
        BottomSheetItem(
          icon: Icons.drive_file_rename_outline,
          label: 'action_rename'.tr(),
          onTap: () => Navigator.of(context, rootNavigator: true).pop('rename'),
        ),
        BottomSheetItem(
          icon: Icons.delete_outline,
          label: 'action_delete'.tr(),
          isDestructive: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop('delete'),
        ),
      ],
    ).then((result) async {
      if (!mounted) return;
      switch (result) {
        case 'export':
          await ref
              .read(chatActionsServiceProvider)
              .exportSessionUI(
                context,
                charId: widget.charId,
                sessionId: sessionId,
              );
        case 'rename':
          await _showRenameDialog(sessionId);
        case 'delete':
          await ref.read(chatHistoryProvider.notifier).deleteSession(sessionId);
          ref.invalidate(chatProvider(widget.charId));
      }
    });
  }

  Future<void> _showRenameDialog(String sessionId) async {
    final session = await ref
        .read(chatSessionOpsProvider.notifier)
        .getSession(sessionId);
    if (!mounted || session == null) return;
    final currentName = session.sessionVars['sessionName']?.isNotEmpty == true
        ? session.sessionVars['sessionName']!
        : 'Session #${session.sessionIndex + 1}';
    await GlazeBottomSheet.show<void>(
      context,
      title: 'Rename Session',
      input: BottomSheetInput(
        placeholder: 'Session name',
        value: currentName,
        confirmLabel: 'action_rename'.tr(),
        onConfirm: (val) async {
          Navigator.of(context, rootNavigator: true).pop();
          if (val.trim().isNotEmpty) {
            await ref
                .read(chatHistoryProvider.notifier)
                .renameSession(sessionId, val.trim());
            ref.invalidate(chatProvider(widget.charId));
          }
        },
      ),
    );
  }

  Future<void> _importChat() async {
    final result = await FilePicker.pickFiles(
      type: Platform.isIOS ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isIOS ? null : ['jsonl', 'json'],
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final filePath = file.path;
    try {
      ChatImportSaveResult saveResult;
      if (file.bytes != null) {
        final importResult = importChatFromJsonlString(
          utf8.decode(file.bytes!),
        );
        saveResult = await ref
            .read(chatActionsServiceProvider)
            .importChatFromResult(widget.charId, importResult);
      } else if (filePath != null) {
        saveResult = await ref
            .read(chatActionsServiceProvider)
            .importChat(widget.charId, filePath);
      } else {
        return;
      }
      if (!mounted) return;
      final count = saveResult.count;
      final sessionIndex = saveResult.sessionIndex;
      if (count > 0 && sessionIndex != null) {
        // Pop the sessions sheet if import succeeds
        Navigator.of(context, rootNavigator: true).pop();
        context.go('/chat/${widget.charId}?session=$sessionIndex');
      }
      GlazeToast.show(
        context,
        count == 0 ? 'No messages found in file' : 'Imported $count messages',
      );
    } catch (e) {
      if (mounted) GlazeErrorDialog.show(context, e, prefix: 'Import failed: ');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatProvider(widget.charId), (prev, next) {
      final prevSession = prev?.value?.session;
      final nextSession = next.value?.session;
      if (prevSession?.id != nextSession?.id ||
          prevSession?.messages.length != nextSession?.messages.length ||
          prevSession?.messages.lastOrNull?.content !=
              nextSession?.messages.lastOrNull?.content) {
        _scheduleRefresh();
      }
    });
    ref.listen(activePresetIdProvider, (prev, next) {
      if (prev != next) _scheduleRefresh();
    });
    // Summary is written straight to its repo (not through chatProvider), so
    // refresh the card when it changes.
    ref.listen(summaryRevisionProvider, (prev, next) {
      if (prev != next) _scheduleRefresh();
    });
    ref.listen(activePersonaIdProvider, (prev, next) {
      if (prev != next) _scheduleRefresh();
    });
    ref.listen(lorebookActivationsProvider, (prev, next) {
      if (prev != next) _scheduleRefresh();
    });
    ref.listen(extensionsSettingsProvider, (prev, next) {
      if (prev == null) {
        _scheduleRefresh();
        return;
      }
      if (prev.enabled != next.enabled ||
          prev.activePresetId != next.activePresetId) {
        _scheduleRefresh();
      }
    });
    ref.listen(extensionPresetsProvider, (prev, next) {
      // Active preset name may have changed (renamed/edited).
      final pl = prev ?? const [];
      if (pl.length != next.length) {
        _scheduleRefresh();
      } else {
        for (int i = 0; i < pl.length; i++) {
          if (pl[i].name != next[i].name) {
            _scheduleRefresh();
            break;
          }
        }
      }
    });

    final extSettings = ref.watch(extensionsSettingsProvider);
    final extPresets = ref.watch(extensionPresetsProvider);
    final studioFeatureEnabled = ref.watch(studioFeatureEnabledProvider);
    final items = _displayItems(extSettings, extPresets, studioFeatureEnabled);
    final batterySaver =
        ref.watch(appSettingsProvider).value?.batterySaver ?? false;

    final scrollable = RawScrollbar(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 60),
      thickness: 3,
      radius: const Radius.circular(3),
      thumbColor: Colors.white24,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = (constraints.maxWidth - 24 - 12) / 3;
            return SingleChildScrollView(
              controller: _scrollController,
              padding: EdgeInsets.fromLTRB(
                12,
                60,
                12,
                16 + MediaQuery.of(context).padding.bottom,
              ),
              child: MagicCardGrid(
                columns: 3,
                cells: List.generate(items.length, (index) {
                  final item = items[index];
                  final card = MagicCard(
                    item: item,
                    editing: _editing,
                    hovered: _hoverIndex == index && _draggingIndex != index,
                    onTap: () => _handleTap(item.def),
                    onDelete: () => _removeItem(item.def.id),
                  );

                  return SizedBox(
                    width: itemWidth,
                    child: DragTarget<int>(
                      onWillAcceptWithDetails: (details) {
                        setState(() => _hoverIndex = index);
                        return details.data != index;
                      },
                      onLeave: (_) {
                        if (_hoverIndex == index) {
                          setState(() => _hoverIndex = null);
                        }
                      },
                      onAcceptWithDetails: (details) {
                        _moveItem(details.data, index);
                      },
                      builder: (context, _, _) {
                        return LongPressDraggable<int>(
                          data: index,
                          delay: const Duration(milliseconds: 300),
                          onDragStarted: () {
                            Haptics.mediumImpact();
                            setState(() {
                              if (!_editing) _editing = true;
                              _draggingIndex = index;
                            });
                          },
                          onDragEnd: (_) {
                            setState(() {
                              _draggingIndex = null;
                              _hoverIndex = null;
                            });
                          },
                          feedback: SizedBox(
                            width: itemWidth,
                            child: Material(
                              color: Colors.transparent,
                              child: Opacity(opacity: 0.92, child: card),
                            ),
                          ),
                          childWhenDragging: Opacity(
                            opacity: 0.25,
                            child: card,
                          ),
                          child: card,
                        );
                      },
                    ),
                  );
                }),
              ),
            );
          },
        ),
      ),
    );

    return DrawerPanelScaffold(
      disableEffects: batterySaver || widget.disableEffects,
      loading: _loading,
      onDismiss: widget.onClose,
      header: MagicDrawerHeader(
        editing: _editing,
        onToggleEditing: _toggleEditing,
        onAdd: _canAddMore(extSettings, studioFeatureEnabled)
            ? _showAddItemSheet
            : null,
      ),
      content: scrollable,
    );
  }
}

class _SessionsSheetContent extends ConsumerStatefulWidget {
  final String charId;
  final void Function(String) onSessionActions;

  const _SessionsSheetContent({
    required this.charId,
    required this.onSessionActions,
  });

  @override
  ConsumerState<_SessionsSheetContent> createState() =>
      _SessionsSheetContentState();
}

class _SessionsSheetContentState extends ConsumerState<_SessionsSheetContent> {
  List<ChatSession> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await ref
        .read(chatProvider(widget.charId).notifier)
        .getSessions();
    // Most-recent activity first — branch/creation counts as activity, so a
    // freshly branched or created chat sorts to the top even before any
    // message is sent.
    sessions.sort((a, b) => b.lastActivityMs.compareTo(a.lastActivityMs));
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    }
  }

  /// Preview line for a session: the origin event ("Created on …" /
  /// "Branched on …") while it is the most recent thing to have happened,
  /// otherwise the last message content.
  String _sessionPreview(ChatSession session) {
    final origin = session.originEvent;
    final lastTs = session.messages.isNotEmpty
        ? session.messages.last.timestamp
        : null;
    if (origin != null && (lastTs == null || origin.timestampMs >= lastTs)) {
      final kind = origin.kind == ChatOriginKind.branched
          ? 'branched'
          : 'created';
      return formatOriginPreview(kind, origin.timestampMs);
    }
    return session.messages.lastOrNull?.content ?? 'No messages yet';
  }

  String _formatRelativeTime(int updatedAtSeconds) {
    return formatRelativeTimeFromSeconds(updatedAtSeconds);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatProvider(widget.charId), (prev, next) {
      _load();
    });

    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final currentSession = ref
        .watch(chatProvider(widget.charId))
        .value
        ?.session;
    final currentSessionId = currentSession?.id;

    return GlazeSessionList(
      items: _sessions
          .map(
            (session) => BottomSheetSessionItem(
              title: session.sessionVars['sessionName']?.isNotEmpty == true
                  ? session.sessionVars['sessionName']!
                  : 'session_name'.tr(
                      namedArgs: {'id': (session.sessionIndex + 1).toString()},
                    ),
              count: session.messages.length,
              time: session.lastActivityMs == 0
                  ? ''
                  : _formatRelativeTime(session.lastActivityMs ~/ 1000),
              preview: _sessionPreview(session),
              isActive: session.id == currentSessionId,
              onTap: () {
                Navigator.of(context).pop();
                if (session.sessionIndex != currentSession?.sessionIndex) {
                  ref
                      .read(chatProvider(widget.charId).notifier)
                      .switchSession(session.sessionIndex);
                }
              },
              onMore: () {
                widget.onSessionActions(session.id);
              },
            ),
          )
          .toList(),
    );
  }
}
