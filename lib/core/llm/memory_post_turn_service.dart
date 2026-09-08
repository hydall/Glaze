import 'dart:async';

import 'memory_cadence_service.dart';

/// Post-turn memory pipeline (Phase G4).
///
/// **DISABLED** — the heuristic entity graph + salience scorer produce
/// garbage on non-English text (Russian RP). The `MemoryEntityExtractor`
/// relies on `[A-Z][a-z]` proper-noun detection which doesn't work for
/// Cyrillic, and the stoplist / preposition guards are insufficient.
///
/// Studio Ledger (LLM-based entity tracking in `tracker_rows`) covers the
/// same use case with much higher quality — it writes `npc:Name.field`,
/// `world:location`, `scene.present_entities`, etc.
///
/// The graph/salience/cadence tables remain in the DB for forward compat,
/// but no new rows are written until the extractor is rewritten.
///
/// Reference for a future LLM-based rewrite (Tier 2 sidecar approach):
/// https://github.com/prolix-oc/Lumiverse/blob/main/src/services/memory-cortex/
/// — Lumiverse uses heuristic Tier 1 + LLM sidecar Tier 2 with arbitration.
class MemoryPostTurnService {
  final MemoryCadenceService _cadenceService;

  MemoryPostTurnService(this._cadenceService);

  /// Run post-turn memory work. Fire-and-forget; caller should not await.
  ///
  /// **Currently a no-op** — entity graph + salience disabled. See class
  /// doc for rationale. Only the cadence counter is incremented so the
  /// table stays consistent when the feature is re-enabled.
  Future<void> runPostTurn(String sessionId) async {
    try {
      await _cadenceService.incrementAssistant(sessionId);
      // Entity graph + salience rebuild disabled — see class doc.
      // To re-enable, rewrite MemoryEntityExtractor for non-English text
      // (LLM-based extraction or Cyrillic-aware heuristics) and restore
      // the full body from git history.
    } catch (_) {
      // Post-turn failures are non-fatal; do not surface to user
    }
  }
}
