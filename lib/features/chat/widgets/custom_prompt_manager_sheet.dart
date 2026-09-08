import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../../core/services/memory_prompt_presets.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/theme/app_colors.dart';

class CustomPromptManagerSheet extends StatefulWidget {
  final List<MemoryPromptPreset> customPrompts;
  final ValueChanged<List<MemoryPromptPreset>> onChanged;

  const CustomPromptManagerSheet({
    super.key,
    required this.customPrompts,
    required this.onChanged,
  });

  @override
  State<CustomPromptManagerSheet> createState() => _CustomPromptManagerSheetState();
}

class _CustomPromptManagerSheetState extends State<CustomPromptManagerSheet> {
  late List<MemoryPromptPreset> _prompts;

  @override
  void initState() {
    super.initState();
    _prompts = List.of(widget.customPrompts);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "${'theme_custom_font_size'.tr()} ${'label_preset_prompts'.tr()}",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: context.cs.onSurface),
              ),
              IconButton(
                onPressed: _addPrompt,
                icon: Icon(Icons.add_rounded, color: context.cs.primary),
                tooltip: 'action_add'.tr(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_prompts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  "${'no_prompt'.tr()}...",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
                ),
              ),
            )
          else
            ...List.generate(_prompts.length, (i) => _promptTile(i)),
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
                style: FilledButton.styleFrom(
                  backgroundColor: context.cs.primary,
                  foregroundColor: Colors.black,
                ),
                onPressed: () {
                  widget.onChanged(_prompts);
                  Navigator.pop(context);
                },
                child: Text('btn_save'.tr()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _promptTile(int index) {
    final p = _prompts[index];
    return Card(
      color: Colors.white.withValues(alpha: 0.03),
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ListTile(
        title: Text(
          p.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: context.cs.onSurface),
        ),
        subtitle: Text(
          p.prompt.length > 80 ? '${p.prompt.substring(0, 80)}...' : p.prompt,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: () => _editPrompt(index),
              icon: Icon(Icons.edit_rounded, size: 18, color: context.cs.primary),
            ),
            IconButton(
              onPressed: () => _deletePrompt(index),
              icon: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red.shade300),
            ),
          ],
        ),
      ),
    );
  }

  void _addPrompt() async {
    final result = await GlazeBottomSheet.show<MemoryPromptPreset>(
      context,
      title: "${'btn_create'.tr()} ${'label_char_prompt'.tr()}",
      child: _PromptEditor(
        existingKeys: {...MemoryPromptPresets.builtIn.map((p) => p.key), ..._prompts.map((p) => p.key)},
      ),
    );
    if (result != null) {
      setState(() => _prompts.add(result));
    }
  }

  void _editPrompt(int index) async {
    final result = await GlazeBottomSheet.show<MemoryPromptPreset>(
      context,
      title: "${'action_edit'.tr()} ${'label_char_prompt'.tr()}",
      child: _PromptEditor(
        existingKeys: {...MemoryPromptPresets.builtIn.map((p) => p.key), ..._prompts.map((p) => p.key).where((k) => k != _prompts[index].key)},
        initial: _prompts[index],
      ),
    );
    if (result != null) {
      setState(() => _prompts[index] = result);
    }
  }

  void _deletePrompt(int index) {
    setState(() => _prompts.removeAt(index));
  }
}

class _PromptEditor extends StatefulWidget {
  final Set<String> existingKeys;
  final MemoryPromptPreset? initial;

  const _PromptEditor({required this.existingKeys, this.initial});

  @override
  State<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_PromptEditor> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _promptCtrl;
  String? _labelError;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController(text: widget.initial?.label ?? '');
    _promptCtrl = TextEditingController(text: widget.initial?.prompt ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initial != null;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isEdit ? "${'action_edit'.tr()} ${'label_char_prompt'.tr()}" : "${'btn_create'.tr()} ${'label_char_prompt'.tr()}",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: context.cs.onSurface),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _labelCtrl,
            onChanged: (_) => setState(() => _labelError = null),
            style: TextStyle(color: context.cs.onSurface, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'label_name'.tr(),
              labelStyle: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 12),
              errorText: _labelError,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _promptCtrl,
            maxLines: 10,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            style: TextStyle(color: context.cs.onSurface, fontSize: 13),
            decoration: InputDecoration(
              labelText: 'label_char_prompt'.tr(),
              hintText: 'chat_history_anchor_hint'.tr(),
              labelStyle: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 12),
              hintStyle: TextStyle(color: context.cs.onSurfaceVariant.withValues(alpha: 0.4)),
              alignLabelWithHint: true,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
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
                style: FilledButton.styleFrom(
                  backgroundColor: context.cs.primary,
                  foregroundColor: Colors.black,
                ),
                onPressed: _save,
                child: Text(isEdit ? 'btn_save'.tr() : 'btn_create'.tr()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _save() {
    final label = _labelCtrl.text.trim();
    if (label.isEmpty) {
      setState(() => _labelError = 'error_name_required'.tr());
      return;
    }
    final key = widget.initial?.key ?? 'custom_${DateTime.now().millisecondsSinceEpoch}';
    Navigator.pop(context, MemoryPromptPreset(key: key, label: label, prompt: _promptCtrl.text));
  }
}
