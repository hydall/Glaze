import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/gallery_entry.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/utils/platform_paths.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../gallery_provider.dart';

/// A character's image gallery: the grid, its import action and the fullscreen
/// viewer, with no chrome of its own.
///
/// Extracted from `GalleryScreen` so the same grid can be the character sheet's
/// gallery tab and the standalone `/character/:id/gallery` route without two
/// implementations drifting apart.
class CharacterGalleryView extends ConsumerWidget {
  final String charId;

  /// True when hosted inside another scrollable (the character sheet's body is
  /// one `SingleChildScrollView`), which requires the grid to size itself and
  /// give scrolling to the parent.
  final bool shrinkWrap;

  /// Entries to render instead of querying the DB. Catalog previews hold a
  /// character that was never persisted, so `galleryProvider` cannot find it.
  final List<GalleryEntry>? entries;

  const CharacterGalleryView({
    super.key,
    required this.charId,
    this.shrinkWrap = false,
    this.entries,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provided = entries;
    if (provided != null) return _buildContent(context, ref, provided);

    return ref
        .watch(galleryProvider(charId))
        .when(
          loading: () => const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: Text('${'title_error'.tr()}: $e')),
          ),
          data: (data) => _buildContent(context, ref, data),
        );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    List<GalleryEntry> entries,
  ) {
    // Import lives in a header row rather than a bottom bar: hosted in the
    // character sheet, a bottom bar would sit under the sheet's chat FAB.
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          if (entries.isNotEmpty)
            Text(
              '${entries.length}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          const Spacer(),
          TextButton.icon(
            onPressed: () => _addImage(context, ref),
            icon: const Icon(Icons.add_photo_alternate, size: 18),
            label: Text('action_import'.tr()),
          ),
        ],
      ),
    );

    if (entries.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
          Icon(
            Icons.photo_library_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'no_results'.tr(),
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _addImage(context, ref),
            icon: const Icon(Icons.add_photo_alternate),
            label: Text('action_import'.tr()),
          ),
          const SizedBox(height: 24),
        ],
      );
    }

    final grid = GridView.builder(
      padding: const EdgeInsets.all(8),
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) => GalleryTile(
        entry: entries[index],
        charId: charId,
        onTap: () => _openViewer(context, ref, entries, index),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [header, shrinkWrap ? grid : Expanded(child: grid)],
    );
  }

  Future<void> _addImage(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final path = result.files.single.path;
    if (path == null) return;

    try {
      final service = await ref.read(galleryServiceProvider.future);
      await service.addImage(charId, path);
      ref.invalidate(galleryProvider(charId));
    } catch (e) {
      if (context.mounted) {
        GlazeErrorDialog.show(context, e, prefix: '${'settings_err_failed'.tr()} ');
      }
    }
  }

  void _openViewer(
    BuildContext context,
    WidgetRef ref,
    List<GalleryEntry> entries,
    int initialIndex,
  ) {
    // Root navigator: pushed on the local one, the viewer would land *below*
    // the imperatively-pushed character sheet that hosts this grid.
    Navigator.of(context, rootNavigator: true)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => GalleryViewer(
              charId: charId,
              entries: entries,
              initialIndex: initialIndex,
            ),
          ),
        )
        .then((_) => ref.invalidate(galleryProvider(charId)));
  }
}

/// One gallery thumbnail. Long-press exposes set-as-avatar and delete.
class GalleryTile extends ConsumerWidget {
  final GalleryEntry entry;
  final String charId;
  final VoidCallback onTap;

  const GalleryTile({
    super.key,
    required this.entry,
    required this.charId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: () => _showActions(context, ref),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(resolveGlazeFilePath(entry.imagePath) ?? entry.imagePath),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.broken_image,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (entry.label != null && entry.label!.isNotEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  color: Colors.black54,
                  child: Text(
                    entry.label!,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'avatar'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.face,
          label: 'avatar'.tr(),
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await setGalleryEntryAsAvatar(context, ref, entry);
          },
        ),
        BottomSheetItem(
          icon: Icons.delete,
          iconColor: Colors.red,
          label: 'action_delete_msg'.tr(),
          isDestructive: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            try {
              final service = await ref.read(galleryServiceProvider.future);
              await service.deleteImage(entry.characterId, entry.id);
              ref.invalidate(galleryProvider(charId));
            } catch (e) {
              if (context.mounted) {
                GlazeErrorDialog.show(
                  context,
                  e,
                  prefix: '${'settings_err_failed'.tr()} ',
                );
              }
            }
          },
        ),
      ],
    );
  }
}

/// Promotes a gallery image to the character's avatar.
///
/// [GalleryService.setAsAvatar] only writes the row, so every cached decode of
/// the old file keeps rendering until the avatar version is bumped and the
/// character list is re-read — visible immediately now that the gallery and the
/// character's hero image share one screen.
Future<void> setGalleryEntryAsAvatar(
  BuildContext context,
  WidgetRef ref,
  GalleryEntry entry,
) async {
  try {
    final service = await ref.read(galleryServiceProvider.future);
    await service.setAsAvatar(entry.characterId, entry.id);
    bumpAvatarVersion(ref);
    ref.invalidate(charactersProvider);
    if (context.mounted) GlazeToast.show(context, 'import_success'.tr());
  } catch (e) {
    if (context.mounted) {
      GlazeErrorDialog.show(context, e, prefix: '${'settings_err_failed'.tr()} ');
    }
  }
}

/// Fullscreen pager over a character's gallery.
class GalleryViewer extends ConsumerStatefulWidget {
  final String charId;
  final List<GalleryEntry> entries;
  final int initialIndex;

  const GalleryViewer({
    super.key,
    required this.charId,
    required this.entries,
    required this.initialIndex,
  });

  @override
  ConsumerState<GalleryViewer> createState() => _GalleryViewerState();
}

class _GalleryViewerState extends ConsumerState<GalleryViewer> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entries[_currentIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${_currentIndex + 1} / ${widget.entries.length}',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.face),
            tooltip: 'avatar'.tr(),
            onPressed: () => setGalleryEntryAsAvatar(context, ref, entry),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'action_delete_msg'.tr(),
            onPressed: () => _confirmDelete(context, entry),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.entries.length,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemBuilder: (context, index) {
          final e = widget.entries[index];
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: Center(
              child: Image.file(
                File(resolveGlazeFilePath(e.imagePath) ?? e.imagePath),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.broken_image,
                      color: Colors.white54,
                      size: 64,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'no_results'.tr(),
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: entry.label != null && entry.label!.isNotEmpty
          ? BottomAppBar(
              color: Colors.black87,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  entry.label!,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : null,
    );
  }

  void _confirmDelete(BuildContext context, GalleryEntry entry) {
    GlazeBottomSheet.show<void>(
      context,
      title: '${'action_delete_msg'.tr()}?',
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'action_delete_msg'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'action_delete_msg'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            try {
              final service = await ref.read(galleryServiceProvider.future);
              await service.deleteImage(entry.characterId, entry.id);
              ref.invalidate(galleryProvider(widget.charId));
              if (context.mounted) Navigator.pop(context);
            } catch (e) {
              if (context.mounted) {
                GlazeErrorDialog.show(
                  context,
                  e,
                  prefix: '${'settings_err_failed'.tr()} ',
                );
              }
            }
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }
}
