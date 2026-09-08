import '../models/character.dart';
import '../models/lorebook.dart';
import 'character_book_converter.dart';
import 'character_importer.dart';

typedef PersistImportedCharacter = Future<void> Function(Character character);
typedef PersistImportedLorebook = Future<void> Function(Lorebook lorebook);
typedef PersistImportedGalleryImage =
    Future<void> Function(String characterId, GalleryImageData image);
typedef ConvertImportedCharacterBook =
    Lorebook Function(Map<String, dynamic> data, String characterId);

enum CharacterImportPersistenceStage { character, lorebook, gallery }

sealed class CharacterImportPersistenceResult {
  const CharacterImportPersistenceResult();
}

final class CharacterImportPersistenceSuccess
    extends CharacterImportPersistenceResult {
  final Character character;
  final Lorebook? lorebook;
  final int galleryImageCount;

  const CharacterImportPersistenceSuccess({
    required this.character,
    required this.lorebook,
    required this.galleryImageCount,
  });
}

final class CharacterImportPersistenceFailure
    extends CharacterImportPersistenceResult {
  final CharacterImportPersistenceStage stage;
  final Object error;
  final StackTrace stackTrace;

  const CharacterImportPersistenceFailure({
    required this.stage,
    required this.error,
    required this.stackTrace,
  });

  Never rethrowError() => Error.throwWithStackTrace(error, stackTrace);
}

class CharacterImportPersistenceCoordinator {
  final PersistImportedCharacter persistCharacter;
  final PersistImportedLorebook persistLorebook;
  final PersistImportedGalleryImage persistGalleryImage;
  final ConvertImportedCharacterBook bookConverter;

  const CharacterImportPersistenceCoordinator({
    required this.persistCharacter,
    required this.persistLorebook,
    required this.persistGalleryImage,
    this.bookConverter = convertCharacterBook,
  });

  Future<CharacterImportPersistenceResult> persist(
    CharacterImportResult imported,
  ) async {
    var stage = CharacterImportPersistenceStage.character;
    try {
      await persistCharacter(imported.character);

      Lorebook? lorebook;
      final characterBookData = imported.characterBookData;
      if (characterBookData != null) {
        stage = CharacterImportPersistenceStage.lorebook;
        lorebook = bookConverter(characterBookData, imported.character.id);
        await persistLorebook(lorebook);
      }

      var galleryImageCount = 0;
      for (final image
          in imported.galleryImages ?? const <GalleryImageData>[]) {
        stage = CharacterImportPersistenceStage.gallery;
        await persistGalleryImage(imported.character.id, image);
        galleryImageCount++;
      }

      return CharacterImportPersistenceSuccess(
        character: imported.character,
        lorebook: lorebook,
        galleryImageCount: galleryImageCount,
      );
    } catch (error, stackTrace) {
      return CharacterImportPersistenceFailure(
        stage: stage,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
