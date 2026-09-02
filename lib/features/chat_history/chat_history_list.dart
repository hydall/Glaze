import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/hover_glow.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/utils/time_formatter.dart';
import '../../shared/utils/avatar_image.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../core/models/character.dart';
import '../../core/state/character_provider.dart'
    show
        avatarVersionProvider,
        characterSessionCountsProvider,
        charactersProvider,
        revealHiddenCharactersProvider;
import '../../core/platform/haptics.dart';
import '../../core/state/chat_session_ops_provider.dart';
import '../../shared/utils/variant_label.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/variation_chip.dart';
import '../chat/generating_sessions_provider.dart';
import '../chat/unread_sessions_provider.dart';
import '../settings/app_settings_provider.dart';
import 'chat_history_actions.dart';
import 'chat_history_provider.dart';
import 'chat_history_selection_provider.dart';
import 'widgets/message_preview_text.dart';
import 'widgets/typing_dots.dart';

class ChatHistoryList extends ConsumerStatefulWidget {
  final bool collapsed;
  final String searchQuery;

  /// Top padding applied inside the scroll view so content can scroll *behind*
  /// a translucent shell header instead of being clipped by it.
  final double topPadding;

  /// Bottom padding applied inside the scroll view so the last rows can scroll
  /// clear of the translucent bottom nav bar instead of being hidden by it.
  final double bottomPadding;

  /// Owned by the parent so a navbar re-tap can animate the list back to the top.
  final ScrollController? controller;

  /// Whether a long press may start a multi-selection. Only the full-screen
  /// dialogs list sets it: the selection bar lives in the shell header, and
  /// the desktop sidebar's embedded copies publish no header to put it in —
  /// there a long press keeps opening the row's own action menu.
  final bool selectable;

  const ChatHistoryList({
    super.key,
    this.collapsed = false,
    this.searchQuery = '',
    this.topPadding = 0,
    this.bottomPadding = 20,
    this.controller,
    this.selectable = false,
  });

  @override
  ConsumerState<ChatHistoryList> createState() => _ChatHistoryListState();
}

class _ChatHistoryListState extends ConsumerState<ChatHistoryList> {
  /// Expanded groups, keyed by variation group id (a character and all of its
  /// variations expand together).
  final Set<String> _expandedGroupIds = {};

  /// Avatar paths already warmed so we don't re-precache on every rebuild.
  final Set<String> _precachedAvatars = {};

  /// Decode + cache each distinct avatar ahead of scrolling so rows don't
  /// pop in while the image decodes on first appearance.
  void _precacheAvatars(List<ChatSessionInfo> sessions) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final s in sessions) {
        for (final path in [s.avatarPath, s.groupAvatarPath]) {
          if (path == null || path.isEmpty) continue;
          if (!_precachedAvatars.add(path)) continue;
          precacheGlazeAvatar(context, path);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(chatHistoryProvider);
    final settingsAsync = ref.watch(appSettingsProvider);

    return sessionsAsync.when(
      loading: () => Center(child: GlazeSpinner(color: context.cs.primary)),
      error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
      data: (list) {
        _precacheAvatars(list);
        final settings = settingsAsync.value ?? const AppSettings();
        var filtered = list;
        if (widget.searchQuery.isNotEmpty) {
          final q = widget.searchQuery.toLowerCase();
          filtered = list
              .where(
                (s) =>
                    s.characterName.toLowerCase().contains(q) ||
                    (s.variantName?.toLowerCase().contains(q) ?? false) ||
                    (s.sessionName?.toLowerCase().contains(q) ?? false) ||
                    s.lastMessage.toLowerCase().contains(q),
              )
              .toList();
        }

        if (filtered.isEmpty) {
          return _buildEmptyState();
        }

        if (settings.groupDialogs) {
          return _buildGroupedList(filtered);
        }

        return ListView.builder(
          controller: widget.controller,
          padding: EdgeInsets.only(
            top: widget.topPadding,
            bottom: widget.bottomPadding,
          ),
          itemCount: filtered.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) return _buildCountHeader(filtered.length);
            return _SessionTile(
              info: filtered[i - 1],
              collapsed: widget.collapsed,
              selectable: widget.selectable,
              index: i - 1,
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: EdgeInsets.only(top: widget.topPadding),
      child: Center(
        child: widget.collapsed
            ? Icon(
                Icons.chat_bubble_outline,
                size: 24,
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 48,
                    color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'no_dialogs'.tr(),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildGroupedList(List<ChatSessionInfo> sessions) {
    // Keyed by variation group, not character id: variations are separate
    // character rows, so grouping by id scattered one character's variations
    // across the list as several look-alike entries with the same avatar.
    final groupsMap = <String, List<ChatSessionInfo>>{};
    for (final s in sessions) {
      groupsMap.putIfAbsent(s.variantGroupId, () => []).add(s);
    }

    final sortedGroups = groupsMap.entries.toList()
      ..sort(
        (a, b) => b.value.first.lastMessageTime.compareTo(
          a.value.first.lastMessageTime,
        ),
      );

    return ListView.builder(
      controller: widget.controller,
      padding: EdgeInsets.only(
        top: widget.topPadding,
        bottom: widget.bottomPadding,
      ),
      itemCount: sortedGroups.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) return _buildCountHeader(sessions.length);
        final entry = sortedGroups[i - 1];
        final groupId = entry.key;
        final group = [...entry.value]
          ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
        final isExpanded = _expandedGroupIds.contains(groupId);
        return _ChatHistoryGroupSection(
          sessions: group,
          isExpanded: isExpanded,
          selectable: widget.selectable,
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expandedGroupIds.remove(groupId);
              } else {
                _expandedGroupIds.add(groupId);
              }
            });
          },
        );
      },
    );
  }

  Widget _buildCountHeader(int count) {
    if (widget.collapsed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Text(
        '$count ${'count_chats'.plural(count)}',
        style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
      ),
    );
  }
}

class _ChatHistoryGroupSection extends StatefulWidget {
  final List<ChatSessionInfo> sessions;
  final bool isExpanded;
  final bool selectable;
  final VoidCallback onTap;

  const _ChatHistoryGroupSection({
    required this.sessions,
    required this.isExpanded,
    required this.onTap,
    this.selectable = false,
  });

  @override
  State<_ChatHistoryGroupSection> createState() =>
      _ChatHistoryGroupSectionState();
}

class _ChatHistoryGroupSectionState extends State<_ChatHistoryGroupSection>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _sizeAnimation;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      reverseDuration: const Duration(milliseconds: 200),
      value: widget.isExpanded ? 1 : 0,
    );
    _sizeAnimation = CurvedAnimation(
      parent: _controller,
      curve: const Cubic(0.2, 0.8, 0.2, 1),
      reverseCurve: Curves.easeInOut,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, -0.04), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Cubic(0.2, 0.8, 0.2, 1),
            reverseCurve: Curves.easeInOut,
          ),
        );
  }

  @override
  void didUpdateWidget(covariant _ChatHistoryGroupSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExpanded != oldWidget.isExpanded) {
      if (widget.isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GroupHeader(
          sessions: widget.sessions,
          isExpanded: widget.isExpanded,
          onTap: widget.onTap,
        ),
        ClipRect(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: SizeTransition(
              sizeFactor: _sizeAnimation,
              alignment: AlignmentDirectional.topStart,
              child: SlideTransition(
                position: _slideAnimation,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: GlassSurface(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < widget.sessions.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 1,
                              thickness: 0.5,
                              color: Colors.white.withValues(alpha: 0.08),
                              indent: 12,
                              endIndent: 12,
                            ),
                          _SessionTile(
                            info: widget.sessions[i],
                            isGrouped: true,
                            selectable: widget.selectable,
                            index: i,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SessionTile extends ConsumerStatefulWidget {
  final ChatSessionInfo info;
  final bool isGrouped;
  final bool collapsed;

  /// See [ChatHistoryList.selectable].
  final bool selectable;

  /// Row position within its list — staggers the fade-in so rows cascade in
  /// on load instead of popping in all at once. Capped below so long lists
  /// don't take forever to finish appearing.
  final int index;

  const _SessionTile({
    required this.info,
    this.isGrouped = false,
    this.collapsed = false,
    this.selectable = false,
    this.index = 0,
  });

  @override
  ConsumerState<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends ConsumerState<_SessionTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entryCtrl;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  ChatSessionInfo get info => widget.info;

  @override
  void initState() {
    super.initState();
    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    final curve = CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOut);
    _fadeAnim = curve;
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(curve);
    final delay = Duration(milliseconds: (widget.index * 30).clamp(0, 240));
    if (delay > Duration.zero) {
      Future.delayed(delay, () {
        if (mounted) _entryCtrl.forward();
      });
    } else {
      _entryCtrl.forward();
    }
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    super.dispose();
  }

  @override
  // `ConsumerState` exposes `ref` as a field, so `build` keeps `State`'s
  // single-argument signature — the two-argument form belongs to
  // `ConsumerWidget` and does not override `State.build` here.
  Widget build(BuildContext context) {
    final generating = ref.watch(
      generatingSessionsProvider.select((s) => s.contains(info.sessionId)),
    );
    // A live reply supersedes the unread dot: the row already reads as "active".
    final unread =
        !generating &&
        ref.watch(
          unreadSessionsProvider.select((s) => s.contains(info.sessionId)),
        );
    // Both reads are gated on a flag that is constant for the life of the row,
    // so the watched set never changes shape between builds.
    final selectionActive =
        widget.selectable &&
        ref.watch(chatHistorySelectionProvider.select((s) => s.active));
    final selected =
        widget.selectable &&
        ref.watch(
          chatHistorySelectionProvider.select(
            (s) => s.contains(info.sessionId),
          ),
        );
    final Widget tile = widget.collapsed
        ? _buildCollapsedTile(context, ref, generating, unread)
        : widget.isGrouped
        ? _buildGroupedTile(
            context,
            ref,
            generating,
            unread,
            selectionActive: selectionActive,
            selected: selected,
          )
        : _buildFullTile(
            context,
            ref,
            generating,
            unread,
            selectionActive: selectionActive,
            selected: selected,
          );

    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(position: _slideAnim, child: tile),
    );
  }

  Widget _buildCollapsedTile(
    BuildContext context,
    WidgetRef ref,
    bool generating,
    bool unread,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          context.go('/chat/${info.characterId}?session=${info.sessionIndex}'),
      child: Tooltip(
        message: info.fullCharacterName,
        preferBelow: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _buildAvatar(context, ref, size: 36),
              if (generating || unread)
                Positioned(
                  right: -1,
                  top: -1,
                  child: _StatusBadge(
                    generating: generating,
                    color: context.cs.primary,
                    borderColor: context.cs.surface,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFullTile(
    BuildContext context,
    WidgetRef ref,
    bool generating,
    bool unread, {
    required bool selectionActive,
    required bool selected,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _handleTap(selectionActive),
      onLongPress: _handleContextGesture,
      // Right-click is the desktop equivalent of a long press, matching the Vue
      // list's `@contextmenu.prevent="openActions(chat)"`.
      onSecondaryTap: _handleContextGesture,
      child: HoverGlow(
        child: Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: _rowDecoration(
            context,
            unread: unread,
            selected: selected,
          ),
          child: Row(
            children: [
              if (selectionActive) ...[
                _SelectionCheck(selected: selected),
                const SizedBox(width: 12),
              ],
              _buildAvatar(context, ref),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              if (unread) ...[
                                _UnreadDot(color: context.cs.primary),
                                const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: Text(
                                  info.characterName,
                                  style: TextStyle(
                                    fontWeight: unread
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    fontSize: 16,
                                    height: 20 / 16,
                                    color: context.cs.onSurface,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              // Outside the Flexible on purpose: the character
                              // name gives way to the ellipsis first, the chip
                              // that identifies the variation always survives.
                              if (info.variantName != null) ...[
                                const SizedBox(width: 6),
                                VariationChip(name: info.variantName!),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildChip(context),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      info.sessionName?.isNotEmpty == true
                          ? info.sessionName!
                          : 'session_name'.tr(
                              namedArgs: {
                                'id': (info.sessionIndex + 1).toString(),
                              },
                            ),
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    generating
                        ? const _GeneratingPreview()
                        : MessagePreviewText(
                            raw: info.lastMessage,
                            style: TextStyle(
                              fontSize: 13,
                              height: 16 / 13,
                              color: unread
                                  ? context.cs.onSurface
                                  : context.cs.onSurfaceVariant,
                            ),
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroupedTile(
    BuildContext context,
    WidgetRef ref,
    bool generating,
    bool unread, {
    required bool selectionActive,
    required bool selected,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _handleTap(selectionActive),
      onLongPress: _handleContextGesture,
      onSecondaryTap: _handleContextGesture,
      child: HoverGlow(
        child: Container(
          padding: const EdgeInsets.all(12),
          color: selected ? context.cs.primary.withValues(alpha: 0.12) : null,
          child: Row(
            children: [
              if (selectionActive) ...[
                _SelectionCheck(selected: selected),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              if (unread) ...[
                                _UnreadDot(color: context.cs.primary),
                                const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: Text(
                                  info.sessionName?.isNotEmpty == true
                                      ? info.sessionName!
                                      : 'session_name'.tr(
                                          namedArgs: {
                                            'id': (info.sessionIndex + 1)
                                                .toString(),
                                          },
                                        ),
                                  style: TextStyle(
                                    fontWeight: unread
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                    fontSize: 15,
                                    color: context.cs.onSurface,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              // Inside a group the rows are sessions of
                              // possibly different variations, so each one
                              // names its own.
                              if (info.variantName != null) ...[
                                const SizedBox(width: 6),
                                VariationChip(name: info.variantName!),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildChip(context),
                      ],
                    ),
                    const SizedBox(height: 4),
                    generating
                        ? const _GeneratingPreview()
                        : MessagePreviewText(
                            raw: info.lastMessage,
                            style: TextStyle(
                              fontSize: 12,
                              color: unread
                                  ? context.cs.onSurface
                                  : context.cs.onSurfaceVariant,
                            ),
                            maxLines: 2,
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens a chat, or toggles the row while a multi-selection is running.
  void _handleTap(bool selectionActive) {
    if (selectionActive) {
      ref.read(chatHistorySelectionProvider.notifier).toggle(info.sessionId);
      return;
    }
    context.go('/chat/${info.characterId}?session=${info.sessionIndex}');
  }

  /// Long press — and right-click, its desktop equivalent. On the full-screen
  /// list it starts or extends the multi-selection, whose actions then live in
  /// the shell header; where selection is unavailable it opens this row's own
  /// action menu, as it always did.
  void _handleContextGesture() {
    if (!widget.selectable) {
      unawaited(showChatSessionActions(context, ref, [info]));
      return;
    }
    unawaited(Haptics.selectionClick());
    final notifier = ref.read(chatHistorySelectionProvider.notifier);
    if (ref.read(chatHistorySelectionProvider).active) {
      notifier.toggle(info.sessionId);
    } else {
      notifier.start(info.sessionId);
    }
  }

  /// Row background: the selection tint wins over the unread accent, so a
  /// selected row still reads as selected while it is also unread.
  BoxDecoration? _rowDecoration(
    BuildContext context, {
    required bool unread,
    required bool selected,
  }) {
    if (selected) {
      return BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.12),
        border: Border(
          left: BorderSide(color: context.cs.primary, width: 3),
        ),
      );
    }
    if (!unread) return null;
    return BoxDecoration(
      color: context.cs.primary.withValues(alpha: 0.06),
      border: Border(left: BorderSide(color: context.cs.primary, width: 3)),
    );
  }

  String _formatTime() {
    if (info.lastMessageTime == 0) return '';
    return formatSessionTimeAgo(info.lastMessageTime);
  }

  Widget _buildAvatar(BuildContext context, WidgetRef ref, {double size = 48}) {
    ref.watch(avatarVersionProvider);
    final image = glazeAvatarImage(info.avatarPath);
    if (image != null) {
      return ClipOval(
        child: SizedBox.square(
          dimension: size,
          child: Image(
            image: image,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (ctx, e, st) => _defaultAvatar(context, size),
          ),
        ),
      );
    }
    return _defaultAvatar(context, size);
  }

  Widget _defaultAvatar(BuildContext context, double size) => CircleAvatar(
    radius: size / 2,
    backgroundColor: context.cs.primary,
    child: Text(
      info.characterName.isNotEmpty ? info.characterName[0].toUpperCase() : '?',
      style: const TextStyle(color: Colors.black, fontSize: 18),
    ),
  );

  Widget _buildChip(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.mail_outline,
            size: 12,
            color: context.cs.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            '${info.messageCount} ${'count_messages'.plural(info.messageCount)}${info.lastMessageTime > 0 ? ' · ${_formatTime()}' : ''}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupHeader extends ConsumerWidget {
  final List<ChatSessionInfo> sessions;
  final bool isExpanded;
  final VoidCallback onTap;

  const _GroupHeader({
    required this.sessions,
    required this.isExpanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = sessions.first;
    final sessionIds = sessions.map((s) => s.sessionId).toSet();
    final generating = ref.watch(
      generatingSessionsProvider.select((s) => s.any(sessionIds.contains)),
    );
    final unread =
        !generating &&
        ref.watch(
          unreadSessionsProvider.select((s) => s.any(sessionIds.contains)),
        );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: () => _showGroupActions(context, ref, latest),
      onSecondaryTap: () => _showGroupActions(context, ref, latest),
      child: HoverGlow(
        child: Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: unread
              ? BoxDecoration(
                  color: context.cs.primary.withValues(alpha: 0.06),
                  border: Border(
                    left: BorderSide(color: context.cs.primary, width: 3),
                  ),
                )
              : null,
          child: Row(
            children: [
              _buildAvatar(context, ref, latest),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              if (unread) ...[
                                _UnreadDot(color: context.cs.primary),
                                const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: Text(
                                  latest.characterName,
                                  style: TextStyle(
                                    fontWeight: unread
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    fontSize: 16,
                                    height: 20 / 16,
                                    color: context.cs.onSurface,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildTime(context, latest),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _subtitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                        AnimatedRotation(
                          turns: isExpanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            color: context.cs.onSurfaceVariant,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    generating
                        ? const _GeneratingPreview()
                        : MessagePreviewText(
                            raw: latest.lastMessage,
                            style: TextStyle(
                              fontSize: 13,
                              height: 16 / 13,
                              color: unread
                                  ? context.cs.onSurface
                                  : context.cs.onSurfaceVariant,
                            ),
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "N sessions", plus "· K variations" when the group spans more than one —
  /// the collapsed header is the only place that can say the group is not just
  /// a pile of sessions of one character.
  String _subtitle() {
    final sessionsLine = 'count_sessions_format'.plural(sessions.length);
    final variantCount = _variantCount();
    if (variantCount < 2) return sessionsLine;
    return '$sessionsLine · ${'variations_count'.plural(variantCount)}';
  }

  /// Distinct variations represented among this group's sessions.
  int _variantCount() => sessions.map((s) => s.characterId).toSet().length;

  Widget _buildAvatar(
    BuildContext context,
    WidgetRef ref,
    ChatSessionInfo info,
  ) {
    ref.watch(avatarVersionProvider);
    // The group's face is the original's, not the last-used variation's.
    final image = glazeAvatarImage(info.groupAvatarPath ?? info.avatarPath);
    if (image != null) {
      return ClipOval(
        child: SizedBox.square(
          dimension: 48,
          child: Image(
            image: image,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (ctx, e, st) => _defaultGroupAvatar(context, info),
          ),
        ),
      );
    }
    return _defaultGroupAvatar(context, info);
  }

  Widget _defaultGroupAvatar(BuildContext context, ChatSessionInfo info) =>
      CircleAvatar(
        radius: 24,
        backgroundColor: context.cs.primary,
        child: Text(
          info.characterName.isNotEmpty
              ? info.characterName[0].toUpperCase()
              : '?',
          style: const TextStyle(color: Colors.black, fontSize: 18),
        ),
      );

  Widget _buildTime(BuildContext context, ChatSessionInfo info) {
    if (info.lastMessageTime == 0) return const SizedBox.shrink();
    final dt = DateTime.fromMillisecondsSinceEpoch(info.lastMessageTime);
    final now = DateTime.now();
    final diff = now.difference(dt);

    String text;
    if (diff.inMinutes < 1) {
      text = 'now';
    } else if (diff.inHours < 1) {
      text = '${diff.inMinutes}m';
    } else if (diff.inDays < 1) {
      text = '${diff.inHours}h';
    } else if (diff.inDays < 7) {
      text = '${diff.inDays}d';
    } else {
      text = '${dt.day}/${dt.month}';
    }

    return Text(
      text,
      style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
    );
  }

  Future<void> _showGroupActions(
    BuildContext context,
    WidgetRef ref,
    ChatSessionInfo info,
  ) async {
    // The group can span several variations. "Edit character" targets the most
    // recently used one, so name it; "New session" asks instead (see below).
    // Both read the group from the library, not from this group's sessions, so
    // a variation you have not chatted with yet still counts.
    final variants = _groupVariants(ref, info.variantGroupId);
    final spansVariations = variants.length > 1;
    final variantHint = spansVariations
        ? (info.variantName ?? 'variation_original'.tr())
        : info.variantName;
    final rootNav = Navigator.of(context, rootNavigator: true);
    final result = await GlazeBottomSheet.show<String>(
      context,
      title: info.characterName,
      items: [
        BottomSheetItem(
          icon: Icons.add_comment_outlined,
          label: 'action_new_session'.tr(),
          hint: spansVariations ? 'variation_pick_title'.tr() : null,
          onTap: () => rootNav.pop('new'),
        ),
        BottomSheetItem(
          icon: Icons.edit_note_rounded,
          label: 'action_edit_character'.tr(),
          hint: variantHint,
          onTap: () => rootNav.pop('edit'),
        ),
      ],
    );
    if (result == null || !context.mounted) return;
    if (result == 'edit') {
      unawaited(context.push('/character/${info.characterId}/edit'));
      return;
    }

    // A new session belongs to exactly one variation and can never be moved
    // between them, so when the group has several, ask which one instead of
    // silently taking the most recently used.
    final charId = await _resolveNewSessionCharacter(
      context,
      ref,
      info,
      variants,
    );
    if (charId == null || !context.mounted) return;
    final hasSessions =
        (await ref
                .read(chatSessionOpsProvider.notifier)
                .getSessionMetadataByCharacter(charId))
            .isNotEmpty;
    if (!context.mounted) return;
    context.go(hasSessions ? '/chat/$charId?new=1' : '/chat/$charId');
  }

  /// The character a new session should be created for: the group's only
  /// variation, or the one the user picks. Null when the picker is dismissed.
  Future<String?> _resolveNewSessionCharacter(
    BuildContext context,
    WidgetRef ref,
    ChatSessionInfo info,
    List<Character> variants,
  ) async {
    if (variants.length < 2) return info.characterId;

    final sessionCounts =
        ref.read(characterSessionCountsProvider).value ?? const <String, int>{};
    final rootNav = Navigator.of(context, rootNavigator: true);
    return GlazeBottomSheet.show<String>(
      context,
      title: 'variation_pick_title'.tr(),
      items: [
        for (final variant in variants)
          BottomSheetItem(
            icon: Icons.person_outline_rounded,
            label: variantLabel(variant),
            hint: variantPickerHint(sessionCounts[variant.id] ?? 0),
            onTap: () => rootNav.pop(variant.id),
          ),
      ],
    );
  }

  /// Every variation of [groupId], cover first.
  ///
  /// Read from the library rather than from this group's sessions, so a
  /// variation you have never chatted with — the one most likely to be the
  /// point of starting a new session — is offered too.
  List<Character> _groupVariants(WidgetRef ref, String groupId) {
    final all = ref.read(charactersProvider).value ?? const <Character>[];
    final revealHidden = ref.read(revealHiddenCharactersProvider);
    return all
        .where(
          (c) =>
              (c.variantGroupId.isEmpty ? c.id : c.variantGroupId) == groupId &&
              (revealHidden || !c.hidden),
        )
        .toList()
      ..sort((a, b) => a.variantOrder.compareTo(b.variantOrder));
  }
}

/// The circular checkbox each row grows on its leading edge while a
/// multi-selection is running. Mirrors the character grid's selection mark.
class _SelectionCheck extends StatelessWidget {
  final bool selected;

  const _SelectionCheck({required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: selected ? context.cs.primary : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? context.cs.primary
              : context.cs.onSurfaceVariant.withValues(alpha: 0.6),
          width: 2,
        ),
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: 14, color: context.cs.onPrimary)
          : null,
    );
  }
}

/// A small solid dot marking an unread session in the chat list.
class _UnreadDot extends StatelessWidget {
  final Color color;
  const _UnreadDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// The last-message line replaced by a "writing" pencil + a "Generating…" label
/// while the session is generating. Mirrors the chat webview's typing indicator
/// (`.typing-container` / `pencil-write`) one-to-one.
class _GeneratingPreview extends StatelessWidget {
  const _GeneratingPreview();

  @override
  Widget build(BuildContext context) {
    final color = context.cs.onSurfaceVariant;
    return Row(
      children: [
        _WritingPencil(color: color),
        const SizedBox(width: 6),
        Text(
          'model_typing'.tr(),
          style: TextStyle(
            fontSize: 13,
            height: 16 / 13,
            fontStyle: FontStyle.italic,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// A pencil glyph that slides right as it "writes", then snaps back — a
/// one-to-one port of the chat webview's `pencil-write` keyframes
/// (`assets/chat_webview/styles.css`): 1.5s, ease-in-out, translateX steps
/// 0→5px across the first 75% of the cycle, then 5px→0.
class _WritingPencil extends StatefulWidget {
  final Color color;

  const _WritingPencil({required this.color});

  @override
  State<_WritingPencil> createState() => _WritingPencilState();
}

class _WritingPencilState extends State<_WritingPencil>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  late final Animation<double> _dx = TweenSequence<double>([
    // 0% → 75%: slide right 0 → 5px in 1px steps, each 15% of the cycle.
    for (int i = 0; i < 5; i++)
      TweenSequenceItem(
        tween: Tween<double>(
          begin: i.toDouble(),
          end: (i + 1).toDouble(),
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 15,
      ),
    // 75% → 100%: snap back 5px → 0.
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 5,
        end: 0,
      ).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 25,
    ),
  ]).animate(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _dx,
      builder: (context, child) =>
          Transform.translate(offset: Offset(_dx.value, 0), child: child),
      child: Icon(
        Icons.edit,
        size: 14,
        color: widget.color.withValues(alpha: 0.7),
      ),
    );
  }
}

/// Avatar-corner badge: pulsing typing dots while generating, else a static
/// unread dot. Bordered so it reads clearly against the avatar.
class _StatusBadge extends StatelessWidget {
  final bool generating;
  final Color color;
  final Color borderColor;

  const _StatusBadge({
    required this.generating,
    required this.color,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(generating ? 3 : 0),
      constraints: const BoxConstraints(minWidth: 12, minHeight: 12),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: 2),
      ),
      child: generating
          ? TypingDots(color: borderColor, size: 3)
          : const SizedBox(width: 8, height: 8),
    );
  }
}
