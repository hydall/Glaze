import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/utils/avatar_image.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../core/state/character_provider.dart' show avatarVersionProvider;
import '../chat/chat_actions_service.dart';
import '../chat/chat_provider.dart';
import '../chat/generating_sessions_provider.dart';
import '../chat/unread_sessions_provider.dart';
import '../settings/app_settings_provider.dart';
import 'chat_history_provider.dart';
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

  const ChatHistoryList({
    super.key,
    this.collapsed = false,
    this.searchQuery = '',
    this.topPadding = 0,
    this.bottomPadding = 20,
    this.controller,
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
        final path = s.avatarPath;
        if (path == null || path.isEmpty) continue;
        if (!_precachedAvatars.add(path)) continue;
        precacheGlazeAvatar(context, path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(chatHistoryProvider);
    final settingsAsync = ref.watch(appSettingsProvider);

    return sessionsAsync.when(
      loading: () =>
          Center(child: CircularProgressIndicator(color: context.cs.primary)),
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
  final VoidCallback onTap;

  const _ChatHistoryGroupSection({
    required this.sessions,
    required this.isExpanded,
    required this.onTap,
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

  /// Row position within its list — staggers the fade-in so rows cascade in
  /// on load instead of popping in all at once. Capped below so long lists
  /// don't take forever to finish appearing.
  final int index;

  const _SessionTile({
    required this.info,
    this.isGrouped = false,
    this.collapsed = false,
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
    final Widget tile = widget.collapsed
        ? _buildCollapsedTile(context, ref, generating, unread)
        : widget.isGrouped
        ? _buildGroupedTile(context, ref, generating, unread)
        : _buildFullTile(context, ref, generating, unread);

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
    bool unread,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          context.go('/chat/${info.characterId}?session=${info.sessionIndex}'),
      onLongPress: () => _showSessionActions(context, ref),
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
    );
  }

  Widget _buildGroupedTile(
    BuildContext context,
    WidgetRef ref,
    bool generating,
    bool unread,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          context.go('/chat/${info.characterId}?session=${info.sessionIndex}'),
      onLongPress: () => _showSessionActions(context, ref),
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                                    'id': (info.sessionIndex + 1).toString(),
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
                      // Inside a group the rows are sessions of possibly
                      // different variations, so each one names its own.
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
    );
  }

  String _formatTime() {
    if (info.lastMessageTime == 0) return '';
    return formatTimeAgo(info.lastMessageTime);
  }

  void _showRenameDialog(BuildContext context, WidgetRef ref) {
    final currentName = info.sessionName?.isNotEmpty == true
        ? info.sessionName!
        : 'session_name'.tr(
            namedArgs: {'id': (info.sessionIndex + 1).toString()},
          );
    GlazeBottomSheet.show<void>(
      context,
      title: 'Rename Session',
      input: BottomSheetInput(
        placeholder: 'Session name',
        value: currentName,
        confirmLabel: 'action_rename'.tr(),
        onConfirm: (val) {
          Navigator.of(context, rootNavigator: true).pop();
          if (val.trim().isNotEmpty) {
            ref
                .read(chatHistoryProvider.notifier)
                .renameSession(info.sessionId, val.trim());
            ref.invalidate(chatProvider(info.characterId));
          }
        },
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_delete_session'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description:
            '${'action_delete_session'.tr()} \u2014 ${info.fullCharacterName}? ${'chat_clear_confirm'.tr()}',
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref
                .read(chatHistoryProvider.notifier)
                .deleteSession(info.sessionId);
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  void _showSessionActions(BuildContext context, WidgetRef ref) {
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
    ).then((result) {
      if (!context.mounted) return;
      switch (result) {
        case 'export':
          ref
              .read(chatActionsServiceProvider)
              .exportSessionUI(
                context,
                charId: info.characterId,
                sessionId: info.sessionId,
              );
        case 'rename':
          _showRenameDialog(context, ref);
        case 'delete':
          _confirmDelete(context, ref);
      }
    });
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
    final image = glazeAvatarImage(info.avatarPath);
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

  void _showGroupActions(
    BuildContext context,
    WidgetRef ref,
    ChatSessionInfo info,
  ) {
    // The group can span several variations; both actions target the most
    // recently used one, so name it — otherwise "New session" on a group of
    // four silently picks one of them.
    final spansVariations = _variantCount() > 1;
    final variantHint = spansVariations
        ? (info.variantName ?? 'variation_original'.tr())
        : info.variantName;
    GlazeBottomSheet.show<String>(
      context,
      title: info.characterName,
      items: [
        BottomSheetItem(
          icon: Icons.add_comment_outlined,
          label: 'action_new_session'.tr(),
          hint: variantHint,
          onTap: () => Navigator.of(context, rootNavigator: true).pop('new'),
        ),
        BottomSheetItem(
          icon: Icons.edit_note_rounded,
          label: 'action_edit_character'.tr(),
          hint: variantHint,
          onTap: () => Navigator.of(context, rootNavigator: true).pop('edit'),
        ),
      ],
    ).then((result) {
      if (!context.mounted) return;
      if (result == 'new') {
        ref.read(chatProvider(info.characterId).notifier).createNewSession();
        context.go('/chat/${info.characterId}');
      } else if (result == 'edit') {
        context.push('/character/${info.characterId}/edit');
      }
    });
  }
}

/// Pill naming the variation a chat belongs to.
///
/// A chip rather than a `"Name — Variation"` suffix on purpose: the suffix was
/// the last thing on a single-line, ellipsized row, so the part that told two
/// otherwise identical rows apart was the first part to be cut off.
class VariationChip extends StatelessWidget {
  final String name;

  const VariationChip({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 110),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: context.cs.primary,
        ),
      ),
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

String formatTimeAgo(int epochMs) {
  final now = DateTime.now();
  final diff = now.difference(DateTime.fromMillisecondsSinceEpoch(epochMs));
  if (diff.inMinutes < 1) return 'now';
  if (diff.inHours < 1) return '${diff.inMinutes}m';
  if (diff.inDays < 1) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return '${diff.inDays ~/ 7}w';
}
