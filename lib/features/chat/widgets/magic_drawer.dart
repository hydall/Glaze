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
import '../composer_pins_provider.dart';
import 'drawer_panel_scaffold.dart';
import 'magic_drawer_catalog.dart';
import 'magic_drawer_models.dart';
import '../services/drawer_item_launcher.dart';
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

  /// Edit mode, owned by the hosting [ChatDrawerPanel] so one pencil toggles
  /// both tabs at once. Ignored in [iconOnly] mode, which has nothing to edit.
  final bool editing;

  /// Asks the host to turn edit mode on — a long-press drag starts a reorder,
  /// which only makes sense in edit mode, so the gesture switches into it.
  final VoidCallback? onEditingRequested;

  /// Renders the panel as a narrow vertical strip of icons instead of the
  /// three-column card grid — the desktop right sidebar's collapsed state, and
  /// the strip that sits beside an open panel there.
  ///
  /// Taps run through the very same handler as the cards, so the strip cannot
  /// drift out of sync with the grid the way a hand-copied icon list would.
  final bool iconOnly;

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
    this.editing = false,
    this.onEditingRequested,
    this.iconOnly = false,
    this.onScrollToMessage,
  });

  @override
  ConsumerState<MagicDrawerPanel> createState() => _MagicDrawerPanelState();
}

class _MagicDrawerPanelState extends ConsumerState<MagicDrawerPanel> {
  final List<MagicDrawerItemDef> _allItems = buildMagicDrawerItems();

  final List<String> _itemIds = [];
  final Set<String> _deletedIds = {};
  bool _loading = true;
  bool _loadingTokens = false;
  int? _draggingIndex;
  int? _hoverIndex;
  MagicDrawerStats _stats = const MagicDrawerStats();
  int _statsRequest = 0;
  Timer? _debounceTimer;
  final _scrollController = ScrollController();
  late final MagicDrawerStatsService _statsService;

  MagicDrawerStatsCacheKey _statsCacheKey([String? sessionId]) => (
    charId: widget.charId,
    sessionId:
        sessionId ?? ref.read(chatProvider(widget.charId)).value?.session?.id,
  );

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
    final cachedStats = ref.read(
      magicDrawerStatsCacheProvider(_statsCacheKey()),
    );
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
    final requestedSessionId = ref
        .read(chatProvider(widget.charId))
        .value
        ?.session
        ?.id;
    final stats = await _statsService.computeStats(widget.charId);
    final currentSessionId = ref
        .read(chatProvider(widget.charId))
        .value
        ?.session
        ?.id;
    if (request != _statsRequest || currentSessionId != requestedSessionId) {
      return;
    }
    _stats = stats;
    // The drawer can be closed mid-load, which disposes this state and with it
    // `ref` — only touch the cache while still mounted.
    if (mounted) {
      ref
              .read(
                magicDrawerStatsCacheProvider(
                  _statsCacheKey(requestedSessionId),
                ).notifier,
              )
              .state =
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
    ref.read(magicDrawerStatsCacheProvider(_statsCacheKey()).notifier).state =
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

  /// The cards this tab paints, in saved order.
  ///
  /// A card pinned to the composer's row is dropped here rather than removed
  /// from [_itemIds]: the row and the grid must never offer the same thing
  /// twice, and keeping the id in the saved order is what lets the down-arrow
  /// put the card back exactly where it was.
  List<MagicDrawerCardItem> _displayItems(
    ExtensionsSettings extSettings,
    List<ExtensionPreset> extPresets,
    bool studioFeatureEnabled,
    Set<String> pinnedIds,
  ) {
    final list = _itemIds
        .where((id) => !pinnedIds.contains(id))
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

  /// Feature-gated cards are hidden from the Tools tab and the "Add Tool"
  /// list unless their Experimental Features master switch is on.
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

  Future<void> _removeItem(String id) async {
    setState(() {
      _itemIds.remove(id);
      _deletedIds.add(id);
    });
    await _saveLayout();
  }

  /// Reorders by card id, not by grid position.
  ///
  /// The grid is a filtered view of [_itemIds] — a feature-gated card or one
  /// pinned to the composer row is skipped — so a drop's display indices are
  /// not indices into the saved order and moving by them would shuffle a
  /// bystander instead.
  Future<void> _moveItem(String movingId, String targetId) async {
    final from = _itemIds.indexOf(movingId);
    final to = _itemIds.indexOf(targetId);
    if (from < 0 || to < 0 || from == to) return;
    setState(() {
      _itemIds.insert(to, _itemIds.removeAt(from));
      _hoverIndex = null;
    });
    await _saveLayout();
  }

  /// Moves a card up into the composer's pinned row. Its id stays in
  /// [_itemIds], so the row's down-arrow drops it back into this slot.
  void _pinItem(String id) {
    Haptics.mediumImpact();
    unawaited(ref.read(composerPinsProvider.notifier).pin(ComposerPin.tool(id)));
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
      title: 'sheet_title_add_tool'.tr(),
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
    if (widget.editing) return;
    try {
      await DrawerItemLauncher(
        ref: ref,
        charId: widget.charId,
        onClose: widget.onClose,
      ).open(context, item.id);
    } finally {
      if (mounted) await _refreshStats();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatProvider(widget.charId), (prev, next) {
      final prevSession = prev?.value?.session;
      final nextSession = next.value?.session;
      if (prevSession?.id != nextSession?.id) {
        ++_statsRequest;
        _debounceTimer?.cancel();
        final cached = ref.read(
          magicDrawerStatsCacheProvider(_statsCacheKey(nextSession?.id)),
        );
        setState(() {
          _stats = cached ?? const MagicDrawerStats();
          _loadingTokens = false;
        });
        unawaited(_refreshStats());
      } else if (prevSession?.messages.length != nextSession?.messages.length ||
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
    final pinnedIds = {
      for (final pin in ref.watch(composerPinsProvider).value ?? const <ComposerPin>[])
        if (pin.kind == ComposerPinKind.tool) pin.refId,
    };
    final items = _displayItems(
      extSettings,
      extPresets,
      studioFeatureEnabled,
      pinnedIds,
    );
    final canAdd = _canAddMore(extSettings, studioFeatureEnabled);

    final scrollable = RawScrollbar(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: kDrawerContentTopInset),
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
                kDrawerContentTopInset,
                12,
                16 + MediaQuery.of(context).padding.bottom,
              ),
              child: MagicCardGrid(
                columns: 3,
                cells: [
                  ...List.generate(items.length, (index) {
                    final item = items[index];
                    final card = MagicCard(
                      item: item,
                      editing: widget.editing,
                      hovered: _hoverIndex == index && _draggingIndex != index,
                      onTap: () => _handleTap(item.def),
                      onDelete: () => _removeItem(item.def.id),
                      onPin: () => _pinItem(item.def.id),
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
                          // Indices address this render's grid; the drop can
                          // land after a rebuild shortened it.
                          final from = details.data;
                          if (from < 0 || from >= items.length) return;
                          _moveItem(items[from].def.id, item.def.id);
                        },
                        builder: (context, _, _) {
                          return LongPressDraggable<int>(
                            data: index,
                            delay: const Duration(milliseconds: 300),
                            onDragStarted: () {
                              Haptics.mediumImpact();
                              if (!widget.editing) {
                                widget.onEditingRequested?.call();
                              }
                              setState(() => _draggingIndex = index);
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
                  // The add tile is always the last cell rather than a header
                  // button revealed by edit mode: a "+" sitting in the grid is
                  // how a new user finds out the row is theirs to change.
                  // It is outside the drag/drop wiring above — it has no index
                  // to reorder and must never be a drop target.
                  if (canAdd)
                    SizedBox(
                      width: itemWidth,
                      child: AddMagicCard(onTap: _showAddItemSheet),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );

    if (widget.iconOnly) return _buildIconStrip(items);

    // The chrome (background, drag handle, header) belongs to the hosting
    // [ChatDrawerPanel] — this is only the tab body.
    return PanelLoadingOverlay(loading: _loading, child: scrollable);
  }

  /// Vue's `.tools-strip.magic-drawer-sidebar.icon-only`: a scrollable column
  /// of 48px rows, each a tinted rounded icon with the card's label as its
  /// tooltip.
  Widget _buildIconStrip(List<MagicDrawerCardItem> items) {
    if (_loading && items.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in items)
              MagicDrawerStripIcon(
                icon: item.def.icon,
                label: item.def.label,
                onTap: () => _handleTap(item.def),
              ),
          ],
        ),
      ),
    );
  }
}
