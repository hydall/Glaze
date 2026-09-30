/// Which list a generic folder belongs to.
///
/// Folders are partitioned by domain so the same two tables (`folders` /
/// `folder_members`) serve every list without their member id spaces colliding
/// — a lorebook id and a persona id are generated independently and are not
/// guaranteed to differ.
enum FolderDomain {
  lorebook,
  persona,
  imageStyle,
  regex;

  /// Stable wire name stored in the `domain` column.
  String get wireName => name;

  static FolderDomain fromWireName(String? value) {
    for (final domain in FolderDomain.values) {
      if (domain.wireName == value) return domain;
    }
    return FolderDomain.lorebook;
  }
}

/// A user-created folder in one list domain.
///
/// Membership is stored separately (`folder_members`); a member may belong to
/// many folders, but never twice to the same folder.
class Folder {
  final String id;
  final FolderDomain domain;
  final String name;
  final String? color;
  final int sortOrder;
  final int createdAt;
  final int updatedAt;

  const Folder({
    required this.id,
    required this.domain,
    required this.name,
    this.color,
    this.sortOrder = 0,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  Folder copyWith({
    String? id,
    FolderDomain? domain,
    String? name,
    String? color,
    int? sortOrder,
    int? createdAt,
    int? updatedAt,
  }) => Folder(
    id: id ?? this.id,
    domain: domain ?? this.domain,
    name: name ?? this.name,
    color: color ?? this.color,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
