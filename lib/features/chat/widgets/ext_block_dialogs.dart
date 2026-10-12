import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../../../shared/widgets/glaze_text_field.dart';

/// Sheet helpers for editing / deleting an ext-block from the chat WebView's
/// ext-blocks panel. Extracted from `chat_webview_widget.dart` so the widget
/// doesn't have to carry the editor + confirmation plumbing inline.
class ExtBlockDialogs {
  const ExtBlockDialogs._();

  /// Show a multi-line editor seeded with [initialContent] and the
  /// given [blockName] in the title. Returns the user-entered
  /// content on save, or `null` on cancel.
  static Future<String?> promptEdit({
    required BuildContext context,
    required String blockName,
    required String initialContent,
  }) {
    return showGlazeSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ExtBlockEditSheet(
        blockName: blockName,
        initialContent: initialContent,
      ),
    );
  }

  /// Show a confirmation sheet for deleting the named ext-block.
  /// Returns `true` if the user confirmed, `false` otherwise.
  static Future<bool> confirmDelete({
    required BuildContext context,
    required String blockName,
  }) async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: '${'blocks_delete_block'.tr()} "$blockName"?',
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'ext_block_delete_confirm'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          centered: true,
          isDestructive: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    return confirmed == true;
  }
}

class _ExtBlockEditSheet extends StatefulWidget {
  final String blockName;
  final String initialContent;

  const _ExtBlockEditSheet({
    required this.blockName,
    required this.initialContent,
  });

  @override
  State<_ExtBlockEditSheet> createState() => _ExtBlockEditSheetState();
}

class _ExtBlockEditSheetState extends State<_ExtBlockEditSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: '${'action_edit'.tr()} "${widget.blockName}"',
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check, size: 22),
          tooltip: 'btn_save'.tr(),
          onPressed: _save,
        ),
      ],
      body: ListView(
        children: [
          const SizedBox(height: 8),
          GlazeTextField(
            controller: _controller,
            autofocus: true,
            maxLines: 16,
            hint: 'placeholder_empty'.tr(),
          ),
          const SizedBox(height: 16),
          GlazeActionButton(
            icon: Icons.check_rounded,
            label: 'btn_save'.tr(),
            tone: GlazeActionTone.primary,
            expand: true,
            onTap: _save,
          ),
        ],
      ),
    );
  }
}
