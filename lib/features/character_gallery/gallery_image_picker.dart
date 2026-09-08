import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/gallery_entry.dart';
import '../../core/utils/platform_paths.dart';
import 'gallery_provider.dart';

Future<GalleryEntry?> showCharacterGalleryImagePicker(
  BuildContext context, {
  required String charId,
}) {
  return showModalBottomSheet<GalleryEntry>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => _GalleryImagePicker(charId: charId),
  );
}

class _GalleryImagePicker extends ConsumerWidget {
  const _GalleryImagePicker({required this.charId});

  final String charId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gallery = ref.watch(galleryProvider(charId));
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Card gallery',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: gallery.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text(error.toString())),
              data: (entries) {
                if (entries.isEmpty) {
                  return const Center(child: Text('The card gallery is empty'));
                }
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final path =
                        resolveGlazeFilePath(entry.imagePath) ??
                        entry.imagePath;
                    return InkWell(
                      onTap: () => Navigator.pop(context, entry),
                      borderRadius: BorderRadius.circular(8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const ColoredBox(
                            color: Colors.black12,
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
