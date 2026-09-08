import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/character_import_persistence_coordinator.dart';
import '../../core/state/character_provider.dart';
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
