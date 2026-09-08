import 'dart:convert';

import 'package:drift/drift.dart';

import '../../db/app_db.dart';
import '../../utils/time_helpers.dart';
import '../image_storage_service.dart';
import 'backup_helpers.dart';

class JsCharacterImporter extends BackupHelpers {
  @override
  final AppDatabase db;
  @override
  final ImageStorageService imageStorage;

  JsCharacterImporter(this.db, this.imageStorage);

  Future<void> importCharacters(dynamic data) async {
    if (data is! List) return;
    final chars = data.cast<Map<String, dynamic>>();

    chars.sort((a, b) {
      final ta = _originalTimestamp(a);
      final tb = _originalTimestamp(b);
      return ta.compareTo(tb);
    });

    final base = currentTimestampSeconds() - chars.length + 1;
    for (int i = 0; i < chars.length; i++) {
      final char = chars[i];
      String? avatarPath;
      final avatar = char['avatar'] as String?;
      if (avatar != null && avatar.startsWith('data:')) {
        final id = char['id'] as String? ?? generateBackupId();
        avatarPath = await imageStorage.saveAvatarFromDataUrl(id, avatar);
      } else {
        avatarPath = avatar;
      }
      await imageStorage.ensureThumbnailForAvatarPath(avatarPath);

      await db.into(db.characters).insertOnConflictUpdate(
            CharactersCompanion.insert(
              charId: char['id'] as String? ?? '',
              name: char['name'] as String? ?? '',
              avatarPath: Value(avatarPath),
              description: Value(char['description'] as String?),
              personality: Value(char['personality'] as String?),
              scenario: Value(char['scenario'] as String?),
              firstMes: Value(char['first_mes'] as String?),
              mesExample: Value(char['mes_example'] as String?),
              systemPrompt: Value(char['system_prompt'] as String?),
              postHistoryInstructions:
                  Value(char['post_history_instructions'] as String?),
              creator: Value(char['creator'] as String?),
              creatorNotes: Value(char['creator_notes'] as String?),
              color: Value(char['color'] as String?),
              tagsJson: Value(
                  char['tags'] != null ? jsonEncode(char['tags']) : null),
              alternateGreetingsJson: Value(
                  char['alternate_greetings'] != null
                      ? jsonEncode(char['alternate_greetings'])
                      : null),
              updatedAt: Value(base + i),
              createdAt: Value(_originalTimestamp(char) > 0 ? _originalTimestamp(char) : base + i),
              fav: Value(char['fav'] == true),
              extensionsJson: Value(extractExtensionsJson(char)),
              characterVersion: Value(
                  char['character_version'] is String
                      ? char['character_version'] as String
                      : '1'),
              macroName: Value(char['macro_name'] as String?),
            ),
          );
    }
  }

  int _originalTimestamp(Map<String, dynamic> char) {
    final raw = toInt(char['updatedAt'] ?? char['updated_at'] ??
        char['creation_date'] ?? char['created_at']);
    if (raw == null) return 0;
    if (raw > 1e12) return raw ~/ 1000;
    return raw;
  }

  Future<void> importPersonas(dynamic data) async {
    if (data is! List) return;
    for (final p in data) {
      if (p is! Map<String, dynamic>) continue;
      final per = p;
      String? avatarPath;
      final avatar = per['avatar'] as String?;
      if (avatar != null && avatar.startsWith('data:')) {
        final id = per['id'] as String? ?? generateBackupId();
        avatarPath = await imageStorage.saveAvatarFromDataUrl(id, avatar);
      } else {
        avatarPath = avatar;
      }
      await imageStorage.ensureThumbnailForAvatarPath(avatarPath);

      await db.into(db.personas).insertOnConflictUpdate(
            PersonasCompanion.insert(
              personaId: per['id'] as String? ?? '',
              name: per['name'] as String? ?? '',
              prompt: Value(
                  per['prompt'] as String? ?? per['description'] as String?),
              avatarPath: Value(avatarPath),
              createdAt: Value(toInt(per['createdAt'] ?? per['created_at']) ??
                  currentTimestampSeconds()),
            ),
          );
    }
  }

  Future<void> importGalleryFromCharacters(dynamic data) async {
    if (data is! List) return;
    for (final c in data) {
      if (c is! Map<String, dynamic>) continue;
      final char = c;
      final charId = char['id'] as String?;
      if (charId == null) continue;

      final galleryRaw = char['images'] ??
          char['gallery'] ??
          char['data']?['extensions']?['gallery'];
      if (galleryRaw is! List || galleryRaw.isEmpty) continue;

      final galleryEntries = <Map<String, dynamic>>[];
      for (int i = 0; i < galleryRaw.length; i++) {
        final g = galleryRaw[i];
        if (g is! Map<String, dynamic>) continue;

        final imageUrl =
            g['src'] as String? ?? g['url'] as String? ?? g['image'] as String?;
        if (imageUrl == null) continue;

        String? imagePath;
        if (imageUrl.startsWith('data:')) {
          final galId = g['id'] as String? ?? 'gal_${charId}_$i';
          final bytes = dataUrlToBytes(imageUrl);
          if (bytes == null) continue;
          final mime = dataUrlMime(imageUrl);
          final ext = mime == 'image/png'
              ? 'png'
              : mime == 'image/webp'
                  ? 'webp'
                  : 'jpg';
          imagePath = await imageStorage.saveBytes(
            bytes,
            'gallery/$charId',
            galId,
            ext,
          );
        } else {
          continue;
        }

        galleryEntries.add({
          'id': g['id'] as String? ?? 'gal_${charId}_$i',
          'characterId': charId,
          'imagePath': imagePath,
          'label': g['label'] as String? ?? g['name'] as String?,
          'createdAt': toInt(g['createdAt']) ?? 0,
        });
      }

      if (galleryEntries.isNotEmpty) {
        await (db.update(db.characters)
              ..where((t) => t.charId.equals(charId)))
            .write(CharactersCompanion(
          galleryJson: Value(jsonEncode(galleryEntries)),
        ));
      }
    }
  }
}
