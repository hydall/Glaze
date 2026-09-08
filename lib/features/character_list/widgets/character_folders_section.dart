import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/character.dart';
import '../../../core/models/character_folder.dart';
import '../../../core/state/character_folder_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/utils/platform_paths.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import 'folder_name_dialog.dart';

/// Folders strip for the My Characters root view: a horizontal row of circular
/// folder covers. Tapping opens a folder; long-pressing exposes rename/delete.
/// New folders are created from the screen's add (FAB) menu, not here.
///
/// When [showOurPicks] is set, a special "Our Picks" circle leads the row. It
/// is not a real folder — it cannot be renamed, deleted, or have characters
/// added/removed; long-pressing only offers to hide it.
///
/// When [showFavorites] is set, a special "Favorites" circle is shown. Like
/// Our Picks it is not a real folder: its contents come from each character's
/// `fav` flag, so it can't be renamed, deleted, or hidden, and membership is
/// only changed via the per-character favorite/unfavorite actions.
class CharacterFoldersSection extends ConsumerWidget {
  final ValueChanged<String> onOpenFolder;
  final bool showOurPicks;
  final VoidCallback? onOpenPicks;
  final VoidCallback? onHidePicks;
  final bool showFavorites;
  final VoidCallback? onOpenFavorites;

  const CharacterFoldersSection({
    super.key,
    required this.onOpenFolder,
    this.showOurPicks = false,
    this.onOpenPicks,
    this.onHidePicks,
    this.showFavorites = false,
    this.onOpenFavorites,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(characterFoldersProvider).value ?? const [];
    if (folders.isEmpty && !showOurPicks && !showFavorites) {
      return const SizedBox.shrink();
    }

    final memberships =
        ref.watch(folderMembershipsProvider).value ?? FolderMemberships.empty;
    final allChars = ref.watch(charactersProvider).value ?? const [];
    final byId = {for (final c in allChars) c.id: c};

    List<Character> membersOf(String folderId) => memberships
        .charsIn(folderId)
        .map((id) => byId[id])
        .whereType<Character>()
        .toList();

    final tiles = <Widget>[
      // Our Picks always leads the row, ahead of Favorites and real folders.
      if (showOurPicks)
        _OurPicksCircle(
          onTap: () => onOpenPicks?.call(),
          onLongPress: () => _picksActions(context),
        ),
      if (showFavorites)
        _FavoritesCircle(onTap: () => onOpenFavorites?.call()),
      for (final folder in folders)
        _FolderCircle(
          folder: folder,
          members: membersOf(folder.id),
          onTap: () => onOpenFolder(folder.id),
          onLongPress: () => _folderActions(context, ref, folder),
        ),
    ];

    return SizedBox(
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        itemCount: tiles.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (ctx, i) => tiles[i],
      ),
    );
  }

  void _picksActions(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Our Picks',
      items: [
        BottomSheetItem(
          icon: Icons.visibility_off_rounded,
          label: 'action_hide_msg'.tr(),
          hint: 'our_picks_restore_hint'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            onHidePicks?.call();
          },
        ),
      ],
    );
  }

  void _folderActions(
    BuildContext context,
    WidgetRef ref,
    CharacterFolder folder,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: folder.name,
      items: [
        BottomSheetItem(
          icon: Icons.edit_rounded,
          label: 'folder_rename_title'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _renameFolder(context, ref, folder);
          },
        ),
        BottomSheetItem(
          icon: Icons.delete_rounded,
          label: 'folder_delete_title'.tr(),
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _confirmDelete(context, ref, folder);
          },
        ),
      ],
    );
  }

  void _renameFolder(
    BuildContext context,
    WidgetRef ref,
    CharacterFolder folder,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'folder_rename_title'.tr(),
      child: FolderNameDialog(
        initialName: folder.name,
        confirmLabel: 'btn_save'.tr(),
        onSubmit: (name) =>
            ref.read(characterFolderRepoProvider).rename(folder.id, name),
      ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    CharacterFolder folder,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'folder_delete_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'folder_delete_confirm'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref.read(characterFolderRepoProvider).delete(folder.id);
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

/// A single circular folder cover with its name beneath it.
class _FolderCircle extends StatelessWidget {
  static const double _diameter = 64;

  final CharacterFolder folder;
  final List<Character> members;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _FolderCircle({
    required this.folder,
    required this.members,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _diameter,
              height: _diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: context.cs.primary.withValues(alpha: 0.25),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipOval(child: _cover(context)),
            ),
            const SizedBox(height: 6),
            Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(BuildContext context) {
    final avatar = members
        .map((c) => c.avatarPath)
        .where((p) => p != null && p.isNotEmpty)
        .map((p) => resolveGlazeFilePath(p!))
        .whereType<String>()
        .firstOrNull;

    if (avatar == null) return _placeholder(context);
    return Image.file(
      File(avatar),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => _placeholder(context),
    );
  }

  Widget _placeholder(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            context.cs.primary.withValues(alpha: 0.35),
            context.cs.surfaceContainerHighest,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.folder_rounded,
          size: 26,
          color: Colors.white.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// Special leading circle for the curated "Our Picks" collection. Shaped like a
/// folder circle but visually distinct (star + brand gradient) and not backed
/// by a real folder.
class _OurPicksCircle extends StatelessWidget {
  static const double _diameter = 64;

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _OurPicksCircle({required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _diameter,
              height: _diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [context.cs.primary, context.cs.secondary],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.25),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  Icons.star_rounded,
                  size: 30,
                  color: Colors.white.withValues(alpha: 0.95),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Our Picks',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Special circle for the virtual "Favorites" collection. Shaped like a folder
/// circle but visually distinct (heart + warm gradient) and not backed by a
/// real folder. It has no long-press actions: it can't be renamed, deleted, or
/// hidden, and membership is driven solely by each character's favorite flag.
class _FavoritesCircle extends StatelessWidget {
  static const double _diameter = 64;
  static const Color _favColor = Color(0xFFFF6B6B);

  final VoidCallback onTap;

  const _FavoritesCircle({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _diameter,
              height: _diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_favColor, Color(0xFFB23A6B)],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.25),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  Icons.favorite_rounded,
                  size: 28,
                  color: Colors.white.withValues(alpha: 0.95),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'folder_favorites'.tr(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
