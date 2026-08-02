import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/models/studio_config.dart';
import '../../core/services/file_export_service.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';

/// Exports an agentic (Studio) preset to JSON and shows a toast with the
/// result.
Future<void> exportStudioPreset(
  BuildContext context,
  StudioPreset preset,
) async {
  try {
    final savedPath = await saveStudioPresetJson(preset);
    if (context.mounted) {
      GlazeToast.show(context, 'export_saved_to'.tr(args: [savedPath]));
    }
  } catch (e) {
    if (context.mounted) {
      GlazeErrorDialog.show(
        context,
        e,
        prefix: 'error_export_failed_prefix'.tr(),
      );
    }
  }
}

/// Writes [preset] to a JSON file and returns the saved path. The payload is
/// the model's own `toJson()` — it keeps the `agentEnabled` map, which is what
/// the importer in `PresetListScreen` sniffs to tell an agentic file apart from
/// a SillyTavern preset. Split out of [exportStudioPreset] so bulk export can
/// report one summary instead of a toast per file.
Future<String> saveStudioPresetJson(StudioPreset preset) {
  final encoded = const JsonEncoder.withIndent('  ').convert(preset.toJson());
  final safeName = preset.name.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
  return FileExportService.export(
    data: encoded,
    filename: '${safeName.isNotEmpty ? safeName : 'agentic_preset'}.json',
    subfolder: 'presets',
  );
}
