import 'card_rewriter_settings.dart';
import 'cleaner_settings.dart';
import 'ledger_settings.dart';
import 'pipeline_settings.dart';
import 'studio_config.dart';

/// Folds a Studio preset's per-preset lane settings over the global
/// [PipelineSettings].
///
/// Post Clean, Studio Ledger and Card Rewriter are configured per preset
/// ([StudioRuntimeSettings.cleaner] / `.ledger` / `.cardRewriter`). A lane the
/// preset has never configured is null and keeps the global value, so an
/// install that predates per-preset settings behaves exactly as before until
/// someone edits a lane.
///
/// Every runtime consumer reads the folded result — `StudioTurnConfigSnapshot`
/// for the generation turn, `effectiveCardRewriterSettings` for the Card
/// Rewriter lane — so a stage can never run on one source while the UI edits
/// the other.
PipelineSettings applyStudioPresetOverrides(
  PipelineSettings globals,
  StudioPreset? preset,
) {
  final runtime = preset?.runtime;
  if (runtime == null) return globals;
  final cleaner = runtime.cleaner;
  final ledger = runtime.ledger;
  final cardRewriter = runtime.cardRewriter;
  if (cleaner == null && ledger == null && cardRewriter == null) {
    return globals;
  }
  return globals.copyWith(
    cleaner: cleaner ?? globals.cleaner,
    ledger: ledger ?? globals.ledger,
    cardRewriter: cardRewriter ?? globals.cardRewriter,
  );
}

/// The Post Clean settings [preset] actually runs on.
CleanerSettings effectiveCleanerSettings(
  PipelineSettings globals,
  StudioPreset? preset,
) => preset?.runtime.cleaner ?? globals.cleaner;

/// The Studio Ledger settings [preset] actually runs on.
LedgerSettings effectiveLedgerSettings(
  PipelineSettings globals,
  StudioPreset? preset,
) => preset?.runtime.ledger ?? globals.ledger;

/// The Card Rewriter settings [preset] actually runs on.
CardRewriterSettings effectiveCardRewriterSettings(
  PipelineSettings globals,
  StudioPreset? preset,
) => preset?.runtime.cardRewriter ?? globals.cardRewriter;
