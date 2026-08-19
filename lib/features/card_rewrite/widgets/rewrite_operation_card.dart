import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/db/repositories/manual_rewrite_job_repo.dart';
import '../../../core/services/card_rewriter/card_rewriter_contracts.dart';
import '../../../shared/theme/app_colors.dart';
import 'rewrite_anchored_diff_pane.dart';
import 'rewrite_evidence_accordion.dart';

/// One reviewable rewrite operation: status header, anchored patch diffs,
/// decision controls, evidence accordion.
///
/// Decision buttons lock the decision to the operation's current immutable
/// revision (the repo CAS enforces that binding); an edit appends a fresh
/// revision and resets the decision, surfacing the "edited" badge here.
class RewriteOperationCard extends StatelessWidget {
  const RewriteOperationCard({
    super.key,
    required this.index,
    required this.view,
    required this.snapshot,
    required this.fieldValue,
    required this.violations,
    required this.lockedKeys,
    required this.previewReady,
    required this.interactionsEnabled,
    this.selected = false,
    this.onTap,
    this.onApprove,
    this.onReject,
    this.onEdit,
    this.onDeletePatch,
  });

  final int index;
  final ManualRewriteOperationView view;
  final CardRewriteOperationSnapshot? snapshot;

  /// Current content of the operation's field (null while loading).
  final String? fieldValue;
  final List<CardPatchViolation> violations;
  final Set<String> lockedKeys;

  /// False while the live character row is still loading.
  final bool previewReady;

  /// False in generating/terminal job states and while an apply is in flight.
  final bool interactionsEnabled;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onEdit;
  final void Function(int patchIndex)? onDeletePatch;

  bool get _invalid =>
      view.operation.validationStatus == 'invalid' || violations.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final op = view.operation;
    final reviewable = op.status == 'reviewable';
    final decisionBound = op.decisionRevision == op.currentRevision;
    final edited = op.currentRevision > 1 && op.decision == 'pending';

    final String? approveBlock;
    if (!editPermitted(interactionsEnabled, reviewable)) {
      approveBlock = null; // terminal/applying: buttons hidden entirely
    } else if (!previewReady) {
      approveBlock = 'rewrite_block_loading'.tr();
    } else if (lockedKeys.isNotEmpty) {
      approveBlock = 'rewrite_btn_approve_disabled_lock'.tr();
    } else if (_invalid) {
      approveBlock = 'rewrite_btn_approve_disabled_invalid'.tr();
    } else {
      approveBlock = null;
    }

    return Material(
      color: cs.surfaceContainerHigh.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected
              ? cs.primary.withValues(alpha: 0.55)
              : cs.outlineVariant,
          width: selected ? 1.4 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '#${index + 1}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: cs.primary.withValues(alpha: 0.08),
                        border: Border.all(
                          color: cs.primary.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Text(
                        snapshot?.transition.scopeKey ?? '—',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: cs.primary,
                        ),
                      ),
                    ),
                  ),
                  if (edited) ...[
                    const SizedBox(width: 6),
                    _Badge(
                      icon: Icons.edit_note_rounded,
                      label: 'rewrite_badge_edited'.tr(),
                      color: cs.tertiary,
                    ),
                  ],
                  if (!reviewable) ...[
                    const SizedBox(width: 6),
                    _Badge(
                      icon: op.status == 'applied'
                          ? Icons.check_circle_outline_rounded
                          : Icons.pause_circle_outline_rounded,
                      label: op.status,
                      color: op.status == 'applied' ? cs.primary : cs.outline,
                    ),
                  ],
                  const SizedBox(width: 8),
                  if (interactionsEnabled && reviewable)
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _DecisionButtons(
                          decision: decisionBound ? op.decision : 'pending',
                          canApprove: approveBlock == null,
                          onApprove: onApprove,
                          onReject: onReject,
                        ),
                      ),
                    )
                  else if (decisionBound && op.decision != 'pending')
                    _Badge(
                      icon: op.decision == 'approved'
                          ? Icons.check_circle_outline_rounded
                          : Icons.cancel_outlined,
                      label: op.decision == 'approved'
                          ? 'rewrite_decision_approved'.tr()
                          : 'rewrite_decision_rejected'.tr(),
                      color: op.decision == 'approved' ? cs.primary : cs.error,
                    ),
                ],
              ),
              if (approveBlock != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 13,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          approveBlock,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (snapshot == null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: _InvalidSnapshotNotice(),
                )
              else ...[
                if (violations.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 2),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final violation in violations.toSet())
                          _ViolationChip(violation: violation),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                for (final (patchIndex, patch)
                    in snapshot!.patches.indexed) ...[
                  RewriteAnchoredDiffPane(
                    patch: patch,
                    fieldValue: fieldValue,
                    onDelete:
                        editPermitted(interactionsEnabled, reviewable) &&
                            snapshot!.patches.length > 1
                        ? () => onDeletePatch?.call(patchIndex)
                        : null,
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    if (editPermitted(interactionsEnabled, reviewable))
                      TextButton.icon(
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: Text(
                          'rewrite_btn_edit'.tr(),
                          style: const TextStyle(fontSize: 12),
                        ),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: cs.primary,
                        ),
                      ),
                    const Spacer(),
                  ],
                ),
                RewriteEvidenceAccordion(
                  snapshot: snapshot!,
                  evidenceCount: view.evidenceCount,
                  lockedKeys: lockedKeys,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static bool editPermitted(bool interactionsEnabled, bool reviewable) =>
      interactionsEnabled && reviewable;
}

class _DecisionButtons extends StatelessWidget {
  const _DecisionButtons({
    required this.decision,
    required this.canApprove,
    required this.onApprove,
    required this.onReject,
  });

  final String decision;
  final bool canApprove;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 6,
      runSpacing: 6,
      children: [
        _DecisionPill(
          label: 'rewrite_btn_approve'.tr(),
          icon: Icons.check_rounded,
          active: decision == 'approved',
          color: cs.primary,
          onTap: canApprove && decision != 'approved' ? onApprove : null,
        ),
        _DecisionPill(
          label: 'rewrite_btn_reject'.tr(),
          icon: Icons.close_rounded,
          active: decision == 'rejected',
          color: cs.error,
          onTap: decision != 'rejected' ? onReject : null,
        ),
      ],
    );
  }
}

class _DecisionPill extends StatelessWidget {
  const _DecisionPill({
    required this.label,
    required this.icon,
    required this.active,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final disabled = onTap == null;
    final bg = active
        ? color.withValues(alpha: 0.18)
        : cs.onSurface.withValues(alpha: disabled ? 0.03 : 0.06);
    final fg = active
        ? color
        : cs.onSurfaceVariant.withValues(alpha: disabled ? 0.5 : 1);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: active ? color.withValues(alpha: 0.5) : cs.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ViolationChip extends StatelessWidget {
  const _ViolationChip({required this.violation});

  final CardPatchViolation violation;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final key = switch (violation) {
      CardPatchViolation.invalidScope => 'rewrite_violation_invalid_scope',
      CardPatchViolation.duplicateAnchor =>
        'rewrite_violation_duplicate_anchor',
      CardPatchViolation.staleAnchor => 'rewrite_violation_stale_anchor',
      CardPatchViolation.ambiguousAnchor =>
        'rewrite_violation_ambiguous_anchor',
      CardPatchViolation.incompleteSet => 'rewrite_violation_incomplete_set',
      CardPatchViolation.macroTokensChanged =>
        'rewrite_violation_macro_tokens_changed',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 12, color: cs.error),
          const SizedBox(width: 4),
          Text(
            key.tr(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cs.error,
            ),
          ),
        ],
      ),
    );
  }
}

class _InvalidSnapshotNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Row(
      children: [
        Icon(Icons.broken_image_outlined, size: 15, color: cs.error),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'rewrite_invalid_snapshot'.tr(),
            style: TextStyle(fontSize: 12, color: cs.error),
          ),
        ),
      ],
    );
  }
}

/// Compact row for the wide-layout operation rail (master pane).
class RewriteOperationRailTile extends StatelessWidget {
  const RewriteOperationRailTile({
    super.key,
    required this.index,
    required this.view,
    required this.scopeKey,
    required this.invalid,
    required this.locked,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final ManualRewriteOperationView view;
  final String scopeKey;
  final bool invalid;
  final bool locked;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final op = view.operation;
    final decisionColor = switch (op.decision) {
      'approved' => cs.primary,
      'rejected' => cs.error,
      _ => cs.onSurfaceVariant,
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected ? cs.primary.withValues(alpha: 0.10) : null,
          border: Border.all(
            color: selected
                ? cs.primary.withValues(alpha: 0.45)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Text(
              '#${index + 1}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                scopeKey,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            if (invalid)
              Icon(Icons.error_outline_rounded, size: 15, color: cs.error)
            else if (locked)
              Icon(Icons.lock_outline_rounded, size: 14, color: cs.error)
            else
              Icon(
                op.decision == 'approved'
                    ? Icons.check_circle_rounded
                    : op.decision == 'rejected'
                    ? Icons.cancel_rounded
                    : Icons.circle_outlined,
                size: 14,
                color: decisionColor,
              ),
          ],
        ),
      ),
    );
  }
}
