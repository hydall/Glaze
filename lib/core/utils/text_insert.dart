import 'package:flutter/widgets.dart';

/// Inserts [token] on both sides of the caret (or the current selection) and
/// leaves the caret between the pair.
///
/// Shared by the composer's insert buttons and the fullscreen editor's
/// formatting bar so the two cannot drift apart. A collapsed caret is wrapped
/// as an empty string, which is what puts the caret between the two tokens; a
/// non-empty selection is wrapped and the caret lands after it, which is what
/// the markdown delimiters are for. An invalid selection — the field has never
/// been focused — appends the pair at the end.
void insertSurroundingText(TextEditingController controller, String token) {
  if (token.isEmpty) return;
  final value = controller.value;
  final selection = value.selection;
  if (!selection.isValid) {
    controller.value = TextEditingValue(
      text: value.text + token + token,
      selection: TextSelection.collapsed(
        offset: value.text.length + token.length,
      ),
    );
    return;
  }
  final selected = value.text.substring(selection.start, selection.end);
  controller.value = TextEditingValue(
    text: value.text.replaceRange(
      selection.start,
      selection.end,
      '$token$selected$token',
    ),
    selection: TextSelection.collapsed(
      offset: selection.start + token.length + selected.length,
    ),
    composing: TextRange.empty,
  );
}
