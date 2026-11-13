import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../../shared/widgets/fullscreen_editor.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import 'memory/memory_books_controls.dart';

/// Editor for the text of a summary block, of the draft a regeneration left on
/// one, or of a new note.
///
/// The sheet a Memory Books entry or draft is edited in
/// (`MemoryEntryEditorSheet`) — the same field group, the same Cancel / Save
/// pair, a title naming the messages the block covers the way a memory entry
/// is named — with the one field a block has.
class SummaryBlockEditorSheet extends StatefulWidget {
  final String initialValue;

  /// Muted line under the field's label: what is being edited.
  final String? description;
  final String? placeholder;

  const SummaryBlockEditorSheet({
    super.key,
    required this.initialValue,
    this.description,
    this.placeholder,
  });

  /// The saved text, trimmed; null when the sheet was cancelled or dismissed.
  static Future<String?> show(
    BuildContext context, {
    required String title,
    String initialValue = '',
    String? description,
    String? placeholder,
  }) => GlazeBottomSheet.show<String>(
    context,
    title: title,
    child: SummaryBlockEditorSheet(
      initialValue: initialValue,
      description: description,
      placeholder: placeholder,
    ),
  );

  @override
  State<SummaryBlockEditorSheet> createState() =>
      _SummaryBlockEditorSheetState();
}

class _SummaryBlockEditorSheetState extends State<SummaryBlockEditorSheet> {
  /// Lines the field keeps, as the Memory Books body field does.
  static const _rows = 8;

  /// Everything in the desktop window besides the field's text: the title,
  /// the label and its description, the field's padding and the buttons.
  static const _chrome = 250.0;

  /// One line of the field's 15 px text.
  static const _lineHeight = 23.0;

  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// How far the field grows before it scrolls.
  ///
  /// A memory entry's body grows to 32 lines on desktop, below the title and
  /// key fields the window can be scrolled by. A summary has only its text, so
  /// a long block filled the window with one field whose own scrolling took
  /// the wheel, and Cancel / Save sat out of reach below it. On desktop the
  /// field stops where the window still shows the buttons; the expand button
  /// opens the full editor.
  int _maxLines(BuildContext context) {
    if (!isDesktopLayout(context)) return _rows;
    final window =
        MediaQuery.sizeOf(context).height * kGlazeSheetWindowHeightFactor;
    return ((window - _chrome) / _lineHeight).floor().clamp(_rows, 32);
  }

  Future<void> _expand() => FullscreenEditorScreen.show(
    context,
    title: 'label_content'.tr(),
    initialValue: _controller.text,
    hintText: widget.placeholder,
    onChanged: (value) {
      if (mounted) _controller.text = value;
    },
  );

  void _save() {
    final content = _controller.text.trim();
    if (content.isEmpty) {
      GlazeToast.show(context, 'memory_books_content_required'.tr());
      return;
    }
    Navigator.pop(context, content);
  }

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktopLayout(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MenuGroup(
          items: [
            MenuFieldItem(
              label: 'label_content'.tr(),
              description: widget.description,
              controller: _controller,
              placeholder: widget.placeholder,
              keyboardType: TextInputType.multiline,
              maxLines: _maxLines(context),
              minLines: desktop ? _rows : null,
              onExpand: _expand,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: MemoryEditorButton(
                  label: 'btn_cancel'.tr(),
                  onTap: () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: MemoryEditorButton(
                  label: 'btn_save'.tr(),
                  emphasised: true,
                  onTap: _save,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
