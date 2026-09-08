import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/gallery_entry.dart';
import '../../core/services/gallery_service.dart';
import '../../core/state/db_provider.dart';

final galleryServiceProvider = FutureProvider<GalleryService>((ref) async {
  final imageStorage = await ref.watch(imageStorageProvider.future);
  return GalleryService(
    ref.watch(characterRepoProvider),
    imageStorage,
  );
});

final galleryProvider =
    FutureProvider.family<List<GalleryEntry>, String>((ref, charId) async {
  final service = await ref.watch(galleryServiceProvider.future);
  return service.getGallery(charId);
});
