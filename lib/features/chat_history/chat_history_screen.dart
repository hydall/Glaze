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
import 'chat_history_list.dart';

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

  @override
  void initState() {
    super.initState();
    if (!widget.embedded) {
      _registry = ref.read(shellHeaderProvider.notifier);
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
    if (!widget.embedded) {
      final registry = _registry;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => registry?.remove(this),
      );
    }
    super.dispose();
  }

  ShellHeaderConfig _shellHeader() => ShellHeaderConfig(
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
