import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'glass_surface.dart';

/// One folder row in a generic [FolderSection]. Mirrors the Presets folder card
/// so every list that uses the shared folder layer reads the same.
class FolderCard extends StatelessWidget {
  final String name;

  /// How many members the folder holds.
  final int count;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  const FolderCard({
    super.key,
    required this.name,
    required this.count,
    required this.onTap,
    required this.onMenu,
    this.icon = Icons.folder_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      enableRipple: true,
      tint: context.cs.surfaceContainerHighest.withValues(alpha: 1.0),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.cs.outline),
      onTap: onTap,
      onLongPress: onMenu,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: context.cs.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20, color: context.cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 32,
              height: 34,
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  mouseCursor: SystemMouseCursors.click,
                  onTap: onMenu,
                  borderRadius: BorderRadius.circular(8),
                  child: Icon(
                    Icons.more_vert,
                    size: 18,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
