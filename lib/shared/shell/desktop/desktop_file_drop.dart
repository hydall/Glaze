import 'package:desktop_drop/desktop_drop.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/character_list/dropped_files_provider.dart';
import '../../theme/app_colors.dart';
import '../../widgets/glaze_toast.dart';

/// Accepts character cards dropped onto the window from the file manager.
///
/// The Vue app had `DragDropOverlay.vue` for this; the Flutter port had no
/// equivalent, so importing on desktop meant going through the file picker
/// every time. Dropped paths are handed to [CharacterListScreen] through
/// [droppedCharacterFilesProvider], which owns the bulk-import flow.
class DesktopFileDrop extends ConsumerStatefulWidget {
  final Widget child;

  const DesktopFileDrop({super.key, required this.child});

  @override
  ConsumerState<DesktopFileDrop> createState() => _DesktopFileDropState();
}

class _DesktopFileDropState extends ConsumerState<DesktopFileDrop> {
  bool _dragging = false;

  void _onDrop(DropDoneDetails details) {
    setState(() => _dragging = false);
    final paths = filterImportableCardPaths(details.files.map((f) => f.path));
    if (paths.isEmpty) {
      GlazeToast.show(context, 'import_unsupported_file'.tr());
      return;
    }
    ref.read(droppedCharacterFilesProvider.notifier).state = paths;
    // The importer lives on the characters screen, so make sure it is mounted.
    context.go('/characters');
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _onDrop,
      child: Stack(
        children: [
          widget.child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: context.cs.primary.withValues(alpha: 0.12),
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.cs.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: context.cs.primary, width: 2),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 22,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.file_download_outlined,
                              size: 36,
                              color: context.cs.primary,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'action_import'.tr(),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: context.cs.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
