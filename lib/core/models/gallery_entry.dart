import 'package:freezed_annotation/freezed_annotation.dart';

part 'gallery_entry.freezed.dart';
part 'gallery_entry.g.dart';

@freezed
abstract class GalleryEntry with _$GalleryEntry {
  const factory GalleryEntry({
    required String id,
    required String characterId,
    required String imagePath,
    String? label,
    @Default(0) int createdAt,
  }) = _GalleryEntry;

  factory GalleryEntry.fromJson(Map<String, dynamic> json) =>
      _$GalleryEntryFromJson(json);
}
