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
import '../../../core/state/lorebook_provider.dart';
import '../../../features/settings/app_settings_provider.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/studio_feature_provider.dart';
import '../../../core/state/summary_providers.dart';
import '../../../shared/theme/app_colors.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../image_gen/widgets/image_gen_sheet.dart';
import '../chat_actions_service.dart';
import '../chat_provider.dart';
import '../../card_rewrite/card_rewriter_studio_sheet.dart';
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
import 'memory_sheet.dart';
import 'prompt_inspector_sheet.dart';
import 'session_picker_sheet.dart';
import '../state/magic_drawer_stats_cache.dart';
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
      label: 'prompt_inspector_title'.tr(),
      icon: Icons.travel_explore,
      category: MagicDrawerCategory.tools,
    ),
    MagicDrawerItemDef(
      id: 'memory',
      label: 'Memory',
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
      id: 'agent-ops',
      label: 'agent_ops_title'.tr(),
      icon: Icons.smart_toy_outlined,
      category: MagicDrawerCategory.tools,
    ),
    MagicDrawerItemDef(
      id: 'card-rewriter',
      label: 'magic_card_rewriter'.tr(),
      icon: Icons.auto_fix_high_outlined,
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
  late final MagicDrawerStatsService _statsService;

  @override
  void initState() {
    super.initState();
    _statsService = MagicDrawerStatsService(ref);
    // Stale-while-revalidate. The panel is destroyed on every drawer close, so
    // without a cache each open would sit behind the spinner until a full
    // layout read and stats recomputation finished. Paint the previous
    // snapshot right away instead; _loadDrawer() refreshes it underneath.
    final cachedLayout = ref.read(magicDrawerLayoutCacheProvider);
    if (cachedLayout != null) {
      _itemIds.addAll(cachedLayout.itemIds);
      _deletedIds.addAll(cachedLayout.deletedIds);
    }
    final cachedStats = ref.read(magicDrawerStatsCacheProvider(widget.charId));
    if (cachedStats != null) _stats = cachedStats;
    // The spinner is now only for the first open of an app run, when there is
    // genuinely nothing to show.
    _loading = cachedLayout == null || cachedStats == null;
    _loadDrawer();
  }

  @override
  void dispose() {
    ++_statsRequest;
    _debounceTimer?.cancel();
    _statsService.dispose();
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
    if (mounted) _cacheLayout();
  }

  Future<void> _saveLayout() async {
    _cacheLayout();
    await MagicDrawerLayoutService(ref).saveLayout(_itemIds, _deletedIds);
  }

  /// Keeps the app-scoped layout cache in step with the local lists, so the
  /// next open starts from the order the user is looking at right now.
  void _cacheLayout() {
    ref.read(magicDrawerLayoutCacheProvider.notifier).state = (
      itemIds: List<String>.unmodifiable(_itemIds),
      deletedIds: Set<String>.unmodifiable(_deletedIds),
    );
  }

  Future<void> _loadStats() async {
    final request = ++_statsRequest;
    final stats = await _statsService.computeStats(widget.charId);
    if (request != _statsRequest) return;
    _stats = stats;
    // The drawer can be closed mid-load, which disposes this state and with it
    // `ref` — only touch the cache while still mounted.
    if (mounted) {
      ref.read(magicDrawerStatsCacheProvider(widget.charId).notifier).state =
          stats;
    }
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
      updated = await _statsService.computeTokenStats(widget.charId, _stats);
    } catch (e) {
      debugPrint('[MagicDrawer] _loadTokenStats error: $e');
      return;
    }
    if (!mounted || request != _statsRequest) return;
    ref.read(magicDrawerStatsCacheProvider(widget.charId).notifier).state =
        updated;
    setState(() {
      _stats = updated;
      _loadingTokens = false;
    });
  }

  /// Lightweight refresh: only stats, no layout re-read from disk.
  /// Called by the debounce timer when messages change.
  Future<void> _refreshStats() async {
    if (!mounted) return;
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
    if (!mounted) return;
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
      'memory' =>
        _stats.summaryChars > 0
            ? '${_stats.summaryChars} chars • ${_stats.memoryEntryCount} entries'
            : '${_stats.memoryEntryCount} entries',
      'sessions' => '${_stats.sessionCount} sessions',
      'char-card' =>
        _stats.characterTokens > 0
            ? '${_stats.characterTokens} tokens'
            : _stats.character?.name,
      'lorebooks' => '${_stats.lorebookEntryCount} entries',
      'regex' => '${_stats.regexCount} scripts',
      'api' =>
        _stats.apiConfig?.name.isNotEmpty == true
            ? _stats.apiConfig!.name
            : _stats.apiConfig?.model,
      'presets' =>
        _stats.activePresetDisplayName == null
            ? 'label_default'.tr()
            : _stats.presetTokens > 0
            ? '${_stats.activePresetDisplayName} • ${_stats.presetTokens} tokens'
            : _stats.activePresetDisplayName,
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
        case 'memory':
          await showMemorySheet(context, widget.charId);
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
        case 'agent-ops':
          await _showAgentOpsLog();
          break;
        case 'card-rewriter':
          await _showCardRewriter();
          break;
      }
    } finally {
      if (mounted) await _refreshStats();
    }
  }

  Future<void> _showCardRewriter() async {
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    if (session == null) return;
    final route = await CardRewriterStudioSheet.show(
      context,
      charId: widget.charId,
      sessionId: session.id,
    );
    if (!mounted) return;
    if (route != null && route.isNotEmpty) {
      widget.onClose?.call();
      context.go(route);
    }
  }

  Future<void> _showAgentOpsLog() async {
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    final route = await AgenticOperationsLogDialog.show(
      context,
      sessionId: session?.id,
      characterId: widget.charId,
    );
    if (!mounted) return;
    if (route != null && route.isNotEmpty) {
      widget.onClose?.call();
      context.go(route);
    }
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

  Future<void> _showSessionsSheet() async {
    final currentSession = ref.read(chatProvider(widget.charId)).value?.session;
    if (currentSession == null) return;

    if (!mounted) return;
    // The same picker the character catalog opens — see
    // `showSessionPickerSheet`. Only what a pick does differs: here it switches
    // the open chat in place instead of routing to it.
    final result = await showSessionPickerSheet(context, charId: widget.charId);
    if (result == null || !mounted) return;
    switch (result.action) {
      case SessionPickerAction.open:
        final target = result.session!.sessionIndex;
        final current = ref
            .read(chatProvider(widget.charId))
            .value
            ?.session
            ?.sessionIndex;
        if (target == current) return;
        try {
          await ref
              .read(chatProvider(widget.charId).notifier)
              .switchSession(target)
              .timeout(const Duration(seconds: 30));
        } catch (error) {
          if (mounted) {
            GlazeErrorDialog.show(
              context,
              error,
              prefix: 'Failed to switch chat session',
            );
          }
        }
      case SessionPickerAction.newSession:
        await ref.read(chatProvider(widget.charId).notifier).newSession();
      case SessionPickerAction.importChat:
        await _importChat();
    }
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
        // The sessions sheet has already resolved and closed itself by the
        // time this runs (`showSessionPickerSheet` pops with the picked
        // action), so there is nothing left here to pop.
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
    ref.listen(presetConnectionsProvider, (prev, next) {
      if (prev != next) _scheduleRefresh();
    });
    ref.listen(activeStudioPresetProvider, (prev, next) {
      if (prev?.value != next.value) _scheduleRefresh();
    });
    ref.listen(studioFeatureEnabledProvider, (prev, next) {
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
