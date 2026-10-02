import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../models/vn_document.dart';
import '../vn_labels.dart';
import '../vn_provider.dart';
import 'vn_cast_review.dart';

/// The passes of a novel that cannot be played yet, ticked off as the model
/// writes them. A novel that draws its cast adds the drawing right after the
/// characters, and the cast to check and accept below the list.
class VnSetupView extends StatelessWidget {
  const VnSetupView({super.key, required this.state, required this.onRetry});

  final VnState state;
  final VoidCallback onRetry;

  static const _passes = [...kVnSetupPasses, VnPass.chapter];

  @override
  Widget build(BuildContext context) {
    final pending = state.doc.pendingPass;
    final error = state.error;
    final hasCast = state.doc.setup.containsKey(VnPass.characters);
    final review = state.drawsCast && hasCast && state.awaitingCastReview;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                state.doc.title ?? 'vn_setup_title'.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurface,
                ),
              ),
              if (state.doc.premise.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  state.doc.premise,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              for (final pass in _passes) ...[
                _PassRow(
                  label: vnPassLabel(pass),
                  done: pending == null || pass.index < pending.index,
                  active: pass == state.writing,
                  failed: error != null && pass == pending,
                ),
                if (pass == VnPass.characters && state.drawsCast)
                  _PassRow(
                    label: 'vn_art_pass'.tr(),
                    done: !state.awaitingCastReview,
                    active: state.drawing != null,
                    failed: state.artError != null,
                  ),
              ],
              if (error != null) ...[
                const SizedBox(height: 16),
                GlazeErrorBlock(message: vnErrorText(error)),
                const SizedBox(height: 12),
                GlazeActionButton(
                  icon: Icons.refresh,
                  label: 'vn_retry'.tr(),
                  tone: GlazeActionTone.primary,
                  expand: true,
                  onTap: onRetry,
                ),
              ],
              if (review) ...[
                const SizedBox(height: 20),
                VnCastReview(sessionId: state.session.id, gate: true),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PassRow extends StatelessWidget {
  const _PassRow({
    required this.label,
    required this.done,
    required this.active,
    required this.failed,
  });

  final String label;
  final bool done;
  final bool active;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final Widget mark = active
        ? const GlazeSpinner(size: 18, strokeWidth: 2)
        : Icon(
            failed
                ? Icons.error_outline
                : done
                ? Icons.check_circle
                : Icons.radio_button_unchecked,
            size: 18,
            color: failed
                ? context.cs.error
                : done
                ? context.cs.primary
                : context.cs.onSurfaceVariant,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox.square(dimension: 20, child: Center(child: mark)),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: done || active
                  ? context.cs.onSurface
                  : context.cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
