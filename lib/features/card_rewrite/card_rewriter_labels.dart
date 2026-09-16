import 'package:easy_localization/easy_localization.dart';

import '../../core/db/repositories/card_evolution_repo.dart'
    show CardEvolutionFinalizeOutcome;

/// Localized labels for the Card Rewriter lane's stored enums.
///
/// The lane persists its stages, statuses and outcome kinds as bare strings, so
/// the management surface and the recovery tiles both have to turn them into
/// sentences. They live here rather than in either widget so the two can never
/// label the same stage differently.

/// What a finished (or refused) run should say in a toast.
String cardRewriterRunMessage(CardEvolutionFinalizeOutcome outcome) =>
    switch (outcome.kind) {
      'notEligible' => 'card_rewriter_studio_outcome_not_eligible'.tr(),
      'busy' => 'card_rewriter_studio_outcome_busy'.tr(),
      'activeJob' => 'card_rewriter_studio_outcome_active_job'.tr(),
      'modelNotConfigured' =>
        'card_rewriter_studio_outcome_model_not_configured'.tr(),
      'cardModelFailed' => 'card_rewriter_studio_outcome_card_model_failed'.tr(
        namedArgs: {'error': outcome.detail ?? 'unknown'},
      ),
      'lorebookModelFailed' =>
        'card_rewriter_studio_outcome_lorebook_model_failed'.tr(
          namedArgs: {'error': outcome.detail ?? 'unknown'},
        ),
      'invalidCardOutput' => 'card_rewriter_studio_outcome_invalid_card'.tr(
        namedArgs: {'error': outcome.detail ?? 'unknown'},
      ),
      'invalidOperation' => 'card_rewriter_studio_outcome_invalid_operation'.tr(
        namedArgs: {'error': outcome.detail ?? 'unknown'},
      ),
      'invalidLorebookOperation' =>
        'card_rewriter_studio_outcome_invalid_lorebook_operation'.tr(),
      'invalidLorebookOutput' =>
        'card_rewriter_studio_outcome_invalid_lorebook_output'.tr(),
      'emptyModelProposal' =>
        'card_rewriter_studio_outcome_empty_proposal'.tr(),
      'snapshotUnavailable' ||
      'stale' ||
      'staleEvidence' => 'card_rewriter_studio_outcome_stale'.tr(),
      'snapshotTooLarge' =>
        outcome.detail ?? 'card_rewriter_studio_outcome_too_large'.tr(),
      'disabled' => 'card_rewriter_studio_outcome_disabled'.tr(),
      'cancelled' => 'card_rewriter_studio_outcome_cancelled'.tr(),
      'writerCallNotFound' => 'card_rewriter_studio_outcome_call_not_found'.tr(),
      'writerCallNotFailed' ||
      'writerNotFailed' => 'card_rewriter_studio_outcome_not_failed'.tr(),
      'writerCallNotFrontier' =>
        'card_rewriter_studio_outcome_not_frontier'.tr(),
      'writerCallRetryFailed' ||
      'leaseLost' => 'card_rewriter_studio_outcome_lease_lost'.tr(),
      'claimMissing' => 'card_rewriter_studio_outcome_claim_missing'.tr(),
      _ => 'card_rewriter_studio_outcome_skipped'.tr(
        namedArgs: {'kind': outcome.kind},
      ),
    };

/// A review job's state.
String cardRewriterJobStatusLabel(String status) => switch (status) {
  'pending' => 'card_rewriter_studio_status_review'.tr(),
  'applied' => 'card_rewriter_studio_status_applied'.tr(),
  'failed' => 'card_rewriter_studio_status_failed'.tr(),
  'cancelled' => 'card_rewriter_studio_status_cancelled'.tr(),
  _ => 'card_rewriter_studio_status_generating'.tr(),
};

/// One request in a writer chain.
String cardRewriterStageLabel(String stage) => switch (stage) {
  'history_consolidation' =>
    'card_rewriter_studio_stage_history_consolidation'.tr(),
  'card_writer' => 'card_rewriter_studio_stage_card_writer'.tr(),
  'card_repair' => 'card_rewriter_studio_stage_card_repair'.tr(),
  'lorebook_writer' => 'card_rewriter_studio_stage_lorebook_writer'.tr(),
  _ => stage,
};

String cardRewriterCallStatusLabel(String status) => switch (status) {
  'completed' => 'card_rewriter_studio_status_completed'.tr(),
  'failed' => 'card_rewriter_studio_status_failed'.tr(),
  // Recovery chains only render failed claims, so a prepared call is always
  // a checkpoint of an interrupted attempt — never an in-flight request.
  'prepared' => 'card_rewriter_studio_status_prepared'.tr(),
  _ => 'card_rewriter_studio_status_pending'.tr(),
};

/// A diagnostics row's stage. Older rows stored `card` / `lorebook` where the
/// chain now stores `card_writer` / `lorebook_writer`.
String cardRewriterDebugStageLabel(String stage) => switch (stage) {
  'card' || 'card_writer' => 'card_rewriter_studio_stage_card_writer'.tr(),
  'card_repair' => 'card_rewriter_studio_stage_card_repair'.tr(),
  'history_consolidation' =>
    'card_rewriter_studio_stage_history_consolidation'.tr(),
  'lorebook' ||
  'lorebook_writer' => 'card_rewriter_studio_stage_lorebook_writer'.tr(),
  _ => stage,
};

String cardRewriterDebugStatusLabel(String status) => switch (status) {
  'ok' || 'completed' => 'card_rewriter_studio_status_completed'.tr(),
  'failed' || 'error' => 'card_rewriter_studio_status_failed'.tr(),
  _ => status,
};
