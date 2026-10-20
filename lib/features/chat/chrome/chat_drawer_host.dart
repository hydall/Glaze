import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../core/platform/haptics.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../core/state/summary_providers.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../extensions/providers/extension_presets_provider.dart';
import '../../extensions/providers/extensions_settings_provider.dart';
import '../../plugins/providers/plugin_library_provider.dart';
import '../../plugins/widgets/plugin_action_cards.dart';
import '../chat_provider.dart';
import '../chat_state.dart';
import '../composer_pins_provider.dart';
import '../hidden_composer_actions_provider.dart';
import '../quick_replies_provider.dart';
import '../services/drawer_item_launcher.dart';
import '../services/magic_drawer_layout_service.dart';
import '../services/magic_drawer_stats_service.dart';
import '../state/cached_token_breakdown.dart';
import '../state/chat_drawer_editing_provider.dart';
import '../state/chat_drawer_tab.dart';
import '../state/magic_drawer_stats_cache.dart';
import '../widgets/magic_drawer_catalog.dart';
import '../widgets/magic_drawer_models.dart';
import '../widgets/magic_drawer_status.dart';
import '../widgets/magic_drawer_widgets.dart';
import '../widgets/quick_replies_panel.dart';
import 'chat_chrome_channel.dart';
import 'chrome_json.dart';

/// The chat drawer on a phone — what [ChatDrawerPanel] with its two tabs
/// ([MagicDrawerPanel], [QuickRepliesPanel]) was, drawn by the chat page
/// (`assets/chat_webview/chrome/drawer.js`).
///
/// Mounted for as long as the drawer is on screen, like the panel it
/// replaces, so the Tools tab's stats are loaded on open and kept fresh while
/// it is up, and nothing is computed while it is shut. The desktop sidebar
/// still hosts the Flutter panel.
class ChatDrawerHost extends ConsumerStatefulWidget {
  final ChatChromeChannel channel;
  final String charId;
  final VoidCallback onClose;
  final Future<bool> Function()? beforeGeneration;
  final Future<void> Function(String messageId)? onScrollToMessage;

  /// Drops the edge blur under the tab strip while the drawer animates in
  /// battery saver.
  final bool disableEffects;

  const ChatDrawerHost({
    super.key,
    required this.channel,
    required this.charId,
    required this.onClose,
    this.beforeGeneration,
    this.onScrollToMessage,
    this.disableEffects = false,
  });

  @override
  ConsumerState<ChatDrawerHost> createState() => _ChatDrawerHostState();
}

class _ChatDrawerHostState extends ConsumerState<ChatDrawerHost> {
  final List<MagicDrawerItemDef> _allItems = buildMagicDrawerItems();
  final List<String> _itemIds = [];
  final Set<String> _deletedIds = {};
  bool _loading = true;
  MagicDrawerStats _stats = const MagicDrawerStats();
  int _statsRequest = 0;
  Timer? _debounceTimer;
  late final MagicDrawerStatsService _statsService;
  late final VoidCallback _removeIntents;
  final List<ProviderSubscription<Object?>> _subscriptions = [];

  ChatChromeChannel get _channel => widget.channel;

  MagicDrawerStatsCacheKey _statsCacheKey([String? sessionId]) => (
    charId: widget.charId,
    sessionId:
        sessionId ?? ref.read(chatProvider(widget.charId)).value?.session?.id,
  );

  @override
  void initState() {
    super.initState();
    _statsService = MagicDrawerStatsService(ref);
    // Stale-while-revalidate, as MagicDrawerPanel: the previous snapshot right
    // away, the fresh one underneath.
    final cachedLayout = ref.read(magicDrawerLayoutCacheProvider);
    if (cachedLayout != null) {
      _itemIds.addAll(cachedLayout.itemIds);
      _deletedIds.addAll(cachedLayout.deletedIds);
    }
    final cachedStats = ref.read(
      magicDrawerStatsCacheProvider(_statsCacheKey()),
    );
    if (cachedStats != null) _stats = cachedStats;
    _loading = cachedLayout == null || cachedStats == null;
    _listenForRefresh();
    unawaited(_loadDrawer());
    _removeIntents = _channel.onAll({
      'drawerTab': (d) {
        final i = d['i'];
        if (i is int && i >= 0 && i < ChatDrawerTab.values.length) {
          ref.read(chatDrawerTabProvider.notifier).state =
              ChatDrawerTab.values[i];
        }
      },
      'drawerEditToggle': (_) {
        final editing = ref.read(chatDrawerEditingProvider);
        ref.read(chatDrawerEditingProvider.notifier).state = !editing;
      },
      'drawerEditStart': (_) {
        if (!ref.read(chatDrawerEditingProvider)) {
          ref.read(chatDrawerEditingProvider.notifier).state = true;
        }
      },
      'drawerClose': (_) => widget.onClose(),
      'toolTap': (d) => _onToolTap(d['id']),
      'toolDelete': (d) {
        final id = d['id'];
        if (id is String) unawaited(_removeItem(id));
      },
      'toolAdd': (_) => unawaited(_showAddItemSheet()),
      'toolMove': (d) {
        final moving = _toolId(d['moving']);
        final target = _toolId(d['target']);
        if (moving != null && target != null) {
          unawaited(_moveItem(moving, target));
        }
      },
      'pluginTap': (d) => _onPluginTap(d['key']),
      'actionTap': (d) => _onActionTap(d['id']),
      'actionHide': (d) {
        final action = d['id'] is String
            ? ComposerAction.byId(d['id'] as String)
            : null;
        if (action == null || !action.isInsert) return;
        Haptics.mediumImpact();
        unawaited(
          ref.read(hiddenComposerActionsProvider.notifier).hide(action),
        );
      },
      'replyTap': (d) => _onReplyTap(d['id']),
      'replyDelete': (d) {
        final id = d['id'];
        if (id is String) {
          unawaited(ref.read(quickRepliesProvider.notifier).remove(id));
        }
      },
      'replyMove': (d) {
        final moving = _replyId(d['moving']);
        final target = _replyId(d['target']);
        if (moving == null || target == null) return;
        final all = ref.read(quickRepliesProvider).value ?? const [];
        final from = all.indexWhere((r) => r.id == moving);
        final to = all.indexWhere((r) => r.id == target);
        if (from < 0 || to < 0 || from == to) return;
        unawaited(ref.read(quickRepliesProvider.notifier).reorder(from, to));
      },
      'actionsAdd': (_) => unawaited(showQuickRepliesAddSheet(context, ref)),
    });
  }

  @override
  void dispose() {
    ++_statsRequest;
    _debounceTimer?.cancel();
    _statsService.dispose();
    for (final sub in _subscriptions) {
      sub.close();
    }
    _removeIntents();
    _channel.set('drawer', {'show': false});
    super.dispose();
  }

  static String? _toolId(Object? key) {
    if (key is! String) return null;
    final pin = ComposerPin.decode(key);
    return pin?.kind == ComposerPinKind.tool ? pin!.refId : null;
  }

  static String? _replyId(Object? key) {
    if (key is! String) return null;
    final pin = ComposerPin.decode(key);
    return pin?.kind == ComposerPinKind.reply ? pin!.refId : null;
  }

  /* ---------- Tools tab: what MagicDrawerPanel did ---------- */

  Future<void> _loadDrawer() async {
    try {
      final layout = await MagicDrawerLayoutService(ref).loadLayout(_allItems);
      _deletedIds
        ..clear()
        ..addAll(layout.deletedIds);
      _itemIds
        ..clear()
        ..addAll(layout.itemIds);
      if (mounted) _cacheLayout();
      await _loadStats();
    } catch (e) {
      debugPrint('[ChatDrawerHost] load error: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveLayout() async {
    _cacheLayout();
    await MagicDrawerLayoutService(ref).saveLayout(_itemIds, _deletedIds);
  }

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
    if (!mounted) return;
    final currentSessionId = ref
        .read(chatProvider(widget.charId))
        .value
        ?.session
        ?.id;
    if (request != _statsRequest || currentSessionId != requestedSessionId) {
      return;
    }
    _stats = stats;
    ref
            .read(
              magicDrawerStatsCacheProvider(
                _statsCacheKey(requestedSessionId),
              ).notifier,
            )
            .state =
        stats;
  }

  Future<void> _refreshStats() async {
    if (!mounted) return;
    try {
      await _loadStats();
    } catch (e) {
      if (mounted) debugPrint('[ChatDrawerHost] refresh error: $e');
    }
    if (mounted) setState(() {});
  }

  void _scheduleRefresh() {
    if (!mounted) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), _refreshStats);
  }

  /// The same triggers MagicDrawerPanel refreshes its stats on.
  void _listenForRefresh() {
    void on<T>(
      ProviderListenable<T> provider,
      bool Function(T? prev, T next) changed,
    ) {
      _subscriptions.add(
        ref.listenManual<T>(provider, (prev, next) {
          if (changed(prev, next)) _scheduleRefresh();
        }),
      );
    }

    _subscriptions.add(
      ref.listenManual<AsyncValue<ChatState>>(chatProvider(widget.charId), (
        prev,
        next,
      ) {
        final prevSession = prev?.value?.session;
        final nextSession = next.value?.session;
        if (prevSession?.id != nextSession?.id) {
          ++_statsRequest;
          _debounceTimer?.cancel();
          final cached = ref.read(
            magicDrawerStatsCacheProvider(_statsCacheKey(nextSession?.id)),
          );
          setState(() => _stats = cached ?? const MagicDrawerStats());
          unawaited(_refreshStats());
        } else if (prevSession?.messages.length !=
                nextSession?.messages.length ||
            prevSession?.messages.lastOrNull?.content !=
                nextSession?.messages.lastOrNull?.content) {
          _scheduleRefresh();
        }
      }),
    );
    on(cachedTokenBreakdownProvider(widget.charId), (p, n) => !identical(p, n));
    on(activePresetIdProvider, (p, n) => p != n);
    on(presetConnectionsProvider, (p, n) => p != n);
    on(activeStudioPresetProvider, (p, n) => p?.value != n.value);
    on(studioFeatureEnabledProvider, (p, n) => p != n);
    on(summaryRevisionProvider, (p, n) => p != n);
    on(activePersonaIdProvider, (p, n) => p != n);
    on(personaConnectionsProvider, (p, n) => p != n);
    on(lorebookActivationsProvider, (p, n) => p != n);
    on(
      extensionsSettingsProvider,
      (p, n) => p == null || p.activePresetId != n.activePresetId,
    );
    on(extensionPresetsProvider, (p, n) {
      final pl = p ?? const [];
      if (pl.length != n.length) return true;
      for (var i = 0; i < pl.length; i++) {
        if (pl[i].name != n[i].name) return true;
      }
      return false;
    });
  }

  Future<void> _removeItem(String id) async {
    setState(() {
      _itemIds.remove(id);
      _deletedIds.add(id);
    });
    await _saveLayout();
  }

  Future<void> _moveItem(String movingId, String targetId) async {
    final from = _itemIds.indexOf(movingId);
    final to = _itemIds.indexOf(targetId);
    if (from < 0 || to < 0 || from == to) return;
    setState(() => _itemIds.insert(to, _itemIds.removeAt(from)));
    await _saveLayout();
  }

  Future<void> _showAddItemSheet() async {
    final available = _allItems
        .where((item) => !_itemIds.contains(item.id))
        .toList();
    if (available.isEmpty) return;
    final selected = await GlazeBottomSheet.show<MagicDrawerItemDef>(
      context,
      title: 'sheet_title_add_tool'.tr(),
      child: MagicDrawerAddList(
        items: available,
        onSelect: (item) =>
            Navigator.of(context, rootNavigator: true).pop(item),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _itemIds.add(selected.id);
      _deletedIds.remove(selected.id);
    });
    await _saveLayout();
  }

  Future<void> _onToolTap(Object? id) async {
    if (id is! String || ref.read(chatDrawerEditingProvider)) return;
    try {
      await DrawerItemLauncher(
        ref: ref,
        charId: widget.charId,
        onClose: widget.onClose,
      ).open(context, id);
    } finally {
      if (mounted) await _refreshStats();
    }
  }

  void _onPluginTap(Object? key) {
    if (key is! String) return;
    for (final kind in PluginActionKind.values) {
      for (final entry in pluginActionEntries(ref, context, kind)) {
        if (_pluginKey(entry) != key) continue;
        widget.onClose();
        unawaited(
          runPluginAction(
            context,
            ref,
            charId: widget.charId,
            kind: kind,
            entry: entry,
          ),
        );
        return;
      }
    }
  }

  static String _pluginKey(PluginActionEntry entry) =>
      'plugin:${entry.pluginId}:${entry.action.id}';

  /* ---------- Actions tab: what QuickRepliesPanel did ---------- */

  void _onActionTap(Object? id) {
    if (id is! String || ref.read(chatDrawerEditingProvider)) return;
    final action = ComposerAction.byId(id);
    if (action == null) return;
    // An insert card has typed its pair in the page already, inside the tap.
    if (!action.isInsert) {
      ref.read(composerActionBridgeProvider).run(action);
    }
    widget.onClose();
  }

  Future<void> _onReplyTap(Object? id) async {
    if (id is! String) return;
    final reply = (ref.read(quickRepliesProvider).value ?? const [])
        .where((r) => r.id == id)
        .firstOrNull;
    if (reply == null) return;
    if (ref.read(chatDrawerEditingProvider)) {
      await showQuickReplyEditSheet(context, ref, existing: reply);
      return;
    }
    final notifier = ref.read(chatProvider(widget.charId).notifier);
    if (await widget.beforeGeneration?.call() == false) return;
    if (!mounted) return;
    if (reply.isContinueAction) {
      await notifier.continueMessage();
    } else if (reply.text.trim().isNotEmpty) {
      await notifier.sendMessage(reply.text);
    }
    widget.onClose();
  }

  /* ---------- State for the page ---------- */

  Map<String, Object?> _pluginCard(PluginActionEntry entry) => {
    'key': _pluginKey(entry),
    'id': _pluginKey(entry),
    'kind': 'plugin',
    'label': entry.label,
    'icon': chromeIcon(Icons.widgets_outlined, file: entry.iconFile),
    'status': entry.pluginName,
    'statusIcon': chromeIcon(Icons.extension_rounded),
    'badge': null,
  };

  Map<String, Object?> _toolsState() {
    final extSettings = ref.watch(extensionsSettingsProvider);
    final extPresets = ref.watch(extensionPresetsProvider);
    final pinnedIds = {
      for (final pin
          in ref.watch(composerPinsProvider).value ?? const <ComposerPin>[])
        if (pin.kind == ComposerPinKind.tool) pin.refId,
    };
    final pluginsStatus = pluginsDrawerStatus(
      ref
          .watch(pluginLibraryProvider)
          .value
          ?.map((x) => (enabled: x.enabled))
          .toList(),
    );
    final cards = <Map<String, Object?>>[
      for (final id in _itemIds)
        if (!pinnedIds.contains(id))
          if (_allItems.where((item) => item.id == id).firstOrNull
              case final def?)
            {
              'key': ComposerPin.tool(def.id).encode(),
              'id': def.id,
              'kind': 'tool',
              'label': def.label,
              'icon': chromeIcon(
                def.icon,
                glyph: def.glyph,
                file: def.iconFile,
              ),
              'status': magicDrawerStatusFor(
                def.id,
                _stats,
                extSettings: extSettings,
                extPresets: extPresets,
                pluginsStatus: pluginsStatus,
              ),
              'badge': 'delete',
            },
      for (final entry in pluginActionEntries(
        ref,
        context,
        PluginActionKind.tools,
      ))
        _pluginCard(entry),
    ];
    final canAdd = _allItems.any((item) => !_itemIds.contains(item.id));
    return {
      'loading': _loading,
      'cards': cards,
      'add': canAdd ? {'label': 'action_add'.tr()} : null,
    };
  }

  Map<String, Object?> _actionsState() {
    final repliesAsync = ref.watch(quickRepliesProvider);
    final allReplies = repliesAsync.value ?? const <QuickReply>[];
    final pins = ref.watch(composerPinsProvider).value ?? const <ComposerPin>[];
    final hiddenIds =
        ref.watch(hiddenComposerActionsProvider).value ?? const <String>{};
    final translationEnabled = ref.watch(
      pipelineSettingsProvider.select((p) => p.translation.enabled),
    );
    final cards = <Map<String, Object?>>[
      for (final action in ComposerAction.demotable)
        if (!pins.contains(ComposerPin.action(action)) &&
            !hiddenIds.contains(action.id) &&
            (action != ComposerAction.translate || translationEnabled))
          {
            'key': ComposerPin.action(action).encode(),
            'id': action.id,
            'kind': 'action',
            'label': action.label,
            'icon': chromeIcon(action.icon, glyph: action.glyph),
            'badge': action.isInsert ? 'hide' : null,
            'insert': action.insertToken,
          },
      for (final reply in allReplies)
        if (!pins.contains(ComposerPin.reply(reply.id)))
          {
            'key': ComposerPin.reply(reply.id).encode(),
            'id': reply.id,
            'kind': 'reply',
            'label': reply.label,
            'icon': chromeIcon(reply.icon),
            'status': quickReplyPreviewText(reply),
            'badge': reply.isBuiltIn ? null : 'delete',
          },
      for (final entry in pluginActionEntries(
        ref,
        context,
        PluginActionKind.composer,
      ))
        _pluginCard(entry),
    ];
    return {
      'loading': repliesAsync.isLoading && allReplies.isEmpty,
      'cards': cards,
      'add': {'label': 'action_add'.tr()},
    };
  }

  @override
  Widget build(BuildContext context) {
    _channel.set('drawer', {
      'show': true,
      'tab': ref.watch(chatDrawerTabProvider).index,
      'editing': ref.watch(chatDrawerEditingProvider),
      'tabs': [
        {
          'label': 'drawer_tab_tools'.tr(),
          'icon': chromeIcon(Icons.auto_awesome),
        },
        {'label': 'drawer_tab_actions'.tr(), 'icon': chromeIcon(Icons.bolt)},
      ],
      'tools': _toolsState(),
      'actions': _actionsState(),
      'tips': {
        'edit': 'action_edit'.tr(),
        'done': 'btn_ok'.tr(),
        'delete': 'btn_delete'.tr(),
        'hide': 'composer_action_hide'.tr(),
      },
      'effects': !widget.disableEffects,
    });
    return const SizedBox.shrink();
  }
}
