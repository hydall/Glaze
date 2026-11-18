import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/transport/endpoint_normalizer.dart';
import '../utils/platform_paths.dart';
import '../utils/time_helpers.dart';
import 'tables.dart';

part 'app_db.g.dart';
part 'migrations/database_integrity.dart';
part 'migrations/memory_legacy.dart';
part 'migrations/upgrade_v2_v50.dart';
part 'migrations/upgrade_v51_v100.dart';
part 'migrations/upgrade_v101_v131.dart';
part 'migrations/upgrade_v132.dart';
part 'migrations/upgrade_v133.dart';
part 'migrations/upgrade_v134.dart';
part 'migrations/upgrade_v135.dart';
part 'migrations/upgrade_v136.dart';
part 'migrations/upgrade_v137.dart';
part 'migrations/upgrade_v138.dart';
part 'migrations/upgrade_v139.dart';
part 'migrations/upgrade_v142.dart';
part 'migrations/upgrade_v143.dart';
part 'migrations/upgrade_v144.dart';
part 'migrations/upgrade_v145.dart';
part 'migrations/upgrade_v146.dart';
part 'migrations/upgrade_v147.dart';
part 'migrations/upgrade_v148.dart';

@DriftDatabase(
  tables: [
    Characters,
    CharacterFolders,
    CharacterFolderMembers,
    Folders,
    FolderMembers,
    ChatSessions,
    Presets,
    PresetFolders,
    PresetFolderMembers,
    ApiConfigs,
    Personas,
    Lorebooks,
    SessionLorebookEvolutionRows,
    SessionCanonCheckpointRows,
    SessionLorebookRevisionRows,
    SessionLorebookEmbeddingJobRows,
    LorebookUseManifests,
    LorebookUseManifestEntries,
    LorebookUseAcceptanceRecords,
    Embeddings,
    ChatSummaries,
    MemoryBookRows,
    MemoryCatalogRows,
    MemoryEntityRows,
    MemorySalienceRows,
    MemoryCadenceRows,
    MemoryConsolidationRows,
    TrackerRows,
    TrackerSnapshots,
    LedgerReconciliationCheckpoints,
    LedgerReconciliationCleanupJournals,
    LedgerReconciliationSuccessfulRuns,
    LedgerReconciliationEffects,
    LedgerReconciliationRunInvalidations,
    LedgerReconciliationCursors,
    LedgerReconciliationLeases,
    LedgerDebugRuns,
    LlmRequestCaptureRows,
    LlmCallEventRows,
    CardEvolutionClaims,
    CardEvolutionWriterCalls,
    CardEvolutionProposalRuns,
    CardEvolutionDebugRuns,
    CardEvolutionObservations,
    CardEvolutionCollectorRuns,
    CharacterKnowledgeFactRows,
    CharacterSessionBaselineRows,
    CharacterRevisionRows,
    AppliedCanonTransitionRows,
    RewriteJobs,
    RewriteOperations,
    RewriteOperationRevisions,
    RewriteEvidenceRows,
    CanonTransitionFactRefs,
    ExtensionPresets,
    InfoBlocks,
    AgentDefinitionRows,
    AgentBindingRows,
    AgentRunRows,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 148;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
      await _ensureSchemaIntegrity();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      await _upgradeV2ToV50(m, from);
      await _upgradeV51ToV100(m, from);
      await _upgradeV101ToV131(m, from);
      await _upgradeV132(from);
      await _upgradeV133(m, from);
      await _upgradeV134(m, from);
      await _upgradeV135(m, from);
      await _upgradeV136(m, from);
      await _upgradeV137(m, from);
      await _upgradeV138(m, from);
      await _upgradeV139(m, from);
      await _upgradeV142(m, from);
      await _upgradeV143(m, from);
      await _upgradeV144(m, from);
      await _upgradeV145(m, from);
      await _upgradeV146(m, from);
      await _upgradeV147(m, from);
      await _upgradeV148(m, from);
      // v140 and v141 have no step of their own: they bring databases already
      // at the previous version through this pass. v140 restores the indexes
      // and triggers their earlier upgrades missed; v141 replaces the request
      // capture trigger with one that lets a turn be bound to its message.
      await _ensureSchemaIntegrity();
    },
  );

  Future<void> purgeRetiredAgenticMicroMemory() =>
      _AppDatabaseMemoryLegacyMigrations(this).purgeRetiredAgenticMicroMemory();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getAppDataDir();
    final dir = Directory(dbFolder);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(p.join(dbFolder, 'glaze.db'));
    return NativeDatabase.createInBackground(file);
  });
}
