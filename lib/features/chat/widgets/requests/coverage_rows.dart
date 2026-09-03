import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';

/// Rows of the coverage list: the next request, and one per past turn.
class CoverageNextRow extends StatelessWidget {
  const CoverageNextRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 18, color: context.cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'coverage_next_request'.tr(),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                  ),
                  Text(
                    'coverage_next_request_desc'.tr(),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: context.cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class CoverageTurnRow extends StatelessWidget {
  const CoverageTurnRow({
    super.key,
    required this.number,
    required this.message,
    required this.onTap,
  });

  final int number;
  final ChatMessage message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = message.content.trim().replaceAll(RegExp(r'\s+'), ' ');
    final lorebooks = message.triggeredLorebooks.length;
    final memories = message.triggeredMemories.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: context.cs.onSurface.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'requests_turn_numbered'.tr(args: ['$number']),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: context.cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          'coverage_row_counts'.tr(
                            args: ['$lorebooks', '$memories'],
                          ),
                          if (preview.isNotEmpty)
                            preview.length <= 40
                                ? preview
                                : '${preview.substring(0, 40)}…',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: context.cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
