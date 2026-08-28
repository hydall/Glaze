import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/character_bulk_import_service.dart';
import '../../core/services/character_import_persistence_coordinator.dart';
import '../../core/services/character_import_write_buffer.dart';
import '../../core/state/character_provider.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/lorebook_provider.dart';
import '../character_gallery/gallery_provider.dart';

final characterImportPersistenceCoordinatorProvider =
    Provider<CharacterImportPersistenceCoordinator>((ref) {
      return CharacterImportPersistenceCoordinator(
        persistCharacter: (character) =>
            ref.read(charactersProvider.notifier).add(character),
        persistLorebook: (lorebook) =>
            ref.read(lorebooksProvider.notifier).put(lorebook),
        persistGalleryImage: (characterId, image) async {
          final galleryService = await ref.read(galleryServiceProvider.future);
          await galleryService.addImageBytes(
            characterId,
            image.bytes,
            image.ext,
            label: image.label,
          );
        },
      );
    });

/// Builds a bulk importer for one run.
///
/// It is a factory rather than a plain provider because the write buffer holds
/// per-run state (the rows queued for the next transaction); reusing one across
/// runs would let a cancelled import leak its pending cards into the next one.
typedef CharacterBulkImportServiceFactory =
    Future<CharacterBulkImportService> Function();

final characterBulkImportServiceFactoryProvider =
    Provider<CharacterBulkImportServiceFactory>((ref) {
      return () async {
        final importer = await ref.read(characterImporterProvider.future);
        return CharacterBulkImportService(
          importer: importer,
          buffer: CharacterImportWriteBuffer(
            writeCharacters: (batch) =>
                ref.read(charactersProvider.notifier).addAll(batch),
            writeLorebooks: (batch) =>
                ref.read(lorebooksProvider.notifier).putAll(batch),
            writeGalleryImage: (characterId, image) async {
              final galleryService = await ref.read(
                galleryServiceProvider.future,
              );
              await galleryService.addImageBytes(
                characterId,
                image.bytes,
                image.ext,
                label: image.label,
              );
            },
          ),
        );
      };
    });
