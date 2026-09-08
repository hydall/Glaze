import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../../core/models/memory_book.dart';
import '../../../shared/theme/app_colors.dart';

class MemoryEntryEditorSheet extends StatefulWidget {
  final MemoryEntry entry;

  const MemoryEntryEditorSheet({super.key, required this.entry});

  @override
  State<MemoryEntryEditorSheet> createState() => _MemoryEntryEditorSheetState();
}

class _MemoryEntryEditorSheetState extends State<MemoryEntryEditorSheet> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  late TextEditingController _keysController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.entry.title);
    _contentController = TextEditingController(text: widget.entry.content);
    _keysController = TextEditingController(text: widget.entry.keys.join(', '));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _keysController.dispose();
    super.dispose();
  }

  void _save() {
    final content = _contentController.text.trim();
    if (content.isEmpty) return;
    final keys = _keysController.text
        .split(',')
        .map((k) => k.trim().toLowerCase())
        .where((k) => k.isNotEmpty)
        .toList();
    final entry = widget.entry.copyWith(
      title: _titleController.text.trim(),
      content: content,
      keys: keys,
    );
    Navigator.pop(context, entry);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _field('label_block_name'.tr(), _titleController, hint: 'placeholder_block_name'.tr()),
          const SizedBox(height: 12),
          _field('search_type_keys'.tr(), _keysController, hint: 'hint_comma_separated'.tr()),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text('search_type_keys'.tr(), style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant.withValues(alpha: 0.6))),
          ),
          const SizedBox(height: 12),
          _field('label_content'.tr(), _contentController, hint: 'placeholder_lore_content'.tr(), maxLines: 8),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('btn_cancel'.tr()),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: context.cs.primary, foregroundColor: Colors.black),
                onPressed: _save,
                child: Text('btn_save'.tr()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController controller, {String? hint, int maxLines = 1}) {
    final isMultiline = maxLines > 1;
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: isMultiline ? TextInputType.multiline : null,
      textInputAction: isMultiline ? TextInputAction.newline : null,
      style: TextStyle(color: context.cs.onSurface, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 12),
        hintText: hint,
        hintStyle: TextStyle(color: context.cs.onSurfaceVariant.withValues(alpha: 0.4)),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
