import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/shell/header_scroll_hider.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/shell/nav_retap_provider.dart';
import '../../shared/shell/shell_header_provider.dart';
import '../../shared/theme/app_colors.dart';

import '../../shared/widgets/glow_ripple.dart';
import '../settings/app_settings_provider.dart';
import 'chat_history_actions.dart';
import 'chat_history_list.dart';
import 'chat_history_provider.dart';
import 'chat_history_selection_provider.dart';

class ChatHistoryScreen extends ConsumerStatefulWidget {
  /// When true, renders an inline search bar and skips shell-header integration.
  /// Used by the desktop left sidebar.
  final bool embedded;
  const ChatHistoryScreen({super.key, this.embedded = false});

  @override
  ConsumerState<ChatHistoryScreen> createState() => _ChatHistoryScreenState();
}

class _ChatHistoryScreenState extends ConsumerState<ChatHistoryScreen> {
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  // Full-screen only
  final FocusNode _searchFocus = FocusNode();
  bool _searchExpanded = false;
  ShellHeaderRegistry? _registry;
  final HeaderScrollHider _headerScrollHider = HeaderScrollHider();
  final ScrollController _scrollController = ScrollController();

  // Cached so [dispose] can clear the selection without reading `ref`.
  ChatHistorySelectionNotifier? _selectionNotifier;

  @override
  void initState() {
    super.initState();
    if (!widget.embedded) {
      _registry = ref.read(shellHeaderProvider.notifier);
      _selectionNotifier = ref.read(chatHistorySelectionProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _registry?.publish(this, 0, _shellHeader());
        // The hidden flag is branch-scoped and outlives this screen, so a list
        // left scrolled down would re-open with its header still slid away.
        _showHeader();
      });
    }
  }

  void _refreshShellHeader() {
    if (widget.embedded || !mounted) return;
    _registry?.publish(this, 0, _shellHeader());
  }

  /// Slides the shell header out of view while scrolling down the list and back
  /// in while scrolling up. Uses [HeaderScrollHider], ported from the chat
  /// header's algorithm.
  bool _onScrollNotification(ScrollNotification n) {
    final notifier = ref.read(shellHeaderHiddenProvider(0).notifier);
    _headerScrollHider.handle(n, (hidden) => notifier.state = hidden);
    return false;
  }

  /// Forces the shell header back into view. Resets the hider too, otherwise it
  /// would keep believing the header is hidden and swallow the next hide.
  void _showHeader() {
    _headerScrollHider.reset();
    final notifier = ref.read(shellHeaderHiddenProvider(0).notifier);
    if (notifier.state) notifier.state = false;
  }

  /// Animates the dialogs list back to the top (guarded so it never touches a
  /// controller with no — or more than one — attached scroll position).
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
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    // The selection bar lives in the header this screen publishes, so a
    // selection that outlived the screen would have no way back out.
    final selection = _selectionNotifier;
    WidgetsBinding.instance.addPostFrameCallback((_) => selection?.clear());
    if (!widget.embedded) {
      final registry = _registry;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => registry?.remove(this),
      );
    }
    super.dispose();
  }

  ShellHeaderConfig _shellHeader() {
    final selection = ref.read(chatHistorySelectionProvider);
    if (selection.active) return _selectionHeader(selection.count);
    return ShellHeaderConfig(
      title: _searchExpanded ? null : 'tab_dialogs'.tr(),
      titleWidget: _searchExpanded ? _buildSearchField() : null,
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
  }

  /// While rows are selected the header stops being the Chats tab: the logo
  /// gives way to a close button, the title to the running count, and the
  /// search button to the overflow menu that a long press used to open.
  ShellHeaderConfig _selectionHeader(int count) => ShellHeaderConfig(
    leading: IconButton(
      icon: const Icon(Icons.close_rounded, size: 22),
      color: context.cs.primary,
      tooltip: 'btn_cancel'.tr(),
      onPressed: () => ref.read(chatHistorySelectionProvider.notifier).clear(),
    ),
    title: '$count ${'selected_count'.tr()}',
    actions: [
      SizedBox(
        width: 44,
        height: 44,
        child: IconButton(
          icon: const Icon(Icons.more_vert_rounded, size: 22),
          color: context.cs.primary,
          onPressed: _openSelectionActions,
        ),
      ),
    ],
  );

  /// Opens the bulk action menu for the current selection, resolved against
  /// the live list so a session deleted meanwhile simply drops out.
  void _openSelectionActions() {
    final selection = ref.read(chatHistorySelectionProvider);
    final all =
        ref.read(chatHistoryProvider).value ?? const <ChatSessionInfo>[];
    final sessions = [
      for (final info in all)
        if (selection.contains(info.sessionId)) info,
    ];
    if (sessions.isEmpty) return;
    showChatSessionActions(context, ref, sessions);
  }

  void _openSearch() {
    _showHeader();
    setState(() => _searchExpanded = true);
    _refreshShellHeader();
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
    _refreshShellHeader();
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _searchCtrl,
      focusNode: _searchFocus,
      autofocus: true,
      onChanged: (v) => setState(() => _searchQuery = v),
      textInputAction: TextInputAction.search,
      cursorColor: context.cs.primary,
      style: TextStyle(color: context.cs.onSurface, fontSize: 16),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: 'search_dialogs'.tr(),
        hintStyle: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.embedded ? _buildEmbedded(context) : _buildFullScreen(context);
  }

  Widget _buildFullScreen(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final topPad = MediaQuery.of(context).padding.top + 66.0 + 16.0;
    final bottomPad = ref.watch(navHeightProvider) + 20;

    // The header *is* the selection bar, so it has to be on screen and current
    // for as long as rows are selected.
    ref.listen(chatHistorySelectionProvider, (_, next) {
      if (next.active) _showHeader();
      _refreshShellHeader();
    });

    // Re-tap on the active Dialogs navbar tab → scroll the list to the top.
    ref.listen(navReTapProvider, (_, next) {
      if (next.branchIndex == kDialogsBranchIndex) {
        _showHeader();
        _scrollToTop();
      }
    });

    // The shell reveals the header when this branch is re-entered (see
    // [ShellScreen]). Re-baseline the hider so it agrees, instead of holding a
    // stale `hidden` that would swallow the next hide.
    ref.listen(shellHeaderHiddenProvider(0), (_, hidden) {
      if (!hidden && _headerScrollHider.hidden) _headerScrollHider.reset();
    });

    final list = ChatHistoryList(
      controller: _scrollController,
      searchQuery: _searchQuery,
      topPadding: topPad,
      bottomPadding: bottomPad,
      selectable: true,
    );
    final body = settingsAsync.value?.batterySaver ?? false
        ? list
        : GlowRippleOverlay(radiusFactor: 0.18, intensity: 0.32, child: list);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: body,
      ),
    );
  }

  Widget _buildEmbedded(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _searchQuery = v),
            textInputAction: TextInputAction.search,
            cursorColor: context.cs.primary,
            style: TextStyle(color: context.cs.onSurface, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'search_dialogs'.tr(),
              hintStyle: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 13,
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: context.cs.onSurfaceVariant,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.06),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
            ),
          ),
        ),
        Expanded(child: ChatHistoryList(searchQuery: _searchQuery)),
      ],
      ),
    );
  }
}
