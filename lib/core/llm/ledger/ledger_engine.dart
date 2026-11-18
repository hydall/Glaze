/// Which extraction path the Tracker (Ledger) runs. Runtime extraction always
/// uses [currentReconciled]; [legacyTurnOnly] keeps the old turn-only prompt
/// reachable for diagnostics.
enum LedgerEngine { currentReconciled, legacyTurnOnly }
