import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_version.dart';
import '../../core/state/dev_mode_provider.dart';

/// Persistent build watermark pinned to the bottom-right of the screen.
///
/// Shows the build branch (when injected) above the build date, both aligned
/// to the right edge. Visible by default on the `staging` and `nightly`
/// channels and hidden on `stable`; either way it follows
/// [hideBuildWatermarkProvider], which is toggleable from the Dev settings.
/// Must be placed as a direct child of a [Stack].
class BuildWatermark extends ConsumerWidget {
  const BuildWatermark({super.key});

  String get _dateLabel {
    if (buildDate.isNotEmpty) return buildDate;
    // Fallback for local/dev builds where BUILD_DATE wasn't injected.
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.day)}/${two(now.month)}/${now.year} (dev)';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(hideBuildWatermarkProvider)) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 9,
      height: 1.0,
      letterSpacing: 0.2,
      fontWeight: FontWeight.w500,
      decoration: TextDecoration.none,
      color: cs.onSurface.withValues(alpha: 0.3),
    );
    return Positioned(
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (isBetaVersion)
                  Text(
                    'BETA',
                    textAlign: TextAlign.right,
                    style: style.copyWith(color: Colors.orange.withValues(alpha: 0.5)),
                  ),
                if (buildBranch.isNotEmpty)
                  Text(buildBranch, textAlign: TextAlign.right, style: style),
                Text(_dateLabel, textAlign: TextAlign.right, style: style),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
