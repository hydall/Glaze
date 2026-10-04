import '../../core/llm/preset_macro_attribution.dart';
import '../../core/models/preset.dart';
import '../../core/models/preset_folder.dart';
import '../../core/models/studio_config.dart';
import '../../core/state/preset_folder_provider.dart';
import '../studio/studio_preset_stats.dart';

/// One row of the Presets list, regardless of which store it came from: a plain
/// chat preset ([PresetKind.normal]) or an agentic Studio preset
/// ([PresetKind.agentic]).
///
/// The two kinds keep their own models — the card still branches on
/// [isAgentic] to render them — but folders, filters and multi-select only ever
/// need the shared projection below.
class PresetItem {
  final Preset? preset;
  final StudioPreset? studioPreset;

  PresetItem({this.preset, this.studioPreset});

  bool get isAgentic => studioPreset != null;

  PresetKind get kind => isAgentic ? PresetKind.agentic : PresetKind.normal;

  String get id => isAgentic ? studioPreset!.id : preset!.id;

  String get name => isAgentic ? studioPreset!.name : preset!.name;

  /// When the preset entered the library, for "date added" sorting.
  ///
  /// Plain presets carry the timestamp themselves. Studio presets don't, but
  /// every one a user makes — created or imported — gets an id of
  /// `studio_<seconds>`, so that is its creation time.
  ///
  /// An id without that stamp is a built-in: the seeded `default` preset, which
  /// arrives with the install exactly like the featured plain presets do. Its
  /// `updatedAt` is *not* a creation time — the repo re-stamps it on every save
  /// — so reading it here would float the built-in to the newest end of the
  /// list every time the user edited it, and sink it to the bottom of the
  /// merged library. It sorts as the oldest entry instead.
  int get createdAt {
    if (!isAgentic) return preset!.createdAt;
    final sp = studioPreset!;
    if (!sp.id.startsWith('studio_')) return 0;
    return int.tryParse(sp.id.substring('studio_'.length)) ?? 0;
  }

  /// Key this row is stored under in `preset_folder_members`.
  String get memberKey => presetMemberKey(id, kind);

  /// Counting a plain preset's tokens resolves every block's macros, so it
  /// stays lazy: the list rebuilds on every preset save (the editor autosaves
  /// while typing) and only rendered rows — plus a token filter, when one is
  /// set — need the number.
  late final int tokens = isAgentic
      ? studioPresetTokenEstimate(studioPreset!)
      : presetOnlyTokenCount(preset!);
}

/// The two preset stores as one list, interleaved by when each preset was
/// added.
///
/// Concatenating them — every plain preset, then every Studio one — groups the
/// list by kind, and that grouping is what the list falls back to: the manual
/// sort ranks only the rows the user has actually dragged and leaves the rest
/// in the incoming order, so a Studio preset sat below every plain one forever.
///
/// This is a merge, not a sort: it only ever takes from the front of either
/// list, so each store's own order survives untouched (the plain list carries a
/// legacy manual order of its own, which is not in timestamp order). Only where
/// the Studio presets slot into that order changes. Ties go to the plain
/// preset, so an equal stamp never pushes an existing row down.
List<PresetItem> mergePresetItems(
  List<Preset> presets,
  List<StudioPreset> studioPresets,
) {
  final plain = [for (final p in presets) PresetItem(preset: p)];
  final agentic = [for (final sp in studioPresets) PresetItem(studioPreset: sp)];

  final merged = <PresetItem>[];
  var i = 0;
  var j = 0;
  while (i < plain.length && j < agentic.length) {
    if (agentic[j].createdAt < plain[i].createdAt) {
      merged.add(agentic[j++]);
    } else {
      merged.add(plain[i++]);
    }
  }
  merged.addAll(plain.sublist(i));
  merged.addAll(agentic.sublist(j));
  return merged;
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
