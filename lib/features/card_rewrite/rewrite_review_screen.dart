import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/repositories/manual_rewrite_job_repo.dart';
import '../../core/db/app_db.dart' show RewriteJobRow;
import '../../core/models/character.dart';
import '../../core/services/card_rewriter/card_rewriter_contracts.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_toast.dart';
import 'rewrite_review_provider.dart';
import 'widgets/rewrite_operation_card.dart';
import 'widgets/rewrite_anchored_diff_pane.dart';

/// Durable review route. It deliberately reads the job aggregate again instead
/// of receiving editor state, so a link/restart always shows the saved review.
class RewriteReviewScreen extends ConsumerWidget {
  const RewriteReviewScreen({
    super.key,
    required this.charId,
    required this.jobId,
  });

  final String charId;
  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(rewriteJobSnapshotProvider(jobId));
    final job = snapshot.whenOrNull(data: (value) => value)?.job;
    final sessionIndex = job == null
        ? null
        : ref
              .watch(rewriteSessionIndexProvider(job.chatSessionId))
              .whenOrNull(data: (value) => value);
    final backLocation = sessionIndex == null
        ? '/chat/$charId'
        : '/chat/$charId?session=$sessionIndex';
    return GlazeScaffold(
      title: 'rewrite_title'.tr(),
      onBack: () => context.go(backLocation),
      body: snapshot.when(
        loading: () => const Center(child: GlazeSpinner()),
        error: (_, _) => _MessageState(
          icon: Icons.error_outline,
          text: 'rewrite_load_failed'.tr(),
        ),
        data: (data) => data == null
            ? _MessageState(
                icon: Icons.find_in_page_outlined,
                text: 'rewrite_not_found'.tr(),
              )
            : _ReviewBody(
                snapshot: data,
                jobId: jobId,
                backLocation: backLocation,
              ),
      ),
    );
  }
}

class _ReviewBody extends ConsumerWidget {
  const _ReviewBody({
    required this.snapshot,
    required this.jobId,
    required this.backLocation,
  });
  final ManualRewriteJobSnapshot snapshot;
  final String jobId;
  final String backLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(rewriteReviewUiProvider(jobId));
    final controller = ref.read(rewriteReviewUiProvider(jobId).notifier);
    final character = ref.watch(
      rewriteCharacterProvider(snapshot.job.characterId),
    );
    final controls = ref.watch(
      rewriteManualControlsProvider(snapshot.job.chatSessionId),
    );
    final isPending = snapshot.job.status == 'pending';
    final interactive = isPending && !ui.busy;
    final lockedNames =
        controls.whenOrNull(data: (value) => value) ?? const <String>{};
    final currentCharacter = character.whenOrNull(data: (value) => value);
    final cards = <Widget>[
      for (var i = 0; i < snapshot.operations.length; i++)
        _OperationItem(
          index: i,
          view: snapshot.operations[i],
          character: currentCharacter,
          controls: lockedNames,
          selected:
              ui.selectedOperationId == snapshot.operations[i].operation.id,
          enabled: interactive,
          onSelect: () =>
              controller.selectOperation(snapshot.operations[i].operation.id),
        ),
    ];
    final railTiles = <Widget>[
      for (var i = 0; i < snapshot.operations.length; i++)
        () {
          final view = snapshot.operations[i];
          final operation = decodeRewriteOperationSnapshot(
            view.currentSnapshotJson,
          );
          final scopeKey = switch (operation) {
            CardRewriteOperationSnapshot card => card.transition.scopeKey,
            LorebookRewriteOperationSnapshot lore =>
              'lorebook:${lore.lorebookId}/${lore.entryId}',
            _ => 'invalid operation',
          };
          final locked =
              operation is CardRewriteOperationSnapshot &&
              lockOverlap(operation, lockedNames).isNotEmpty;
          return RewriteOperationRailTile(
            index: i,
            view: view,
            scopeKey: scopeKey,
            invalid:
                view.operation.validationStatus == 'invalid' ||
                operation == null,
            locked: locked,
            selected: ui.selectedOperationId == view.operation.id,
            onTap: () => controller.selectOperation(view.operation.id),
          );
        }(),
    ];
    return Column(
      children: [
        _StatusStrip(snapshot: snapshot, freshness: ui.freshness),
        _JobActions(
          job: snapshot.job,
          jobId: jobId,
          backLocation: backLocation,
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 768 && cards.isNotEmpty) {
                final index = ui.selectedOperationId == null
                    ? 0
                    : snapshot.operations.indexWhere(
                        (v) => v.operation.id == ui.selectedOperationId,
                      );
                final safeIndex = index < 0 ? 0 : index;
                return Row(
                  children: [
                    SizedBox(
                      width: 320,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: railTiles,
                      ),
                    ),
                    VerticalDivider(color: context.cs.outlineVariant, width: 1),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(20),
                        children: [cards[safeIndex]],
                      ),
                    ),
                  ],
                );
              }
              return ListView(
                padding: const EdgeInsets.all(16),
                children: cards.isEmpty
                    ? [
                        _MessageState(
                          icon: Icons.inbox_outlined,
                          text: 'rewrite_empty'.tr(),
                        ),
                      ]
                    : cards,
              );
            },
          ),
        ),
        _ApplyFooter(
          snapshot: snapshot,
          jobId: jobId,
          backLocation: backLocation,
          enabled: interactive,
          manualControlNames: lockedNames,
        ),
      ],
    );
  }
}

class _OperationItem extends ConsumerWidget {
  const _OperationItem({
    required this.index,
    required this.view,
    required this.character,
    required this.controls,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });
  final int index;
  final ManualRewriteOperationView view;
  final Character? character;
  final Set<String> controls;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelect;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decoded = decodeRewriteOperationSnapshot(view.currentSnapshotJson);
    if (decoded case LorebookRewriteOperationSnapshot lore) {
      return _LorebookOperationItem(
        index: index,
        view: view,
        snapshot: lore,
        selected: selected,
        enabled: enabled,
        onSelect: onSelect,
      );
    }
    final snapshot = decoded is CardRewriteOperationSnapshot ? decoded : null;
    final locked = snapshot == null
        ? <String>{}
        : lockOverlap(snapshot, controls);
    final card = character;
    final violations = snapshot == null || card == null
        ? const <CardPatchViolation>[]
        : advisoryViolations(snapshot, card);
    final fieldValue = snapshot == null || card == null
        ? null
        : rewrittenFieldValue(card, snapshot.field);
    final controller = ref.read(
      rewriteReviewUiProvider(view.operation.rewriteJobId).notifier,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: RewriteOperationCard(
        index: index,
        view: view,
        snapshot: snapshot,
        fieldValue: fieldValue,
        violations: violations,
        lockedKeys: locked,
        previewReady: character != null,
        interactionsEnabled: enabled,
        selected: selected,
        onTap: onSelect,
        onApprove: () async {
          final result = await controller.decide(view, 'approved');
          if (context.mounted) _showOutcome(context, result);
        },
        onReject: () async {
          final result = await controller.decide(view, 'rejected');
          if (context.mounted) _showOutcome(context, result);
        },
        onEdit: snapshot == null
            ? null
            : () => _edit(context, controller, view, snapshot),
        onDeletePatch: (patchIndex) =>
            _confirmDeletePatch(context, controller, view, patchIndex),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    RewriteReviewController controller,
    ManualRewriteOperationView view,
    CardRewriteOperationSnapshot snapshot,
  ) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _EditDialog(
        initial: snapshot.patches.map((p) => p.value).join('\n\n'),
      ),
    );
    if (value == null) return;
    final values = value.split('\n\n');
    final result = await controller.saveEdit(view, values);
    if (context.mounted) _showOutcome(context, result);
  }

  void _confirmDeletePatch(
    BuildContext context,
    RewriteReviewController controller,
    ManualRewriteOperationView view,
    int patchIndex,
  ) {
    _showDeletePatchConfirmation(context, () async {
      final result = await controller.deletePatch(view, patchIndex);
      if (context.mounted && result != 'updated') {
        _showOutcome(context, result);
      }
    });
  }
}

class _LorebookOperationItem extends ConsumerWidget {
  const _LorebookOperationItem({
    required this.index,
    required this.view,
    required this.snapshot,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  final int index;
  final ManualRewriteOperationView view;
  final LorebookRewriteOperationSnapshot snapshot;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operation = view.operation;
    final controller = ref.read(
      rewriteReviewUiProvider(operation.rewriteJobId).notifier,
    );
    final reviewable = operation.status == 'reviewable';
    final canApprove =
        enabled && reviewable && operation.validationStatus == 'valid';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? context.cs.primary : context.cs.outlineVariant,
            ),
            color: context.cs.surfaceContainerHigh.withValues(alpha: 0.35),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '#${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Lorebook ${snapshot.lorebookId} / ${snapshot.entryId}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (reviewable && enabled) ...[
                    TextButton(
                      onPressed: canApprove
                          ? () async {
                              final result = await controller.decide(
                                view,
                                'approved',
                              );
                              if (context.mounted) {
                                _showOutcome(context, result);
                              }
                            }
                          : null,
                      child: Text('rewrite_btn_approve'.tr()),
                    ),
                    TextButton(
                      onPressed: () async {
                        final result = await controller.decide(
                          view,
                          'rejected',
                        );
                        if (context.mounted) _showOutcome(context, result);
                      },
                      child: Text('rewrite_btn_reject'.tr()),
                    ),
                  ],
                ],
              ),
              if (operation.validationStatus == 'invalid')
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'rewrite_btn_approve_disabled_invalid'.tr(),
                    style: TextStyle(color: context.cs.error, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 10),
              for (final patch in snapshot.patches) ...[
                RewriteAnchoredDiffPane.lorebook(
                  patch: patch,
                  fieldValue: snapshot.baseContent,
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ApplyFooter extends ConsumerWidget {
  const _ApplyFooter({
    required this.snapshot,
    required this.jobId,
    required this.backLocation,
    required this.enabled,
    required this.manualControlNames,
  });
  final ManualRewriteJobSnapshot snapshot;
  final String jobId;
  final String backLocation;
  final bool enabled;
  final Set<String> manualControlNames;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final approved = snapshot.operations
        .where((v) => v.operation.decision == 'approved')
        .length;
    final hasPending = snapshot.operations.any(
      (view) =>
          view.operation.status == 'reviewable' &&
          view.operation.decision == 'pending',
    );
    final canApply = enabled && approved > 0;
    final canApproveAll =
        enabled &&
        snapshot.operations.any((view) {
          final op = view.operation;
          final operationSnapshot = decodeRewriteOperationSnapshot(
            view.currentSnapshotJson,
          );
          return op.status == 'reviewable' &&
              op.decision == 'pending' &&
              op.validationStatus == 'valid' &&
              operationSnapshot != null &&
              (operationSnapshot is! CardRewriteOperationSnapshot ||
                  lockOverlap(operationSnapshot, manualControlNames).isEmpty);
        });
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Text(
                'rewrite_apply_summary'.tr(namedArgs: {'count': '$approved'}),
              ),
              TextButton.icon(
                onPressed: canApproveAll
                    ? () => _approveAll(context, ref)
                    : null,
                icon: const Icon(Icons.done_all_rounded),
                label: Text('rewrite_approve_all'.tr()),
              ),
              if (approved == 0)
                TextButton.icon(
                  onPressed: enabled
                      ? () => _rejectAndClose(context, ref, hasPending)
                      : null,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Reject and close'),
                  style: TextButton.styleFrom(
                    foregroundColor: context.cs.error,
                  ),
                ),
              FilledButton.icon(
                onPressed: canApply ? () => _confirm(context, ref) : null,
                icon: const Icon(Icons.done_all_rounded),
                label: Text('rewrite_apply'.tr()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _approveAll(BuildContext context, WidgetRef ref) async {
    final approved = await ref
        .read(rewriteReviewUiProvider(jobId).notifier)
        .approveAllValid(
          ops: snapshot.operations,
          manualControlNames: manualControlNames,
        );
    if (context.mounted) {
      GlazeToast.show(
        context,
        'rewrite_approve_all_result'.tr(namedArgs: {'count': '$approved'}),
      );
    }
  }

  Future<void> _rejectAndClose(
    BuildContext context,
    WidgetRef ref,
    bool hasPending,
  ) async {
    if (hasPending) {
      await ref
          .read(rewriteReviewUiProvider(jobId).notifier)
          .rejectAllPending(ops: snapshot.operations);
    }
    await ref.read(rewriteReviewUiProvider(jobId).notifier).cancelJob(jobId);
    if (context.mounted) context.go(backLocation);
  }

  void _confirm(BuildContext context, WidgetRef ref) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'rewrite_apply_confirm_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.warning_amber_rounded,
        description: 'rewrite_apply_confirm_body'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'rewrite_apply'.tr(),
          centered: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            final outcome = await ref
                .read(rewriteReviewUiProvider(jobId).notifier)
                .apply(snapshot);
            if (context.mounted) {
              GlazeToast.show(
                context,
                'rewrite_apply_result'.tr(namedArgs: {'result': outcome.kind}),
              );
            }
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.snapshot, required this.freshness});
  final ManualRewriteJobSnapshot snapshot;
  final RewriteCanonFreshness freshness;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: GlassSurface(
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 5,
          children: [
            Text(
              'rewrite_status_${snapshot.job.status}'.tr(),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(
              'rewrite_session_basis'.tr(
                namedArgs: {
                  'session': snapshot.job.chatSessionId,
                  'basis': '${snapshot.job.basisRevision}',
                },
              ),
              style: TextStyle(color: context.cs.onSurfaceVariant),
            ),
            Text(
              'rewrite_freshness_${freshness.name}'.tr(),
              style: TextStyle(color: context.cs.primary),
            ),
            if (snapshot.job.statusReason case final reason?)
              Text(
                'rewrite_status_reason'.tr(namedArgs: {'reason': reason}),
                style: TextStyle(color: context.cs.error),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Actions remain deliberately tied to the durable job status. There is no
/// optimistic state here: the watched job row is the source of truth after a
/// cancel or retry request completes.
class _JobActions extends ConsumerWidget {
  const _JobActions({
    required this.job,
    required this.jobId,
    required this.backLocation,
  });

  final RewriteJobRow job;
  final String jobId;
  final String backLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final generating = job.status == 'generating';
    final pending = job.status == 'pending';
    final failed = job.status == 'failed';
    final cancelled = job.status == 'cancelled';
    final automated = isAutomatedEvolutionJob(job);
    final canReplaceAutomated = automated && (pending || failed || cancelled);
    if (!generating && !failed && !canReplaceAutomated) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                generating
                    ? 'rewrite_generating_hint'.tr()
                    : pending
                    ? 'rewrite_regenerate_hint'.tr()
                    : 'rewrite_failed_hint'.tr(),
                style: TextStyle(
                  fontSize: 12,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              if (failed && !automated)
                OutlinedButton.icon(
                  key: const Key('rewrite-retry-button'),
                  onPressed: () => _retry(context, ref),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text('rewrite_retry'.tr()),
                ),
              if (canReplaceAutomated) ...[
                OutlinedButton.icon(
                  key: const Key('rewrite-regenerate-button'),
                  onPressed: () => _regenerate(context, ref),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text('rewrite_regenerate'.tr()),
                ),
                OutlinedButton.icon(
                  key: const Key('rewrite-delete-button'),
                  onPressed: () => _delete(context, ref),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: Text('rewrite_delete'.tr()),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.cs.error,
                  ),
                ),
              ] else
                OutlinedButton.icon(
                  key: const Key('rewrite-cancel-button'),
                  onPressed: () => _cancel(context, ref),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: Text('rewrite_cancel'.tr()),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.cs.error,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    await ref.read(rewriteReviewUiProvider(jobId).notifier).cancelJob(job.id);
    if (context.mounted) {
      GlazeToast.show(context, 'rewrite_cancel_requested'.tr());
    }
  }

  Future<void> _retry(BuildContext context, WidgetRef ref) async {
    final result = await ref
        .read(rewriteReviewUiProvider(jobId).notifier)
        .retry(job);
    if (context.mounted) {
      GlazeToast.show(
        context,
        (result == 'updated' ? 'rewrite_retry_started' : 'rewrite_retry_result')
            .tr(namedArgs: {'result': result}),
      );
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final outcome = await ref
        .read(rewriteReviewUiProvider(jobId).notifier)
        .deleteAutomatedProposal(job);
    if (!context.mounted) return;
    if (outcome.isDeleted) {
      context.go(backLocation);
    } else {
      GlazeToast.show(
        context,
        'rewrite_delete_result'.tr(namedArgs: {'result': outcome.kind}),
      );
    }
  }

  Future<void> _regenerate(BuildContext context, WidgetRef ref) async {
    final outcome = await ref
        .read(rewriteReviewUiProvider(jobId).notifier)
        .regenerateAutomatedProposal(job);
    if (!context.mounted) return;
    final replacement = outcome.job;
    if (outcome.kind == 'persisted' && replacement != null) {
      context.go(
        '/character/${Uri.encodeComponent(replacement.characterId)}/rewrite/'
        '${Uri.encodeComponent(replacement.id)}',
      );
      return;
    }
    GlazeToast.show(
      context,
      'rewrite_regenerate_result'.tr(namedArgs: {'result': outcome.kind}),
    );
    context.go(backLocation);
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 36, color: context.cs.onSurfaceVariant),
        const SizedBox(height: 10),
        Text(text),
      ],
    ),
  );
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.initial});
  final String initial;
  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final TextEditingController controller = TextEditingController(
    text: widget.initial,
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('rewrite_edit_title'.tr()),
    content: TextField(controller: controller, minLines: 5, maxLines: 12),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text('btn_cancel'.tr()),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text),
        child: Text('rewrite_save_revision'.tr()),
      ),
    ],
  );
}

void _showOutcome(BuildContext context, String outcome) {
  if (outcome != 'updated') {
    GlazeToast.show(
      context,
      'rewrite_action_result'.tr(namedArgs: {'result': outcome}),
    );
  }
}

void _showDeletePatchConfirmation(
  BuildContext context,
  Future<void> Function() onDelete,
) {
  GlazeBottomSheet.show<void>(
    context,
    title: 'rewrite_delete_patch_confirm_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.delete_outline_rounded,
      description: 'rewrite_delete_patch_confirm_body'.tr(),
    ),
    items: [
      BottomSheetItem(
        label: 'rewrite_delete_patch'.tr(),
        centered: true,
        onTap: () async {
          Navigator.of(context, rootNavigator: true).pop();
          await onDelete();
        },
      ),
      BottomSheetItem(
        label: 'btn_cancel'.tr(),
        centered: true,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}
