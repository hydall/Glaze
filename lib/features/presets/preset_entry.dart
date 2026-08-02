import '../../core/llm/preset_macro_attribution.dart';
import '../../core/models/preset.dart';
import '../../core/models/preset_folder.dart';
import '../../core/models/studio_config.dart';
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
