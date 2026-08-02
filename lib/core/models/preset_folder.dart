/// Which list a preset entry comes from.
///
/// `normal` — a chat preset (`presets` table, [Preset] model).
/// `agentic` — a Studio agent preset (`studio_preset_rows`, [StudioPreset]).
enum PresetKind {
  normal,
  agentic;

  /// Stable wire name used as the `kind` column in `preset_folder_members`.
  String get wireName => name;

  static PresetKind fromWireName(String? value) =>
      value == agentic.wireName ? agentic : normal;
}

/// A user-created folder for organizing presets.
///
/// Membership is stored separately (`preset_folder_members`); a preset may
/// belong to many folders, but never twice to the same folder. Mirrors
/// [CharacterFolder] — the only difference is that members are keyed by
/// (id, kind) because chat and Studio presets have independent id spaces.
class PresetFolder {
  final String id;
  final String name;
  final String? color;
  final int sortOrder;
  final int createdAt;
  final int updatedAt;

  const PresetFolder({
    required this.id,
    required this.name,
    this.color,
    this.sortOrder = 0,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  PresetFolder copyWith({
    String? id,
    String? name,
    String? color,
    int? sortOrder,
    int? createdAt,
    int? updatedAt,
  }) => PresetFolder(
    id: id ?? this.id,
    name: name ?? this.name,
    color: color ?? this.color,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// Stable key identifying a preset inside folder membership maps. Chat and
/// Studio presets are stored side by side, so the kind is part of the key.
String presetMemberKey(String presetId, PresetKind kind) =>
    '${kind.wireName}:$presetId';
