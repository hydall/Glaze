import 'package:flutter/material.dart';

class GlazeTextField extends StatelessWidget {
  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final bool obscureText;
  final int maxLines;

  /// Lines the field keeps even when empty; with a larger [maxLines] the field
  /// grows with its text up to that many lines before it scrolls.
  final int? minLines;

  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool readOnly;

  /// False greys the field out and drops the caret; the caller's `onChanged`
  /// never fires. Used by a form whose fields wait on an in-flight request.
  final bool enabled;

  /// Focus of the field, for a caller that opens the field itself — a search
  /// bar that replaces a row has to take the caret with it.
  final FocusNode? focusNode;

  final bool autofocus;
  final TextInputAction? textInputAction;

  /// Passed through to the field — a key or identifier input turns both off so
  /// the platform keyboard stops capitalising and suggesting.
  final bool autocorrect;
  final bool enableSuggestions;

  final ValueChanged<String>? onSubmitted;

  /// Trims the field's vertical padding, for a field that has to sit at the
  /// height of the control it replaces rather than at form height.
  final bool isDense;

  const GlazeTextField({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.obscureText = false,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.onChanged,
    this.onTap,
    this.readOnly = false,
    this.enabled = true,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.onSubmitted,
    this.isDense = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      enabled: enabled,
      obscureText: obscureText,
      maxLines: maxLines,
      minLines: minLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      onTap: onTap,
      readOnly: readOnly,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: isDense,
      ),
    );
  }
}
