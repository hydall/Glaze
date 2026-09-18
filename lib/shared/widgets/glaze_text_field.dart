import 'package:flutter/material.dart';

class GlazeTextField extends StatelessWidget {
  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final bool obscureText;
  final int maxLines;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool readOnly;

  /// Focus of the field, for a caller that opens the field itself — a search
  /// bar that replaces a row has to take the caret with it.
  final FocusNode? focusNode;

  final bool autofocus;
  final TextInputAction? textInputAction;

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
    this.keyboardType,
    this.onChanged,
    this.onTap,
    this.readOnly = false,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction,
    this.isDense = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      obscureText: obscureText,
      maxLines: maxLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: onChanged,
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
