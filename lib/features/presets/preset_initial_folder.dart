import '../../core/models/preset_folder.dart';
import '../../core/state/preset_folder_provider.dart';

/// The folder the Presets list should open on, or null to open at the top
/// level.
///
/// A preset filed into a folder is not listed at the top level, so a list that
/// always opened there would show no highlighted row at all and leave the user
/// to remember where they put the preset in effect.
///
/// [activeId] is the preset currently in effect (null when there is none) and
/// [kind] which list it comes from. When it belongs to several folders the one
/// [folders] lists first wins, so the choice matches the order the folder
/// section shows.
String? initialPresetFolderId({
  required String? activeId,
  required PresetKind kind,
  required PresetFolderMemberships memberships,
  required List<PresetFolder> folders,
}) {
  if (activeId == null) return null;
  final folderIds = memberships.foldersOf(activeId, kind);
  if (folderIds.isEmpty) return null;
  // A membership row can outlive its folder (a folder deleted while its rows
  // were still being cleaned up); such an id opens nothing.
  for (final folder in folders) {
    if (folderIds.contains(folder.id)) return folder.id;
  }
  return null;
}
