import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/utils/time_formatter.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../chat_history/chat_history_provider.dart';
import '../chat_actions_service.dart';
import '../chat_provider.dart';
import '../generating_sessions_provider.dart';
import '../unread_sessions_provider.dart';

/// What the user picked in [showSessionPickerSheet]. Null means dismissed.
enum SessionPickerAction { open, newSession, importChat }

class SessionPickerResult {
  final SessionPickerAction action;

  /// The chosen session — set only for [SessionPickerAction.open].
  final ChatSessionInfo? session;

  const SessionPickerResult._(this.action, this.session);

  const SessionPickerResult.open(ChatSessionInfo session)
    : this._(SessionPickerAction.open, session);
  const SessionPickerResult.newSession()
    : this._(SessionPickerAction.newSession, null);
  const SessionPickerResult.importChat()
    : this._(SessionPickerAction.importChat, null);
}

/// The session picker, for every place that offers one.
///
/// The magic drawer and the character catalog both used to hand-roll this: the
/// drawer decoded whole sessions to render its own rows, the catalog listed
/// bare "Session #N" menu entries with a message count and nothing else, and
/// neither matched the chat list. They are the same list of the same rows —
/// only what a tap does differs — so they share this sheet, and it shows what
/// the chat list shows: session name, message count, relative time, an
/// origin-aware preview ("Created on …" / "Branched on …"), the unread dot, the
/// live "typing" line, and the same export / rename / delete actions (delete
/// behind the chat list's confirmation).
///
/// Resolves with the user's choice *after* the sheet has closed, so the caller
/// can navigate without chaining a second `Navigator.pop` onto the sheet's own
/// exit animation.
Future<SessionPickerResult?> showSessionPickerSheet(
  BuildContext context, {
  required String charId,
}) {
  return GlazeBottomSheet.show<SessionPickerResult>(
    context,
    title: 'history_title'.tr(),
    headerAction: _SessionPickerAddButton(charId: charId),
    child: SessionPickerList(charId: charId),
  );
}

/// Opens the new-session / import menu and, once a choice is made, resolves the
/// picker with it. Shared by the header's add button and the empty state's
/// centred create button, so the two cannot offer different choices.
Future<void> _showCreateMenu(BuildContext context) async {
  final rootNav = Navigator.of(context, rootNavigator: true);
  final action = await GlazeBottomSheet.show<SessionPickerAction>(
    context,
    title: 'action_new_session'.tr(),
    items: [
      BottomSheetItem(
        icon: Icons.add_circle_outline,
        label: 'action_new_session'.tr(),
        onTap: () => rootNav.pop(SessionPickerAction.newSession),
      ),
      BottomSheetItem(
        icon: Icons.file_download,
        label: 'action_import'.tr(),
        onTap: () => rootNav.pop(SessionPickerAction.importChat),
      ),
    ],
  );
  // Runs once the inner sheet's route is gone, so this pop closes the picker
  // rather than racing the menu's exit animation.
  if (action == SessionPickerAction.newSession) {
    rootNav.pop(const SessionPickerResult.newSession());
  } else if (action == SessionPickerAction.importChat) {
    rootNav.pop(const SessionPickerResult.importChat());
  }
}

class _SessionPickerAddButton extends ConsumerWidget {
  final String charId;

  const _SessionPickerAddButton({required this.charId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Hidden while the list is empty: the body shows a centred create button
    // in that state, and two add affordances would be one too many.
    if (ref.watch(characterSessionInfosProvider(charId)).isEmpty) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: Icon(Icons.add, color: context.cs.primary),
      onPressed: () => _showCreateMenu(context),
    );
  }
}

/// The rows of [showSessionPickerSheet]. Pops its route with a
/// [SessionPickerResult] when a session is tapped.
///
/// Reads [chatHistoryProvider] instead of querying the DB itself: the history
/// provider is warmed at startup and kept alive, so the picker opens populated
/// rather than flashing a spinner while it loads the same metadata a second
/// time.
class SessionPickerList extends ConsumerStatefulWidget {
  final String charId;

  const SessionPickerList({super.key, required this.charId});

  @override
  ConsumerState<SessionPickerList> createState() => _SessionPickerListState();
}

class _SessionPickerListState extends ConsumerState<SessionPickerList> {
  String _title(ChatSessionInfo session) {
    final name = session.sessionName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return 'session_name'.tr(
      namedArgs: {'id': (session.sessionIndex + 1).toString()},
    );
  }

  @override
  Widget build(BuildContext context) {
    // The history provider is the single source of truth for session metadata;
    // watching it keeps renaming and deleting in step, and so does a reply
    // landing in another session while the sheet is open.
    final sessionsAsync = ref.watch(chatHistoryProvider);

    return sessionsAsync.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: GlazeSpinner(),
        ),
      ),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Text('${'title_error'.tr()}: $error'),
        ),
      ),
      data: (all) {
        final sessions = [
          for (final session in all)
            if (session.characterId == widget.charId) session,
        ];
        if (sessions.isEmpty) return const _SessionPickerEmptyState();

        final activeSessionId = ref
            .watch(chatProvider(widget.charId))
            .value
            ?.session
            ?.id;
        final generatingSessions = ref.watch(generatingSessionsProvider);
        final unreadSessions = ref.watch(unreadSessionsProvider);

        return GlazeSessionList(
          items: [
            for (final session in sessions)
              _itemFor(
                session,
                activeSessionId: activeSessionId,
                generating: generatingSessions.contains(session.sessionId),
                unread: unreadSessions.contains(session.sessionId),
              ),
          ],
        );
      },
    );
  }

  BottomSheetSessionItem _itemFor(
    ChatSessionInfo session, {
    required String? activeSessionId,
    required bool generating,
    required bool unread,
  }) {
    final time = session.lastMessageTime;
    return BottomSheetSessionItem(
      title: _title(session),
      count: session.messageCount,
      time: time == 0 ? '' : formatSessionTimeAgo(time),
      preview: session.lastMessage.isEmpty
          ? 'No messages yet'
          : session.lastMessage,
      isActive: session.sessionId == activeSessionId,
      generating: generating,
      // A live reply supersedes the unread dot: the row already reads as
      // "active". Same rule as the chat list.
      unread: !generating && unread,
      onTap: () => Navigator.of(
        context,
        rootNavigator: true,
      ).pop(SessionPickerResult.open(session)),
      onMore: () => _showSessionActions(session),
    );
  }

  void _showSessionActions(ChatSessionInfo session) {
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
                sessionId: session.sessionId,
              );
        case 'rename':
          _showRenameDialog(session);
        case 'delete':
          _confirmDelete(session);
      }
    });
  }

  void _showRenameDialog(ChatSessionInfo session) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Rename Session',
      input: BottomSheetInput(
        placeholder: 'Session name',
        value: _title(session),
        confirmLabel: 'action_rename'.tr(),
        onConfirm: (val) {
          Navigator.of(context, rootNavigator: true).pop();
          if (val.trim().isEmpty) return;
          ref
              .read(chatHistoryProvider.notifier)
              .renameSession(session.sessionId, val.trim());
        },
      ),
    );
  }

  void _confirmDelete(ChatSessionInfo session) {
    // Deleting a chat is not undoable, so it confirms — the same sheet the
    // chat list uses. The drawer used to delete on the first tap.
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_delete_session'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description:
            '${'action_delete_session'.tr()} — ${_title(session)}? '
            '${'chat_clear_confirm'.tr()}',
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            // `deleteSession` rebinds the chat provider itself, so the open
            // chat can never be left pointing at the row that just went away.
            ref
                .read(chatHistoryProvider.notifier)
                .deleteSession(session.sessionId);
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
}

/// Shown instead of the list when the character has no sessions yet: a centred
/// create button, the same action the header's add button would offer.
class _SessionPickerEmptyState extends StatelessWidget {
  const _SessionPickerEmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 24, 40, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 20),
          Text(
            'no_dialogs'.tr(),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: context.cs.primary,
              foregroundColor: Colors.black,
            ),
            onPressed: () => _showCreateMenu(context),
            icon: const Icon(Icons.add, size: 20),
            label: Text('btn_create'.tr()),
          ),
        ],
      ),
    );
  }
}
