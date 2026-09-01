import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/haptics.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../features/settings/app_settings_provider.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/studio_feature_provider.dart';
import '../../../core/state/summary_providers.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../chat_provider.dart';
import 'drawer_panel_scaffold.dart';
import 'magic_drawer_models.dart';
import '../services/magic_drawer_actions.dart';
import '../services/magic_drawer_layout_service.dart';
import '../services/magic_drawer_stats_service.dart';
import 'magic_drawer_widgets.dart';
import '../state/magic_drawer_stats_cache.dart';
import '../state/token_breakdown_cache.dart';
import '../../extensions/models/extension_preset.dart';
import '../../extensions/models/extensions_settings.dart';
import '../../extensions/providers/extension_presets_provider.dart';
import '../../extensions/providers/extensions_settings_provider.dart';

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
  /// Quick Access catalogue + dispatch, shared with the desktop sidebar
  /// strip — see [MagicDrawerActions].
  late final MagicDrawerActions _actions;

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
    _actions = MagicDrawerActions(
      charId: widget.charId,
      onClose: widget.onClose,
      onScrollToMessage: widget.onScrollToMessage,
    );
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
    final layout = await MagicDrawerLayoutService(
      ref,
    ).loadLayout(MagicDrawerActions.all);
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
        .map(
          (id) =>
              MagicDrawerActions.all.where((item) => item.id == id).firstOrNull,
        )
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
      MagicDrawerActions.all.any(
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
    final available = MagicDrawerActions.all
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
                    onTap: () => _editing
                        ? null
                        : _actions.handleTap(
                            context,
                            ref,
                            item.def,
                            onFinished: () async {
                              if (mounted) await _refreshStats();
                            },
                          ),
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
