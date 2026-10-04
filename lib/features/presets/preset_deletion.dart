import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/preset_folder.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/preset_folder_provider.dart';
import '../studio/studio_preset_workflow_provider.dart';
import 'preset_list_provider.dart';

/// Deletes a preset of either kind and drops its folder membership rows, so no
/// folder is left holding a member that no longer exists. Every delete path
/// (editor menu, list row menu, bulk delete) goes through here.
Future<void> deletePresetAndFolderMemberships(
  WidgetRef ref,
  String presetId,
  PresetKind kind,
) async {
  if (kind == PresetKind.normal) {
    await ref.read(presetListProvider.notifier).remove(presetId);
  } else {
    // The workflow service also records the sync deletion and moves the active
    // selection off the deleted preset.
    await ref.read(studioPresetWorkflowServiceProvider).deletePreset(presetId);
    ref.invalidate(studioPresetListProvider);
  }
  await ref
      .read(presetFolderRepoProvider)
      .deleteMembersForPreset(presetId, kind);
}
