import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../../core/services/memory_prompt_presets.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/theme/app_colors.dart';

class CustomPromptManagerSheet extends StatefulWidget {
  final List<MemoryPromptPreset> customPrompts;

  /// The read-only prompts shown above the custom ones, and the keys a new
  /// one may not collide with. Defaults to the Memory Books set; the summary
  /// settings pass their own.
  final List<MemoryPromptPreset> builtIn;

  /// Heading of the sheet. Defaults to the Memory Books one.
  final String? title;

  const CustomPromptManagerSheet({
    super.key,
    required this.customPrompts,
    this.builtIn = MemoryPromptPresets.builtIn,
    this.title,
  });

  @override
  State<CustomPromptManagerSheet> createState() =>
      _CustomPromptManagerSheetState();
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
                widget.title ?? 'memory_prompt_presets_title'.tr(),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.cs.onSurface,
                ),
              ),
              IconButton(
                onPressed: _addPrompt,
                icon: Icon(Icons.add_rounded, color: context.cs.primary),
                tooltip: 'action_add'.tr(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _sectionLabel('memory_prompt_built_in'.tr()),
          ...widget.builtIn.map(_builtInTile),
          const SizedBox(height: 12),
          _sectionLabel('memory_prompt_custom'.tr()),
          if (_prompts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'memory_prompt_no_custom'.tr(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                  ),
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
                key: const Key('memory_prompt_manager_save'),
                style: FilledButton.styleFrom(
                  backgroundColor: context.cs.primary,
                  foregroundColor: Colors.black,
                ),
                onPressed: () {
                  final result = List<MemoryPromptPreset>.unmodifiable(
                    _prompts,
                  );
                  Navigator.pop<List<MemoryPromptPreset>>(context, result);
                },
                child: Text('btn_save'.tr()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      label,
      style: TextStyle(
        color: context.cs.onSurfaceVariant,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _builtInTile(MemoryPromptPreset preset) {
    return Card(
      key: Key('memory_prompt_builtin_${preset.key}'),
      color: Colors.white.withValues(alpha: 0.03),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => _viewBuiltIn(preset),
        leading: Icon(Icons.lock_outline_rounded, color: context.cs.primary),
        title: Text(preset.label),
        subtitle: Text('memory_prompt_read_only'.tr()),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }

  Widget _promptTile(int index) {
    final p = _prompts[index];
    return Card(
      key: Key('memory_prompt_custom_${p.key}'),
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
              key: Key('memory_prompt_edit_${p.key}'),
              onPressed: () => _editPrompt(index),
              icon: Icon(
                Icons.edit_rounded,
                size: 18,
                color: context.cs.primary,
              ),
            ),
            IconButton(
              key: Key('memory_prompt_delete_${p.key}'),
              onPressed: () => _deletePrompt(index),
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 18,
                color: Colors.red.shade300,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _viewBuiltIn(MemoryPromptPreset preset) async {
    final copy = await GlazeBottomSheet.show<bool>(
      context,
      title: preset.label,
      child: MemoryPromptPreviewSheet(preset: preset, allowCopy: true),
    );
    if (!mounted) return;
    if (copy == true) await _copyPrompt(preset);
  }

  Future<void> _copyPrompt(MemoryPromptPreset preset) async {
    final result = await GlazeBottomSheet.show<MemoryPromptPreset>(
      context,
      title: 'memory_prompt_copy_as_new'.tr(),
      child: _PromptEditor(
        existingKeys: {
          ...widget.builtIn.map((p) => p.key),
          ..._prompts.map((p) => p.key),
        },
        initial: preset,
        preserveInitialKey: false,
      ),
    );
    if (!mounted) return;
    if (result != null) setState(() => _prompts.add(result));
  }

  void _addPrompt() async {
    final result = await GlazeBottomSheet.show<MemoryPromptPreset>(
      context,
      title: 'memory_prompt_create'.tr(),
      child: _PromptEditor(
        existingKeys: {
          ...widget.builtIn.map((p) => p.key),
          ..._prompts.map((p) => p.key),
        },
      ),
    );
    if (!mounted) return;
    if (result != null) {
      setState(() => _prompts.add(result));
    }
  }

  void _editPrompt(int index) async {
    final result = await GlazeBottomSheet.show<MemoryPromptPreset>(
      context,
      title: 'memory_prompt_edit'.tr(),
      child: _PromptEditor(
        existingKeys: {
          ...widget.builtIn.map((p) => p.key),
          ..._prompts.map((p) => p.key).where((k) => k != _prompts[index].key),
        },
        initial: _prompts[index],
      ),
    );
    if (!mounted) return;
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
  final bool preserveInitialKey;

  const _PromptEditor({
    required this.existingKeys,
    this.initial,
    this.preserveInitialKey = true,
  });

  @override
  State<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_PromptEditor> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _promptCtrl;
  String? _labelError;
  String? _promptError;

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
            (isEdit ? 'memory_prompt_edit' : 'memory_prompt_create').tr(),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('memory_prompt_name_field'),
            controller: _labelCtrl,
            onChanged: (_) => setState(() => _labelError = null),
            style: TextStyle(color: context.cs.onSurface, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'label_name'.tr(),
              labelStyle: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 12,
              ),
              errorText: _labelError,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('memory_prompt_body_field'),
            controller: _promptCtrl,
            onChanged: (_) => setState(() => _promptError = null),
            maxLines: 10,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            style: TextStyle(color: context.cs.onSurface, fontSize: 13),
            decoration: InputDecoration(
              labelText: 'memory_prompt_body'.tr(),
              hintText: 'memory_prompt_body_hint'.tr(),
              errorText: _promptError,
              labelStyle: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 12,
              ),
              hintStyle: TextStyle(
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.4),
              ),
              alignLabelWithHint: true,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
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
                key: const Key('memory_prompt_editor_save'),
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
    final prompt = _promptCtrl.text.trim();
    if (prompt.isEmpty) {
      setState(() => _promptError = 'memory_prompt_required'.tr());
      return;
    }
    final key = widget.preserveInitialKey && widget.initial != null
        ? widget.initial!.key
        : _newCustomKey();
    Navigator.pop(
      context,
      MemoryPromptPreset(key: key, label: label, prompt: prompt),
    );
  }

  String _newCustomKey() {
    final base = DateTime.now().microsecondsSinceEpoch;
    var suffix = 0;
    var key = 'custom_$base';
    while (widget.existingKeys.contains(key)) {
      key = 'custom_${base}_${++suffix}';
    }
    return key;
  }
}

class MemoryPromptPreviewSheet extends StatelessWidget {
  final MemoryPromptPreset preset;
  final bool allowCopy;

  const MemoryPromptPreviewSheet({
    super.key,
    required this.preset,
    this.allowCopy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(
              child: SelectableText(
                preset.prompt,
                key: const Key('memory_prompt_preview_text'),
                style: TextStyle(color: context.cs.onSurface, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('btn_close'.tr()),
              ),
              if (allowCopy) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const Key('memory_prompt_copy_as_new'),
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: Text('memory_prompt_copy_as_new'.tr()),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
