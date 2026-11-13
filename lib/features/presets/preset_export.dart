import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/import/silly_tavern_preset_parser.dart';
import '../../core/models/preset.dart';
import '../../core/services/file_export_service.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';

/// Exports [preset] to a JSON file and shows a toast with the result.
Future<void> exportPreset(BuildContext context, Preset preset) async {
  try {
    final savedPath = await savePresetJson(preset);
    if (savedPath.isEmpty) return; // user cancelled the save dialog
    if (context.mounted) {
      GlazeToast.show(context, 'Exported to $savedPath');
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

/// The preset as it is written to disk: a SillyTavern preset, with Glaze's
/// own keys riding along.
///
/// SillyTavern reads `prompts` by `identifier` and takes which of them are on,
/// and in what order, from `prompt_order` — a file without those opened there
/// as its default prompt list with every toggle lost, which is what "the
/// export is just a standard preset" was. So every prompt carries the
/// identifier SillyTavern knows the block by (`chatHistory` for the chat
/// history, the block's own id for a custom prompt), its insertion fields and
/// the `marker` / `system_prompt` flags of its built-ins, and `prompt_order`
/// lists the live blocks in order with their toggles. A stashed block is in
/// `prompts` but not in the order, which is how SillyTavern keeps one too.
///
/// Glaze's own keys stay next to them — `enabled`, `insertion_mode`, `depth`,
/// `isStashed`, `appendToLastMessage`, `sendEmptyBlock`, `regexes` — so the
/// file comes back here without loss (`parseSillyTavernPreset` prefers them
/// when present) and a frontend that knows nothing about them ignores them.
/// Folders ride along the same way: a separate `block_folders` list plus a
/// `folder` id on the prompts that belong to one, so an importer only ever
/// sees the folders the file declares.
Map<String, dynamic> presetExportJson(Preset preset) {
  final live = preset.blocks.where((b) => !b.isStashed);
  final order = [
    for (final b in live)
      <String, dynamic>{
        'identifier': stIdentifierForBlockId(b.id),
        'enabled': b.enabled,
      },
  ];
  return <String, dynamic>{
    'name': preset.name,
    if (preset.author != null && preset.author!.isNotEmpty)
      'author': preset.author,
    if (preset.impersonationPrompt != null &&
        preset.impersonationPrompt!.isNotEmpty)
      'impersonation_prompt': preset.impersonationPrompt,
    'prompts': preset.blocks
        .map(
          (b) => <String, dynamic>{
            'identifier': stIdentifierForBlockId(b.id),
            'name': b.name,
            'role': b.role,
            'content': b.content,
            // SillyTavern's own built-ins carry these; a marker is an
            // insertion point whose text is produced at prompt time.
            'system_prompt':
                isStMarkerBlockId(b.id) || _stBuiltIns.contains(b.id),
            'marker': isStMarkerBlockId(b.id),
            'enabled': b.enabled,
            'injection_position': b.insertionMode == 'depth' ? 1 : 0,
            'injection_depth': b.depth ?? 4,
            'injection_order': 100,
            'forbid_overrides': false,
            if (b.isStashed) 'isStashed': true,
            'insertion_mode': b.insertionMode,
            if (b.depth != null) 'depth': b.depth,
            if (b.appendToLastMessage) 'appendToLastMessage': true,
            if (b.sendEmptyBlock) 'sendEmptyBlock': true,
            // Folder membership is an explicit reference into
            // `block_folders`; other frontends ignore the extra key and read
            // the preset as the flat prompt list it still is.
            if (b.folderId != null) 'folder': b.folderId,
          },
        )
        .toList(),
    // The same order under both ids SillyTavern looks up — 100001 is the
    // global one its prompt manager uses today, 100000 the one older builds
    // read — so the toggles land whichever it asks for.
    'prompt_order': [
      {'character_id': 100000, 'order': order},
      {'character_id': 100001, 'order': order},
    ],
    'regexes': preset.regexes
        .map(
          (r) => <String, dynamic>{
            'scriptName': r.name,
            'findRegex': r.regex,
            'replaceString': r.replacement,
            'trimStrings': r.trimOut.isEmpty
                ? <String>[]
                : r.trimOut.split('\n').where((t) => t.isNotEmpty).toList(),
            'placement': r.placement,
            'isEnabled': !r.disabled,
            'markdownOnly': r.markdownOnly,
            'promptOnly': r.promptOnly,
            'runOnEdit': r.runOnEdit,
            'memoryBookRetrieval': r.memoryBookRetrieval,
            'substituteRegex': r.substituteRegex,
            if (r.minDepth != null) 'minDepth': r.minDepth,
            if (r.maxDepth != null) 'maxDepth': r.maxDepth,
            // A reference into `regex_folders`, like a prompt's `folder`.
            if (r.folderId != null) 'folder': r.folderId,
          },
        )
        .toList(),
    // Folders are declared here and nowhere else — never derived from block
    // names — so an importer that skips this key simply gets no folders.
    if (preset.blockFolders.isNotEmpty)
      'block_folders': preset.blockFolders
          .map(
            (f) => <String, dynamic>{
              'id': f.id,
              'name': f.name,
              'enabled': f.enabled,
              'exclusive': f.exclusive,
            },
          )
          .toList(),
    if (preset.regexFolders.isNotEmpty)
      'regex_folders': preset.regexFolders
          .map((f) => <String, dynamic>{'id': f.id, 'name': f.name})
          .toList(),
    'reasoning': preset.reasoningEnabled,
  };
}

/// SillyTavern's text built-ins (`main` is its Main Prompt, `nsfw` its
/// Auxiliary Prompt), flagged `system_prompt` there like the markers.
const _stBuiltIns = <String>{'main', 'nsfw'};

/// Writes [preset] to a JSON file and returns the saved path. Split out of
/// [exportPreset] so bulk export can report one summary instead of a toast per
/// file.
Future<String> savePresetJson(Preset preset) async {
  final exportJson = presetExportJson(preset);
  final encoded = const JsonEncoder.withIndent('  ').convert(exportJson);
  final safeName = preset.name.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
  return FileExportService.export(
    data: encoded,
    filename: '${safeName.isNotEmpty ? safeName : 'preset'}.json',
    subfolder: 'presets',
  );
}
