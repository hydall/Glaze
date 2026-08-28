import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/services/character_bulk_import_service.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_spinner.dart';

/// Blocking progress card for a mass character import.
///
/// The import runs card-by-card on the UI isolate and yields between cards, so
/// this dialog keeps repainting: it shows how far the run is, which file is
/// being read, and offers a cancel that stops the run at the next card (already
/// imported cards stay).
Future<void> showImportProgressDialog(
  BuildContext context, {
  required ValueListenable<CharacterBulkImportProgress> progress,
  required VoidCallback onCancel,
}) {
  return showGeneralDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    barrierLabel: 'import_progress',
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) =>
        _ImportProgressContent(progress: progress, onCancel: onCancel),
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
      child: child,
    ),
  );
}

class _ImportProgressContent extends StatelessWidget {
  final ValueListenable<CharacterBulkImportProgress> progress;
  final VoidCallback onCancel;

  const _ImportProgressContent({
    required this.progress,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return PopScope(
      // Leaving mid-run would orphan the loop with no way to dismiss it later —
      // the cancel button is the way out.
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x33FFFFFF)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: ValueListenableBuilder<CharacterBulkImportProgress>(
              valueListenable: progress,
              builder: (context, value, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        GlazeSpinner(size: 22, value: value.fraction),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'import_progress_title'.tr(),
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'import_progress_count'.tr(
                        args: ['${value.completed}', '${value.total}'],
                      ),
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.75),
                        fontSize: 13,
                      ),
                    ),
                    if (value.currentName.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        value.currentName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.45),
                          fontSize: 12,
                        ),
                      ),
                    ],
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: onCancel,
                        child: Text(
                          'btn_cancel'.tr(),
                          style: TextStyle(
                            color: cs.primary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
