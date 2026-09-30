import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/services/card_rewriter/card_rewriter_contracts.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_expansion_tile.dart';

/// Immutable transition + evidence read-out for one operation.
///
/// The durable rows behind this panel are write-once (operation revisions and
/// evidence rows are append-only), so everything here is strictly display-only:
/// no affordance may ever mutate a transition from this accordion.
class RewriteEvidenceAccordion extends StatelessWidget {
  const RewriteEvidenceAccordion({
    super.key,
    required this.snapshot,
    required this.evidenceCount,
    required this.lockedKeys,
  });

  final CardRewriteOperationSnapshot snapshot;
  final int evidenceCount;

  /// Subset of `transition.affectedTrackerKeys` currently under a manual
  /// `canon_lock:`/`canon_override:` — rendered as highlighted lock chips.
  final Set<String> lockedKeys;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final transition = snapshot.transition;
    return GlazeExpansionTile(
      leading: Icon(
        Icons.history_edu_outlined,
        size: 16,
        color: cs.onSurfaceVariant,
      ),
      title: Text(
        'rewrite_evidence_title'.tr(namedArgs: {'count': '$evidenceCount'}),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
        ),
      ),
      childrenPadding: const EdgeInsets.only(bottom: 4),
      children: [
        _row(
          context,
          icon: Icons.format_quote_outlined,
          label: 'rewrite_evidence_claim'.tr(),
          value: transition.canonicalClaim,
        ),
        _row(
          context,
          icon: Icons.output_outlined,
          label: 'rewrite_evidence_destination'.tr(),
          value: transition.promotionDestination.isEmpty
              ? '—'
              : transition.promotionDestination,
        ),
        _row(
          context,
          icon: Icons.public_outlined,
          label: 'rewrite_evidence_scope'.tr(),
          value: transition.chatSessionId == null
              ? 'rewrite_evidence_scope_global'.tr()
              : transition.chatSessionId!,
        ),
        _row(
          context,
          icon: Icons.tag,
          label: 'rewrite_evidence_transition_id'.tr(),
          value: transition.id,
          mono: true,
        ),
        _row(
          context,
          icon: Icons.link_outlined,
          label: 'rewrite_evidence_facts'.tr(
            namedArgs: {'count': '${transition.factIds.length}'},
          ),
          value: '',
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'rewrite_evidence_affected_keys'.tr(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 6),
        if (transition.affectedTrackerKeys.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'rewrite_evidence_no_keys'.tr(),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final key in transition.affectedTrackerKeys)
                _TrackerKeyChip(keyName: key, locked: lockedKeys.contains(key)),
            ],
          ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 12,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'rewrite_evidence_immutable_note'.tr(),
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    bool mono = false,
  }) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: cs.onSurface,
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackerKeyChip extends StatelessWidget {
  const _TrackerKeyChip({required this.keyName, required this.locked});

  final String keyName;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final base = locked ? cs.error : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: base.withValues(alpha: locked ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: base.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (locked) ...[
            Icon(Icons.lock_rounded, size: 11, color: cs.error),
            const SizedBox(width: 4),
          ],
          Text(
            keyName,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: locked ? FontWeight.w700 : FontWeight.w500,
              color: base,
            ),
          ),
        ],
      ),
    );
  }
}
