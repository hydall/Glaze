import 'package:flutter/material.dart';

import '../../../core/models/preset_folder.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import 'preset_small_badge.dart';

/// Folder row of the Presets list.
///
/// Deliberately the same card as a preset row — same glass frame, circular
/// leading glyph, title and badge — so a folder reads as "a preset that holds
/// presets". Only the glyph (a folder) and the badge (member count instead of
/// the token estimate) differ.
class PresetFolderCard extends StatelessWidget {
  final PresetFolder folder;

  /// How many presets the folder holds, of either kind.
  final int count;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  const PresetFolderCard({
    super.key,
    required this.folder,
    required this.count,
    required this.onTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      enableRipple: true,
      // Full alpha for the same reason the preset card pins its tint: a
      // translucent theme colour would otherwise render this card thinner than
      // the rows below it.
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
              child: Icon(
                Icons.folder_rounded,
                size: 20,
                color: context.cs.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      // A folder, not the preset card's token glyph — the
                      // number here counts members, not tokens.
                      PresetSmallBadge(
                        icon: Icons.folder_rounded,
                        label: '$count',
                      ),
                    ],
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
