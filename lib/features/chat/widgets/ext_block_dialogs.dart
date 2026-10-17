import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../extensions/models/block_config.dart';
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

  /// Asks which of [blocks] should rewrite a message, and optionally which
  /// fragment of it and with what extra instruction — the original's
  /// selection popup. Returns `null` on cancel.
  static Future<ExtBlockRewriteRequest?> promptRewrite({
    required BuildContext context,
    required List<BlockConfig> blocks,
  }) {
    return showGlazeSheet<ExtBlockRewriteRequest>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ExtBlockRewriteSheet(blocks: blocks),
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

/// What the rewrite sheet asked for. An empty [fragment] means the whole
/// message.
typedef ExtBlockRewriteRequest = ({
  String blockId,
  String fragment,
  String additionalPrompt,
});

class _ExtBlockRewriteSheet extends StatefulWidget {
  final List<BlockConfig> blocks;

  const _ExtBlockRewriteSheet({required this.blocks});

  @override
  State<_ExtBlockRewriteSheet> createState() => _ExtBlockRewriteSheetState();
}

class _ExtBlockRewriteSheetState extends State<_ExtBlockRewriteSheet> {
  final _fragment = TextEditingController();
  final _additionalPrompt = TextEditingController();
  late String _blockId = widget.blocks.first.id;

  @override
  void dispose() {
    _fragment.dispose();
    _additionalPrompt.dispose();
    super.dispose();
  }

  void _run() => Navigator.of(context).pop((
    blockId: _blockId,
    fragment: _fragment.text,
    additionalPrompt: _additionalPrompt.text,
  ));

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: 'extblocks_rewrite_title'.tr(),
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final block in widget.blocks)
                ChoiceChip(
                  label: Text(block.name),
                  selected: block.id == _blockId,
                  onSelected: (_) => setState(() => _blockId = block.id),
                ),
            ],
          ),
          const SizedBox(height: 16),
          GlazeTextField(
            controller: _fragment,
            label: 'extblocks_rewrite_fragment'.tr(),
            hint: 'extblocks_rewrite_fragment_hint'.tr(),
            minLines: 2,
            maxLines: 8,
          ),
          const SizedBox(height: 12),
          GlazeTextField(
            controller: _additionalPrompt,
            label: 'extblocks_rewrite_additional_prompt'.tr(),
            hint: 'extblocks_rewrite_additional_prompt_hint'.tr(),
            minLines: 2,
            maxLines: 6,
          ),
          const SizedBox(height: 16),
          GlazeActionButton(
            icon: Icons.auto_fix_high_rounded,
            label: 'extblocks_rewrite_run'.tr(),
            tone: GlazeActionTone.primary,
            expand: true,
            onTap: _run,
          ),
        ],
      ),
    );
  }
}
