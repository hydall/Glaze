import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';

/// Single-field name input for creating or renaming a folder. Shown via
/// `GlazeBottomSheet.show(title:…, child: FolderNameDialog(...))`.
class FolderNameDialog extends StatefulWidget {
  final String? initialName;
  final String confirmLabel;
  final ValueChanged<String> onSubmit;

  const FolderNameDialog({
    super.key,
    this.initialName,
    required this.confirmLabel,
    required this.onSubmit,
  });

  @override
  State<FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<FolderNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    widget.onSubmit(name);
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            style: TextStyle(fontSize: 14, color: context.cs.onSurface),
            decoration: InputDecoration(
              hintText: 'folder_name_hint'.tr(),
              hintStyle: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 14,
              ),
              filled: true,
              fillColor: context.cs.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: context.cs.primary,
                foregroundColor: context.cs.onPrimary,
              ),
              child: Text(
                widget.confirmLabel,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
