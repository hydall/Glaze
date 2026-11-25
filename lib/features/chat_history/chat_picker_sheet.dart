import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../shared/widgets/glaze_sheet.dart';
import '../../shared/widgets/picker_search_field.dart';
import '../../shared/widgets/sheet_view.dart';
import 'chat_history_list.dart';
import 'chat_history_provider.dart';

/// Opens the chat list — the same rows, grouping and order as the main Dialogs
/// screen — to pick one chat for a binding. Resolves to the picked session, or
/// null when dismissed. [excludedSessionIds] (already bound) are left out.
Future<ChatSessionInfo?> showChatPicker(
  BuildContext context, {
  required String title,
  Set<String> excludedSessionIds = const {},
}) {
  return showGlazeSheet<ChatSessionInfo>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        ChatPickerSheet(title: title, excludedSessionIds: excludedSessionIds),
  );
}

class ChatPickerSheet extends StatefulWidget {
  final String title;
  final Set<String> excludedSessionIds;

  const ChatPickerSheet({
    super.key,
    required this.title,
    this.excludedSessionIds = const {},
  });

  @override
  State<ChatPickerSheet> createState() => _ChatPickerSheetState();
}

class _ChatPickerSheetState extends State<ChatPickerSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: widget.title,
      // Opens nearly full height: the list is the whole point of the sheet.
      collapsedFraction: 0.92,
      headerBottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: PickerSearchField(
          controller: _searchCtrl,
          hint: 'search_dialogs'.tr(),
          onChanged: (v) => setState(() => _search = v.trim()),
        ),
      ),
      body: Builder(
        builder: (context) {
          final inset = MediaQuery.paddingOf(context);
          return ChatHistoryList(
            searchQuery: _search,
            topPadding: inset.top,
            bottomPadding: inset.bottom + 20,
            excludedSessionIds: widget.excludedSessionIds,
            onPick: (info) =>
                Navigator.of(context, rootNavigator: true).pop(info),
          );
        },
      ),
    );
  }
}
