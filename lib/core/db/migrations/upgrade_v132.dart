part of '../app_db.dart';

extension _AppDatabaseUpgradeV132 on AppDatabase {
  Future<void> _upgradeV132(int from) async {
    if (from >= 132) return;

    // Collector journals are derived from cadence-specific reconciliation
    // batches. Pair-based rows cannot prove the new three-run boundaries.
    await transaction(() async {
      await customStatement(
        'DELETE FROM card_evolution_writer_calls WHERE claim_id IN '
        "(SELECT id FROM card_evolution_claims WHERE status <> 'completed')",
      );
      await customStatement(
        "DELETE FROM card_evolution_claims WHERE status <> 'completed'",
      );
      await customStatement('DELETE FROM card_evolution_collector_runs');
      await customStatement('DELETE FROM card_evolution_observations');
    });
  }
}
