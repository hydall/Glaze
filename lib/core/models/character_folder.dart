/// A user-created folder for organizing local characters.
///
/// Membership is stored separately (`character_folder_members`); a character
/// may belong to many folders, but never twice to the same folder.
class CharacterFolder {
  final String id;
  final String name;
  final String? color;
  final int sortOrder;
  final int createdAt;
  final int updatedAt;

  const CharacterFolder({
    required this.id,
    required this.name,
    this.color,
    this.sortOrder = 0,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  CharacterFolder copyWith({
    String? id,
    String? name,
    String? color,
    int? sortOrder,
    int? createdAt,
    int? updatedAt,
  }) => CharacterFolder(
    id: id ?? this.id,
    name: name ?? this.name,
    color: color ?? this.color,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
