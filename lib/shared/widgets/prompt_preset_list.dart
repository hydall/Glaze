import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/services/memory_prompt_presets.dart';
import '../state/preset_sort.dart';
import '../theme/app_colors.dart';
import 'glaze_bottom_sheet.dart';
import 'glaze_list_item.dart';
import 'list_controls.dart';

/// The one place a list of prompt presets is rendered, whether the reader is
/// managing them (Memory Books / Summary settings) or just picking one.
///
/// Memory Books and Summary each ship their own read-only built-in set, so the
/// element is handed both lists. Built-ins are templates: they can be previewed
/// and duplicated ("Copy as new"), never edited or deleted — only the custom
/// presets are editable. Sorting reuses the shared [PresetSortMode] vocabulary;
/// "date added" reads a custom preset's position in the saved list as its age,
/// because [MemoryPromptPreset] carries no timestamp of its own.
enum PromptPresetListMode { manage, pick }

class PromptPresetList extends StatefulWidget {
  final List<MemoryPromptPreset> builtIn;
  final List<MemoryPromptPreset> custom;
  final PromptPresetListMode mode;

  /// Heading shown above the built-in section. Defaults to the Memory Books
  /// one; the Summary settings pass their own.
  final String? title;

  /// Key of the entry shown as active / currently selected (pick mode).
  final String? activeKey;

  /// Fires when a row is chosen in [PromptPresetListMode.pick].
  final ValueChanged<MemoryPromptPreset>? onPick;

  /// Fires with the edited custom list when Save is pressed in
  /// [PromptPresetListMode.manage].
  final ValueChanged<List<MemoryPromptPreset>>? onSave;

  const PromptPresetList({
    super.key,
    required this.builtIn,
    required this.custom,
    this.mode = PromptPresetListMode.manage,
    this.title,
    this.activeKey,
    this.onPick,
    this.onSave,
  });

  @override
  State<PromptPresetList> createState() => _PromptPresetListState();
}

class _PromptPresetListState extends State<PromptPresetList> {
  late List<MemoryPromptPreset> _prompts;
  PresetSortMode _sortMode = PresetSortMode.manual;

  bool get _manage => widget.mode == PromptPresetListMode.manage;

  @override
  void initState() {
    super.initState();
    _prompts = List.of(widget.custom);
  }

  /// The custom section in the order the picked sort mode shows it. Manual
  /// keeps the list's own order — the one dragging and saving act on.
  List<MemoryPromptPreset> get _visibleCustom {
    switch (_sortMode) {
      case PresetSortMode.manual:
        return _prompts;
      case PresetSortMode.alphabetical:
        final sorted = List.of(_prompts)
          ..sort(
            (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
          );
        return sorted;
      case PresetSortMode.dateAdded:
        // Presets are appended as they are created, so the last is the newest.
        return _prompts.reversed.toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            title: widget.title ?? 'memory_prompt_presets_title'.tr(),
            sortMode: _sortMode,
            manage: _manage,
            onSortChanged: (mode) => setState(() => _sortMode = mode),
            onAdd: _manage ? _addPrompt : null,
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
            _customList(),
          if (_manage) ...[
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
                  onPressed: _save,
                  child: Text('btn_save'.tr()),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Custom presets. In the manual mode they are drag-ordered; the other modes
  /// show a plain list, because dragging would fight the order on screen.
  Widget _customList() {
    final visible = _visibleCustom;
    // Only the manage sheet has an order worth dragging into; a picker just
    // lists what is available.
    if (!_manage || _sortMode != PresetSortMode.manual) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [for (final p in visible) _customTile(p)],
      );
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: visible.length,
      onReorderItem: _onReorder,
      itemBuilder: (_, i) => ReorderableDelayedDragStartListener(
        key: ValueKey(visible[i].key),
        index: i,
        child: _customTile(visible[i]),
      ),
    );
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final moved = _prompts.removeAt(oldIndex);
      _prompts.insert(newIndex, moved);
    });
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

  /// The read-only preset: locked, previewable, and duplicated into a custom
  /// one. Tap never edits it, in either mode.
  Widget _builtInTile(MemoryPromptPreset preset) {
    return GlazeListItem(
      key: Key('memory_prompt_builtin_${preset.key}'),
      leading: GlazeListIcon(
        icon: Icons.lock_outline_rounded,
        color: context.cs.primary,
      ),
      title: preset.label,
      subtitle: _manage
          ? 'memory_prompt_read_only'.tr()
          : _excerpt(preset.prompt),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: context.cs.onSurfaceVariant,
      ),
      isActive: widget.activeKey == preset.key,
      onTap: () => _onBuiltInTap(preset),
    );
  }

  Widget _customTile(MemoryPromptPreset p) {
    return GlazeListItem(
      key: Key('memory_prompt_custom_${p.key}'),
      leading: GlazeListIcon(icon: Icons.tune_rounded),
      title: p.label,
      subtitle: _excerpt(p.prompt),
      isActive: widget.activeKey == p.key,
      onTap: _manage ? null : () => _pick(p),
      trailing: _manage
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('memory_prompt_edit_${p.key}'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _editPrompt(p),
                  icon: Icon(
                    Icons.edit_rounded,
                    size: 18,
                    color: context.cs.primary,
                  ),
                ),
                IconButton(
                  key: Key('memory_prompt_delete_${p.key}'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _deletePrompt(p),
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: Colors.red.shade300,
                  ),
                ),
              ],
            )
          : Icon(
              Icons.chevron_right_rounded,
              color: context.cs.onSurfaceVariant,
            ),
    );
  }

  Future<void> _onBuiltInTap(MemoryPromptPreset preset) async {
    if (!_manage) {
      _pick(preset);
      return;
    }
    final copy = await GlazeBottomSheet.show<bool>(
      context,
      title: preset.label,
      child: MemoryPromptPreviewSheet(preset: preset, allowCopy: true),
    );
    if (!mounted) return;
    if (copy == true) await _copyPrompt(preset);
  }

  void _pick(MemoryPromptPreset preset) {
    Navigator.pop(context);
    widget.onPick?.call(preset);
  }

  Future<void> _copyPrompt(MemoryPromptPreset preset) async {
    final result = await GlazeBottomSheet.show<MemoryPromptPreset>(
      context,
      title: 'memory_prompt_copy_as_new'.tr(),
      child: _PromptEditor(
        existingKeys: _existingKeys(),
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
      child: _PromptEditor(existingKeys: _existingKeys()),
    );
    if (!mounted) return;
    if (result != null) setState(() => _prompts.add(result));
  }

  void _editPrompt(MemoryPromptPreset preset) async {
    final result = await GlazeBottomSheet.show<MemoryPromptPreset>(
      context,
      title: 'memory_prompt_edit'.tr(),
      child: _PromptEditor(
        existingKeys: _existingKeys()..remove(preset.key),
        initial: preset,
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      final index = _prompts.indexWhere((p) => p.key == preset.key);
      if (index >= 0) _prompts[index] = result;
    });
  }

  void _deletePrompt(MemoryPromptPreset preset) {
    setState(() => _prompts.removeWhere((p) => p.key == preset.key));
  }

  Set<String> _existingKeys() => {
    ...widget.builtIn.map((p) => p.key),
    ..._prompts.map((p) => p.key),
  };

  void _save() {
    widget.onSave?.call(List<MemoryPromptPreset>.unmodifiable(_prompts));
    Navigator.pop(context, _prompts);
  }

  static String _excerpt(String prompt) =>
      prompt.length > 80 ? '${prompt.substring(0, 80)}...' : prompt;
}

/// Opens the same prompt-preset list in pick mode, so the memory and summary
/// pickers show the read-only built-ins and the custom presets exactly as the
/// manage sheet does.
Future<void> showPromptPresetPicker(
  BuildContext context, {
  required List<MemoryPromptPreset> builtIn,
  required List<MemoryPromptPreset> custom,
  required String? activeKey,
  required ValueChanged<MemoryPromptPreset> onPick,
  String? title,
}) {
  return GlazeBottomSheet.show<void>(
    context,
    title: title,
    child: PromptPresetList(
      builtIn: builtIn,
      custom: custom,
      mode: PromptPresetListMode.pick,
      activeKey: activeKey,
      onPick: onPick,
    ),
  );
}

class _Header extends StatelessWidget {
  final String title;
  final PresetSortMode sortMode;
  final bool manage;
  final ValueChanged<PresetSortMode> onSortChanged;
  final VoidCallback? onAdd;

  const _Header({
    required this.title,
    required this.sortMode,
    required this.manage,
    required this.onSortChanged,
    this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
        ),
        GlazeSortIconChip(
          icon: sortMode.icon,
          tooltip: sortMode.label,
          onTap: () => showPresetSortPicker(
            context,
            current: sortMode,
            onSelect: onSortChanged,
          ),
        ),
        if (manage) ...[
          const SizedBox(width: 4),
          IconButton(
            onPressed: onAdd,
            icon: Icon(Icons.add_rounded, color: context.cs.primary),
            tooltip: 'action_add'.tr(),
          ),
        ],
      ],
    );
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
