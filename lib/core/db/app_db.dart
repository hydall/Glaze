import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/studio_preset_block_migration.dart';
import '../models/studio_preset_codec.dart';
import '../models/studio_agent_codec.dart';
import '../models/studio_config.dart';
import '../llm/studio_controller_ontology.dart';
import '../llm/transport/endpoint_normalizer.dart';
import '../utils/platform_paths.dart';
import '../utils/time_helpers.dart';
import 'tables.dart';

part 'app_db.g.dart';
part 'migrations/database_integrity.dart';
part 'migrations/studio_legacy.dart';
part 'studio_preset_seed.dart';
part 'migrations/upgrade_v2_v50.dart';
part 'migrations/upgrade_v51_v100.dart';
part 'migrations/upgrade_v101_v131.dart';
part 'migrations/upgrade_v132.dart';
part 'migrations/upgrade_v133.dart';
part 'migrations/upgrade_v134.dart';
part 'migrations/upgrade_v135.dart';

@DriftDatabase(
  tables: [
    Characters,
    CharacterFolders,
    CharacterFolderMembers,
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
    StudioConfigRows,
    StudioPresetRows,
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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 135;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
      final now = currentTimestampSeconds();
      await customStatement(
        'INSERT INTO studio_preset_rows '
        '(preset_id, name, blocks_json, agents_json, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          'default',
          'Default Studio Preset',
          jsonEncode(_legacyStudioPresetMigrationBlocks()),
          StudioAgentCodec.encodeAgents(
            StudioControllerOntology.buildDefaultAgents(
              sessionId: 'default',
              now: now,
            ),
          ),
          now,
        ],
      );
      await _createLorebookUseManifestImmutabilityTriggers();
      await _createLorebookUseManifestIntegrityTriggers();
      await _createLedgerReconciliationImmutabilityTriggers();
      await _createCardEvolutionIntegrity();
      await _createRewriteAuditIntegrity();
      await _createSessionCanonIntegrity();
      await _createLlmCallEventImmutabilityTrigger();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      await _upgradeV2ToV50(m, from);
      await _upgradeV51ToV100(m, from);
      await _upgradeV101ToV131(m, from);
      await _upgradeV132(from);
      await _upgradeV133(m, from);
      await _upgradeV134(m, from);
      await _upgradeV135(m, from);
    },
  );

  Future<void> applyLegacyStudioRuntimePayloads(
    List<Map<String, dynamic>> rows,
  ) => _AppDatabaseStudioLegacyMigrations(
    this,
  ).applyLegacyStudioRuntimePayloads(rows);

  Future<void> purgeRetiredAgenticMicroMemory() =>
      _AppDatabaseStudioLegacyMigrations(this).purgeRetiredAgenticMicroMemory();
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
