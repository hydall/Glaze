import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/character_import_persistence_coordinator.dart';
import 'package:glaze_flutter/core/services/character_importer.dart';

void main() {
  late Character character;
  late List<String> writes;
  late CharacterImportPersistenceCoordinator coordinator;

  setUp(() {
    character = const Character(id: 'char-1', name: 'Test');
    writes = [];
    coordinator = CharacterImportPersistenceCoordinator(
      persistCharacter: (value) async {
        writes.add('character:${value.id}');
      },
      persistLorebook: (value) async {
        writes.add('lorebook:${value.activationTargetId}');
      },
      persistGalleryImage: (characterId, image) async {
        writes.add('gallery:$characterId:${image.label}');
      },
    );
  });

  test('persists a character-only result once', () async {
    final result = await coordinator.persist(
      CharacterImportResult(character: character, hadAvatar: false),
    );

    expect(result, isA<CharacterImportPersistenceSuccess>());
    expect(writes, ['character:char-1']);
    final success = result as CharacterImportPersistenceSuccess;
    expect(success.lorebook, isNull);
    expect(success.galleryImageCount, 0);
  });

  test('persists an embedded lorebook after its character', () async {
    final result = await coordinator.persist(
      CharacterImportResult(
        character: character,
        hadAvatar: false,
        characterBookData: {
          'name': 'Embedded lore',
          'entries': [
            {
              'id': 1,
              'keys': ['key'],
              'content': 'content',
            },
          ],
        },
      ),
    );

    expect(result, isA<CharacterImportPersistenceSuccess>());
    expect(writes, ['character:char-1', 'lorebook:char-1']);
    final lorebook = (result as CharacterImportPersistenceSuccess).lorebook;
    expect(lorebook?.name, 'Embedded lore');
    expect(lorebook?.activationScope, 'character');
    expect(lorebook?.entries, hasLength(1));
  });

  test('persists gallery data in order after character and lorebook', () async {
    final result = await coordinator.persist(
      CharacterImportResult(
        character: character,
        hadAvatar: false,
        characterBookData: const {'name': 'Lore', 'entries': <Object>[]},
        galleryImages: [
          GalleryImageData(
            label: 'first',
            bytes: Uint8List.fromList([1]),
            ext: 'png',
          ),
          GalleryImageData(
            label: 'second',
            bytes: Uint8List.fromList([2]),
            ext: 'jpg',
          ),
        ],
      ),
    );

    expect(result, isA<CharacterImportPersistenceSuccess>());
    expect(writes, [
      'character:char-1',
      'lorebook:char-1',
      'gallery:char-1:first',
      'gallery:char-1:second',
    ]);
    expect((result as CharacterImportPersistenceSuccess).galleryImageCount, 2);
  });

  test(
    'propagates the failed stage and does not retry or continue writes',
    () async {
      final failure = StateError('lorebook failed');
      var characterWrites = 0;
      var lorebookWrites = 0;
      var galleryWrites = 0;
      coordinator = CharacterImportPersistenceCoordinator(
        persistCharacter: (_) async {
          characterWrites++;
        },
        persistLorebook: (_) async {
          lorebookWrites++;
          throw failure;
        },
        persistGalleryImage: (_, _) async {
          galleryWrites++;
        },
        bookConverter: (_, characterId) => Lorebook(
          id: 'lore-1',
          name: 'Lore',
          activationScope: 'character',
          activationTargetId: characterId,
        ),
      );

      final result = await coordinator.persist(
        CharacterImportResult(
          character: character,
          hadAvatar: false,
          characterBookData: const {},
          galleryImages: [
            GalleryImageData(
              label: 'not written',
              bytes: Uint8List(0),
              ext: 'png',
            ),
          ],
        ),
      );

      expect(result, isA<CharacterImportPersistenceFailure>());
      final typedFailure = result as CharacterImportPersistenceFailure;
      expect(typedFailure.stage, CharacterImportPersistenceStage.lorebook);
      expect(typedFailure.error, same(failure));
      expect(characterWrites, 1);
      expect(lorebookWrites, 1);
      expect(galleryWrites, 0);
    },
  );
}
