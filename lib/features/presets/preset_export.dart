import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/models/preset.dart';
import '../../core/services/file_export_service.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';

/// Exports [preset] to a JSON file and shows a toast with the result.
Future<void> exportPreset(BuildContext context, Preset preset) async {
  try {
    final exportJson = <String, dynamic>{
      'name': preset.name,
      if (preset.author != null && preset.author!.isNotEmpty)
        'author': preset.author,
      'prompts': preset.blocks
          .map((b) => <String, dynamic>{
                'name': b.name,
                'role': b.role,
                'content': b.content,
                'enabled': b.enabled,
                'insertion_mode': b.insertionMode,
                if (b.depth != null) 'depth': b.depth,
                if (b.isStashed) 'isStashed': true,
                if (b.appendToLastMessage) 'appendToLastMessage': true,
              })
          .toList(),
      'regexes': preset.regexes
          .map((r) => <String, dynamic>{
                'scriptName': r.name,
                'findRegex': r.regex,
                'replaceString': r.replacement,
                'trimStrings': r.trimOut.isEmpty
                    ? <String>[]
                    : r.trimOut
                        .split('\n')
                        .where((t) => t.isNotEmpty)
                        .toList(),
                'placement': r.placement,
                'isEnabled': !r.disabled,
                'markdownOnly': r.markdownOnly,
                'promptOnly': r.promptOnly,
                'runOnEdit': r.runOnEdit,
                'substituteRegex': r.substituteRegex,
                if (r.minDepth != null) 'minDepth': r.minDepth,
                if (r.maxDepth != null) 'maxDepth': r.maxDepth,
              })
          .toList(),
      'reasoning': preset.reasoningEnabled,
      if (preset.mergePrompts) 'mergePrompts': true,
      if (preset.mergeRole != 'system') 'mergeRole': preset.mergeRole,
    };

    final encoded = const JsonEncoder.withIndent('  ').convert(exportJson);
    final safeName =
        preset.name.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
    final savedPath = await FileExportService.export(
      data: encoded,
      filename: '${safeName.isNotEmpty ? safeName : 'preset'}.json',
      subfolder: 'presets',
    );

    if (context.mounted) {
      GlazeToast.show(context, 'Exported to $savedPath');
    }
  } catch (e) {
    if (context.mounted) {
      GlazeErrorDialog.show(context, e, prefix: 'Export failed: ');
    }
  }
}
