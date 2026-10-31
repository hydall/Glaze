part of '../app_db.dart';

extension _AppDatabaseUpgradeV146 on AppDatabase {
  Future<void> _upgradeV146(Migrator m, int from) async {
    if (from >= 146) return;

    // The two stepped-trim knobs changed what they are a share of. They were
    // shares of the history budget — the context left once the preset, the
    // character, the lorebooks and memory had taken theirs, which moves with
    // every turn's lorebook activation — and are now shares of the whole
    // context window, as the prompt inspector shows it. A number chosen under
    // the old meaning says something else under the new one, so every row
    // goes back to the defaults (kDefaultHistoryTrimTriggerPercent /
    // kDefaultHistoryTrimStepPercent in lib/core/llm/history_trim.dart).
    //
    // The columns exist by now: v135 adds them on the way up, and a database
    // restored from a backup carries them already.
    await customStatement(
      'UPDATE api_configs '
      'SET history_trim_trigger_percent = 85, history_trim_step_percent = 30',
    );
  }
}
