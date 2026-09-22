import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../image_gen_models.dart';

/// Workflow library for ComfyUI.
///
/// A named list of API-format graphs plus the shipped default, following the
/// prompt-preset manager: one row per workflow, tap to make it active,
/// trailing edit/delete, and a header action that imports a graph exported
/// from ComfyUI's "Export Workflow (API)".
class ComfyUiWorkflowSheet extends StatefulWidget {
  const ComfyUiWorkflowSheet({
    super.key,
    required this.settings,
    required this.onUpdate,
  });

  final ComfyUiImageSettings settings;
  final ValueChanged<ComfyUiImageSettings> onUpdate;

  @override
  State<ComfyUiWorkflowSheet> createState() => _ComfyUiWorkflowSheetState();
}

class _ComfyUiWorkflowSheetState extends State<ComfyUiWorkflowSheet> {
  late ComfyUiImageSettings _settings = widget.settings;

  void _update(ComfyUiImageSettings next) {
    setState(() => _settings = next);
    widget.onUpdate(next);
  }

  void _select(String id) => _update(_settings.copyWith(activeWorkflowId: id));

  Future<void> _import() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    try {
      final bytes =
          picked.bytes ??
          (picked.path == null ? null : await File(picked.path!).readAsBytes());
      if (bytes == null) return;
      final text = utf8.decode(bytes).trim();
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        _showInvalid();
        return;
      }
      final workflow = ComfyUiWorkflow(
        id: _newWorkflowId(),
        name: _nameFromFile(picked.name),
        json: text,
      );
      _update(
        _settings.copyWith(
          workflows: [..._settings.workflows, workflow],
          activeWorkflowId: workflow.id,
        ),
      );
      if (mounted) GlazeToast.show(context, 'imggen_comfyui_imported'.tr());
    } catch (_) {
      _showInvalid();
    }
  }

  Future<void> _add() async {
    final result = await GlazeBottomSheet.show<ComfyUiWorkflow>(
      context,
      title: 'imggen_comfyui_workflow_new'.tr(),
      child: _WorkflowEditor(
        name: 'imggen_comfyui_workflow_custom'.tr(),
        json: ComfyUiConstants.defaultWorkflow,
      ),
    );
    if (!mounted || result == null) return;
    _update(
      _settings.copyWith(
        workflows: [..._settings.workflows, result],
        activeWorkflowId: result.id,
      ),
    );
  }

  Future<void> _edit(ComfyUiWorkflow workflow) async {
    final result = await GlazeBottomSheet.show<ComfyUiWorkflow>(
      context,
      title: 'imggen_comfyui_workflow_edit'.tr(),
      child: _WorkflowEditor(name: workflow.name, json: workflow.json),
    );
    if (!mounted || result == null) return;
    _update(
      _settings.copyWith(
        workflows: [
          for (final entry in _settings.workflows)
            if (entry.id == workflow.id)
              result.copyWith(id: workflow.id)
            else
              entry,
        ],
      ),
    );
  }

  void _delete(ComfyUiWorkflow workflow) {
    _update(
      _settings.copyWith(
        workflows: _settings.workflows
            .where((entry) => entry.id != workflow.id)
            .toList(),
        activeWorkflowId: _settings.activeWorkflowId == workflow.id
            ? ''
            : _settings.activeWorkflowId,
      ),
    );
  }

  void _showInvalid() {
    if (!mounted) return;
    GlazeToast.show(context, 'imggen_comfyui_invalid'.tr(), isError: true);
  }

  @override
  Widget build(BuildContext context) {
    final activeId = _settings.activeWorkflowId;
    // A stale id (its workflow was deleted) falls back to the default graph,
    // exactly as the provider does — so the default reads as selected then too.
    final usesDefault = _settings.activeWorkflow == null;
    return SheetView(
      title: 'imggen_comfyui_workflows'.tr(),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.file_open_outlined),
          tooltip: 'imggen_comfyui_import'.tr(),
          onPressed: _import,
        ),
        SheetViewAction(
          icon: const Icon(Icons.add),
          tooltip: 'imggen_comfyui_workflow_add'.tr(),
          onPressed: _add,
        ),
      ],
      fitContent: false,
      enableHeaderBlur: false,
      // Built under the sheet's own MediaQuery, whose top padding is the
      // measured header height — the outer context only carries the status-bar
      // inset, so the first row would start underneath the header without it.
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + 12,
            bottom: MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            MenuGroup(
              header: 'imggen_comfyui_workflow_default'.tr(),
              items: [
                MenuItem(
                  icon: usesDefault ? Icons.check : Icons.account_tree_outlined,
                  label: 'imggen_comfyui_workflow_default'.tr(),
                  subtitle: 'imggen_comfyui_workflow_default_desc'.tr(),
                  onTap: () => _select(''),
                ),
              ],
            ),
            if (_settings.workflows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'imggen_comfyui_workflow_empty'.tr(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              )
            else
              MenuGroup(
                header: 'imggen_comfyui_workflow_custom'.tr(),
                items: [
                  for (final workflow in _settings.workflows)
                    MenuItem(
                      icon: workflow.id == activeId
                          ? Icons.check
                          : Icons.account_tree_outlined,
                      label: workflow.name,
                      subtitle: _preview(workflow.json),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            tooltip: 'imggen_comfyui_workflow_edit'.tr(),
                            onPressed: () => _edit(workflow),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: 'imggen_comfyui_workflow_delete'.tr(),
                            onPressed: () => _delete(workflow),
                          ),
                        ],
                      ),
                      onTap: () => _select(workflow.id),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _preview(String json) {
    final compact = json.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return 'imggen_comfyui_workflow_default'.tr();
    return compact.length > 80 ? '${compact.substring(0, 80)}…' : compact;
  }

  static String _nameFromFile(String fileName) {
    final base = fileName.replaceFirst(
      RegExp(r'\.json$', caseSensitive: false),
      '',
    );
    return base.trim().isEmpty
        ? 'imggen_comfyui_workflow_custom'.tr()
        : base.trim();
  }
}

String _newWorkflowId() => 'workflow-${DateTime.now().microsecondsSinceEpoch}';

/// Name + JSON editor for one workflow, shown from the library sheet.
class _WorkflowEditor extends StatefulWidget {
  const _WorkflowEditor({required this.name, required this.json});

  final String name;
  final String json;

  @override
  State<_WorkflowEditor> createState() => _WorkflowEditorState();
}

class _WorkflowEditorState extends State<_WorkflowEditor> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.name,
  );
  late final TextEditingController _jsonController = TextEditingController(
    text: widget.json,
  );
  String? _nameError;
  String? _jsonError;

  @override
  void dispose() {
    _nameController.dispose();
    _jsonController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'error_name_required'.tr());
      return;
    }
    final json = _jsonController.text.trim();
    if (json.isEmpty) {
      setState(() => _jsonError = 'imggen_comfyui_invalid'.tr());
      return;
    }
    try {
      if (jsonDecode(json) is! Map) throw const FormatException();
    } catch (_) {
      setState(() => _jsonError = 'imggen_comfyui_invalid'.tr());
      return;
    }
    Navigator.pop(
      context,
      ComfyUiWorkflow(id: _newWorkflowId(), name: name, json: json),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MenuGroup(
            items: [
              MenuFieldItem(
                label: 'imggen_comfyui_workflow_name'.tr(),
                controller: _nameController,
                onChanged: (_) => setState(() => _nameError = null),
                helper: _nameError,
                helperIsError: true,
              ),
              MenuFieldItem(
                label: 'imggen_comfyui_workflow_json'.tr(),
                description: 'imggen_comfyui_workflow_hint'.tr(),
                controller: _jsonController,
                maxLines: 12,
                keyboardType: TextInputType.multiline,
                onChanged: (_) => setState(() => _jsonError = null),
                helper: _jsonError,
                helperIsError: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
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
                child: Text('btn_save'.tr()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
