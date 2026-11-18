import '../../core/llm/preset_macro_attribution.dart';
import '../../core/models/preset.dart';
import '../../core/models/preset_folder.dart';
import '../../core/state/preset_folder_provider.dart';

/// One row of the Presets list: a chat preset plus the shared projection that
/// folders, filters and multi-select need.
class PresetItem {
  final Preset preset;

  PresetItem({required this.preset});

  PresetKind get kind => PresetKind.normal;

  String get id => preset.id;

  String get name => preset.name;

  /// When the preset entered the library, for "date added" sorting.
  int get createdAt => preset.createdAt;

  /// Key this row is stored under in `preset_folder_members`.
  String get memberKey => presetMemberKey(id, kind);

  /// Counting a preset's tokens resolves every block's macros, so it stays
  /// lazy: the list rebuilds on every preset save (the editor autosaves while
  /// typing) and only rendered rows — plus a token filter, when one is set —
  /// need the number.
  late final int tokens = presetOnlyTokenCount(preset);
}

/// The folder the Presets list should open on, or null for the top level.
///
/// A preset filed into a folder is not listed at the top level — it lives in
/// the folder, and only there — so opening on the top level showed a list that
/// did not contain the preset actually in effect, with no hint of where it
/// went. A preset can belong to several folders; the first in [folders]' own
/// order wins, so the answer is the same on every open.
String? initialPresetFolderId({
  required String? activeId,
  required PresetKind kind,
  required List<PresetFolder> folders,
  required PresetFolderMemberships memberships,
}) {
  if (activeId == null || activeId.isEmpty) return null;
  final owning = memberships.foldersOf(activeId, kind);
  if (owning.isEmpty) return null;
  return folders.where((f) => owning.contains(f.id)).firstOrNull?.id;
}
