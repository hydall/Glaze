import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_spinner.dart';

/// Shown over the game while the model writes a new one.
class VnGeneratingBadge extends StatelessWidget {
  const VnGeneratingBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GlazeSpinner(size: 16, strokeWidth: 2),
                const SizedBox(width: 10),
                Text(
                  'vn_generating'.tr(),
                  style: TextStyle(color: context.cs.onSurface, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
