import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../image_gen_models.dart';

/// Editor for the ComfyUI API-format workflow.
///
/// Mirrors SillyTavern's workflow editor: the whole graph is one JSON document,
/// editable as text, and an empty value means the shipped default. Saving is
/// gated on the text parsing as JSON so a bad paste cannot silently break every
/// later generation.
class ComfyUiWorkflowSheet extends StatefulWidget {
  const ComfyUiWorkflowSheet({
    super.key,
    required this.workflow,
    required this.onSave,
  });

  final String workflow;
  final ValueChanged<String> onSave;

  @override
  State<ComfyUiWorkflowSheet> createState() => _ComfyUiWorkflowSheetState();
}

class _ComfyUiWorkflowSheetState extends State<ComfyUiWorkflowSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.workflow.trim().isEmpty
        ? ComfyUiConstants.defaultWorkflow
        : widget.workflow,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _reset() {
    setState(() => _controller.text = ComfyUiConstants.defaultWorkflow);
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      try {
        jsonDecode(text);
      } catch (_) {
        GlazeToast.show(context, 'imggen_comfyui_invalid'.tr(), isError: true);
        return;
      }
    }
    // Storing the shipped default verbatim would read back as a custom
    // workflow; keep the empty sentinel so "Default" stays selected.
    final isDefault = text == ComfyUiConstants.defaultWorkflow.trim();
    widget.onSave(isDefault ? '' : text);
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: 'imggen_comfyui_workflow'.tr(),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.restart_alt),
          tooltip: 'imggen_comfyui_reset'.tr(),
          onPressed: _reset,
        ),
        SheetViewAction(
          icon: const Icon(Icons.check),
          tooltip: 'imggen_comfyui_save'.tr(),
          onPressed: _save,
        ),
      ],
      fitContent: false,
      enableHeaderBlur: false,
      body: ListView(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 12,
          bottom: MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          MenuGroup(
            items: [
              MenuFieldItem(
                label: 'imggen_comfyui_workflow'.tr(),
                description: 'imggen_comfyui_workflow_hint'.tr(),
                controller: _controller,
                maxLines: 18,
                keyboardType: TextInputType.multiline,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
