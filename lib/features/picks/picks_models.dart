import 'package:freezed_annotation/freezed_annotation.dart';

part 'picks_models.freezed.dart';

@freezed
abstract class PicksFolder with _$PicksFolder {
  const factory PicksFolder({
    required String id,
    required String name,
    String? description,
    String? imageUrl,
    @Default([]) List<PicksFolder> subfolders,
    @Default([]) List<PicksCharacter> characters,
  }) = _PicksFolder;

  static PicksFolder fromJson(Map<String, dynamic> json) {
    return PicksFolder(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      imageUrl: json['imageUrl'] as String?,
      subfolders: (json['subfolders'] as List<dynamic>?)
              ?.map((e) => PicksFolder.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      characters: (json['characters'] as List<dynamic>?)
              ?.map((e) => PicksCharacter.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

@freezed
abstract class PicksCharacter with _$PicksCharacter {
  const factory PicksCharacter({
    required String id,
    required String name,
    String? fileName,
    String? hash,
    String? description,
    @Default([]) List<String> tags,
    String? creator,
  }) = _PicksCharacter;

  static PicksCharacter fromJson(Map<String, dynamic> json) {
    return PicksCharacter(
      id: json['id'] as String,
      name: json['name'] as String,
      fileName: json['fileName'] as String?,
      hash: json['hash'] as String?,
      description: json['description'] as String?,
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
      creator: json['creator'] as String?,
    );
  }
}

@freezed
abstract class PicksIndex with _$PicksIndex {
  const factory PicksIndex({
    @Default([]) List<PicksFolder> folders,
  }) = _PicksIndex;

  static PicksIndex fromJson(Map<String, dynamic> json) {
    return PicksIndex(
      folders: (json['folders'] as List<dynamic>?)
              ?.map((e) => PicksFolder.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
