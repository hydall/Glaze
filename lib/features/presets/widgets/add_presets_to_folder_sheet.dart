import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/preset_folder.dart';
import '../../../core/state/preset_folder_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/folder_name_dialog.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/sheet_view.dart';

/// A preset the folder sheet can act on, identified the way membership rows
/// store it.
class PresetFolderTarget {
  final String id;
  final PresetKind kind;

  const PresetFolderTarget(this.id, this.kind);
}

/// Bulk "add to folder" sheet for the Presets list: tapping a folder adds every
/// preset in [targets] to it at once, then closes and runs [onDone]. Mirrors
/// `AddCharactersToFolderSheet`.
class AddPresetsToFolderSheet extends ConsumerWidget {
  final List<PresetFolderTarget> targets;
  final VoidCallback? onDone;

  const AddPresetsToFolderSheet({
    super.key,
    required this.targets,
    this.onDone,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(presetFoldersProvider).value ?? const [];
    final memberships =
        ref.watch(presetFolderMembershipsProvider).value ??
        PresetFolderMemberships.empty;
    final repo = ref.read(presetFolderRepoProvider);

    Future<void> addAllTo(String folderId) async {
      for (final t in targets) {
        await repo.addMember(folderId, t.id, t.kind);
      }
    }

    return SheetView(
      title: 'action_add_to_folder'.tr(),
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _NewFolderTile(
            onTap: () => GlazeBottomSheet.show<void>(
              context,
              title: 'folder_create_title'.tr(),
              child: FolderNameDialog(
                confirmLabel: 'btn_create'.tr(),
                onSubmit: (name) async {
                  final folder = await repo.create(name: name);
                  await addAllTo(folder.id);
                  onDone?.call();
                },
              ),
            ),
          ),
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'preset_folder_empty'.tr(),
                  style: TextStyle(color: context.cs.onSurfaceVariant),
                ),
              ),
            ),
          for (final folder in folders)
            _FolderTile(
              name: folder.name,
              count: memberships.countFor(folder.id),
              onTap: () async {
                await addAllTo(folder.id);
                if (context.mounted) {
                  Navigator.of(context, rootNavigator: true).pop();
                }
                onDone?.call();
              },
            ),
        ],
      ),
    );
  }
}

class _NewFolderTile extends StatelessWidget {
  final VoidCallback onTap;
  const _NewFolderTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: context.cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(
                  Icons.create_new_folder_rounded,
                  size: 20,
                  color: context.cs.primary,
                ),
                const SizedBox(width: 12),
                Text(
                  'folder_new'.tr(),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: context.cs.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  final String name;
  final int count;
  final VoidCallback onTap;

  const _FolderTile({
    required this.name,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(
                  Icons.folder_rounded,
                  size: 20,
                  color: context.cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, color: context.cs.onSurface),
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
