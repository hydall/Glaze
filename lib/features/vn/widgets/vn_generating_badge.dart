import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_spinner.dart';

/// Shown over the game while the model writes the next chapter, or, with
/// [onRetry], after it failed to.
class VnGeneratingBadge extends StatelessWidget {
  const VnGeneratingBadge({super.key, required this.label, this.onRetry});

  final String label;

  /// Set when the last attempt failed; the badge then offers a retry.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = onRetry != null;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 12, left: 12, right: 12),
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onRetry,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (failed)
                    Icon(Icons.refresh, size: 16, color: context.cs.error)
                  else
                    const GlazeSpinner(size: 16, strokeWidth: 2),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      failed ? '$label · ${'vn_retry'.tr()}' : label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: failed ? context.cs.error : context.cs.onSurface,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
