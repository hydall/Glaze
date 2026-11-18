import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/preset_folder.dart';
import '../../core/state/preset_folder_provider.dart';
import 'preset_list_provider.dart';

/// Deletes a preset and drops its folder membership rows, so no
/// folder is left holding a member that no longer exists. Every delete path
/// (editor menu, list row menu, bulk delete) goes through here.
Future<void> deletePresetAndFolderMemberships(
  WidgetRef ref,
  String presetId,
  PresetKind kind,
) async {
  if (kind == PresetKind.normal) {
    await ref.read(presetListProvider.notifier).remove(presetId);
  }
  await ref
      .read(presetFolderRepoProvider)
      .deleteMembersForPreset(presetId, kind);
}
