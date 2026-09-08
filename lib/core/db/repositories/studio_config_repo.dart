import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/studio_config.dart';
import '../../llm/studio_controller_ontology.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';
import '../../application/sync_repo_interfaces.dart';

class StudioConfigRepo implements SyncStudioConfigStore {
  final AppDatabase db;

  const StudioConfigRepo(this.db);

  Future<StudioConfig?> getBySessionId(String sessionId) async {
    final row = await (db.select(
      db.studioConfigRows,
    )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
    if (row == null) {
      // No session-specific config — fall back to the first global profile
      // so new sessions inherit Studio settings without a dialog prompt.
      final profiles = await getProfiles();
      if (profiles.isEmpty) return null;
      final profile = profiles.first;
      // Bind the session to the profile so future lookups are direct.
      await _upsertRow(
        profile.copyWith(
          sessionId: sessionId,
          profileId: profile.profileId,
          enabled: profile.enabled,
        ),
      );
      return profile.copyWith(sessionId: sessionId);
    }
    final binding = _rowToModel(row);
    final profileId = binding.profileId;
    if (profileId.isEmpty || profileId == binding.sessionId) {
      return binding;
    }
    final profile = await getByProfileId(profileId);
    return profile?.copyWith(
          sessionId: binding.sessionId,
          enabled: binding.enabled,
          profileId: profile.profileId.isNotEmpty
              ? profile.profileId
              : profileId,
        ) ??
        binding;
  }

  Future<StudioConfig?> getByProfileId(String profileId) async {
    final row =
        await (db.select(db.studioConfigRows)..where(
              (t) =>
                  t.profileId.equals(profileId) & t.sessionId.equals(profileId),
            ))
            .getSingleOrNull();
    if (row != null) return _rowToModel(row);
    final fallback = await (db.select(
      db.studioConfigRows,
    )..where((t) => t.profileId.equals(profileId))).getSingleOrNull();
    return fallback == null ? null : _rowToModel(fallback);
  }

  /// True if any Studio config row (session binding or profile) has ever been
  /// enabled. Used to migrate pre-existing Studio users onto the global
  /// Experimental Features master switch without losing their setup.
  Future<bool> hasAnyEnabledConfig() async {
    final row =
        await (db.select(db.studioConfigRows)
              ..where((t) => t.enabled.equals(true))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  Future<List<StudioConfig>> getProfiles() async {
    final rows = await db.select(db.studioConfigRows).get();
    final byProfile = <String, StudioConfig>{};
    for (final row in rows) {
      final config = _rowToModel(row);
      final id = config.profileId.isNotEmpty
          ? config.profileId
          : config.sessionId;
      final existing = byProfile[id];
      if (existing == null || config.sessionId == id) {
        byProfile[id] = config.copyWith(profileId: id);
      }
    }
    final profiles = byProfile.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return profiles;
  }

  @override
  Future<List<StudioConfig>> getAll() => getProfiles();

  @override
  Future<StudioConfig?> getById(String id) => getByProfileId(id);

  @override
  Future<void> put(StudioConfig config) => upsert(config);

  @override
  Future<void> delete(String id) async {
    await (db.delete(
      db.studioConfigRows,
    )..where((t) => t.profileId.equals(id))).go();
  }

  Future<void> bindSessionToProfile({
    required String sessionId,
    required String profileId,
    bool enabled = true,
  }) async {
    final profile = await getByProfileId(profileId);
    if (profile == null) return;
    await upsert(
      profile.copyWith(
        sessionId: sessionId,
        profileId: profileId,
        enabled: enabled,
        createdAt: currentTimestampSeconds(),
        updatedAt: currentTimestampSeconds(),
      ),
    );
  }

  Future<void> upsert(StudioConfig config) async {
    await _upsertRow(config);
    final profileId = config.profileId.isNotEmpty
        ? config.profileId
        : config.sessionId;
    if (profileId != config.sessionId) {
      await _upsertRow(
        config.copyWith(sessionId: profileId, profileId: profileId),
      );
    }
  }

  Future<void> _upsertRow(StudioConfig config) {
    return db
        .into(db.studioConfigRows)
        .insertOnConflictUpdate(
          StudioConfigRowsCompanion.insert(
            sessionId: config.sessionId,
            profileId: Value(
              config.profileId.isNotEmpty ? config.profileId : config.sessionId,
            ),
            profileName: Value(config.profileName),
            enabled: Value(config.enabled),
            agentsJson: Value(
              jsonEncode(config.agents.map((a) => a.toJson()).toList()),
            ),
            finalPresetId: Value(config.finalPresetId),
            runApiConfigId: Value(config.runApiConfigId),
            expensiveApiConfigId: Value(config.expensiveApiConfigId),
            cheapApiConfigId: Value(config.cheapApiConfigId),
            cleanerApiConfigId: Value(config.cleanerApiConfigId),
            runModelOverride: Value(config.runModelOverride),
            maxFinalHistoryMessages: Value(config.maxFinalHistoryMessages),
            broadcastBlocksJson: Value(jsonEncode(config.broadcastBlocks)),
            createdAt: Value(config.createdAt),
            updatedAt: Value(currentTimestampSeconds()),
          ),
        );
  }

  Future<void> deleteBySessionId(String sessionId) {
    return (db.delete(
      db.studioConfigRows,
    )..where((t) => t.sessionId.equals(sessionId))).go();
  }

  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
  }) async {
    final source = await getBySessionId(fromSessionId);
    if (source == null) return;
    // A branch needs only its session binding. Do not route through upsert(),
    // which would also rewrite the shared profile row and its updatedAt.
    await _upsertRow(
      source.copyWith(
        sessionId: toSessionId,
        profileId: source.profileId.isNotEmpty
            ? source.profileId
            : source.sessionId,
        createdAt: currentTimestampSeconds(),
        updatedAt: currentTimestampSeconds(),
      ),
    );
  }

  StudioConfig _rowToModel(StudioConfigRow row) {
    List<StudioAgent> agents;
    try {
      final list = jsonDecode(row.agentsJson) as List<dynamic>;
      agents = list
          .map((e) => StudioAgent.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      agents = [];
    }
    List<String> broadcastBlocks;
    try {
      broadcastBlocks = (jsonDecode(row.broadcastBlocksJson) as List<dynamic>)
          .whereType<String>()
          .toList(growable: false);
    } catch (_) {
      broadcastBlocks = const [];
    }

    return _normalizeLoadedConfig(
      StudioConfig(
        sessionId: row.sessionId,
        profileId: row.profileId.isNotEmpty ? row.profileId : row.sessionId,
        profileName: row.profileName,
        enabled: row.enabled,
        agents: agents,
        finalPresetId: row.finalPresetId,
        runApiConfigId: row.runApiConfigId,
        expensiveApiConfigId: row.expensiveApiConfigId,
        cheapApiConfigId: row.cheapApiConfigId,
        cleanerApiConfigId: row.cleanerApiConfigId,
        runModelOverride: row.runModelOverride,
        maxFinalHistoryMessages: row.maxFinalHistoryMessages,
        broadcastBlocks: broadcastBlocks,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      ),
    );
  }

  /// Silent migration of loaded Studio configs:
  ///
  /// 1. Meta-Weaver (plan §Part 6): upgrade from the old `'static'` refresh
  ///    policy to the meta-weaver architecture — `refreshPolicy: 'turn'`
  ///    (runs every turn so it can apply the period rule). Keep the user's
  ///    existing `contextSize`: in batched Studio runs the largest tracker
  ///    context becomes the shared history window for the whole group, so a
  ///    high Meta-Weaver default would inflate every tracker request.
  ///
  /// 2. All trackers run every turn (Marinara parity, see
  ///    `studio_controller_ontology.dart`): any agent still carrying
  ///    `refreshPolicy: 'scene'` or `'static'` from a pre-parity build is
  ///    migrated to `'turn'`. The `'scene'` policy's gate was a regex over
  ///    the last user message only — it missed real scene changes that
  ///    weren't phrased with time-skip words, and stale scene-cached briefs
  ///    degraded the final response. Running every turn is cheaper to reason
  ///    about and matches upstream Marinara-Engine's `runInterval: 1`
  ///    default for all tracker agents.
  ///
  /// Returns [config] unchanged when no agent needs migration. This is a
  /// normalization in memory, so existing configs benefit immediately without
  /// a rebuild.
  StudioConfig _normalizeLoadedConfig(StudioConfig config) {
    if (config.enabled && config.agents.isEmpty) {
      final now = config.updatedAt != 0
          ? config.updatedAt
          : currentTimestampSeconds();
      return config.copyWith(
        agents: StudioControllerOntology.buildDefaultAgents(
          sessionId: config.sessionId,
          now: now,
        ),
        createdAt: config.createdAt == 0 ? now : config.createdAt,
        updatedAt: config.updatedAt == 0 ? now : config.updatedAt,
      );
    }
    if (config.agents.isEmpty) return config;
    final migrated = <StudioAgent>[];
    var changed = false;
    for (final agent in config.agents) {
      var current = agent;
      if (_isMetaWeaver(current) && current.refreshPolicy != 'turn') {
        current = current.copyWith(refreshPolicy: 'turn');
        changed = true;
      }
      if (current.refreshPolicy != 'turn') {
        current = current.copyWith(refreshPolicy: 'turn');
        changed = true;
      }
      // Migrate old pre-gen tracker defaults down to the focused 5-message
      // window. Post-processing trackers get 2 (last turn + response to edit).
      if (current.phase == 'post_processing') {
        if (current.contextSize != 2) {
          current = current.copyWith(contextSize: 2);
          changed = true;
        }
      } else if (!_isFinalResponder(current) && current.contextSize == 20) {
        current = current.copyWith(contextSize: 5);
        changed = true;
      }
      migrated.add(current);
    }
    final withBeauty = _ensureBeautyShardAgent(config, migrated);
    if (!identical(withBeauty, migrated)) changed = true;
    return changed ? config.copyWith(agents: withBeauty) : config;
  }

  List<StudioAgent> _ensureBeautyShardAgent(
    StudioConfig config,
    List<StudioAgent> agents,
  ) {
    if (agents.any(_isBeautyShard)) return agents;
    final spec = StudioControllerOntology.specs.firstWhere(
      (s) => s.id == 'beauty',
      orElse: () => throw StateError('Beauty Shard spec missing'),
    );
    final finalIdx = agents.indexWhere(_isFinalResponder);
    final insertAt = finalIdx >= 0 ? finalIdx : agents.length;
    final beauty = StudioAgent(
      id: 'agent_${config.sessionId}_beauty_migrated',
      name: spec.name,
      role: 'system',
      order: insertAt,
      enabled: true,
      temperature: spec.temperature,
      maxTokens: spec.maxTokens,
      timeoutMs: spec.timeoutMs,
      sourceBlockNames:
          'Beauty Shard fallback (rebuild Studio to route preset style blocks)',
      refreshPolicy: spec.refreshPolicy,
      invalidationSignals: spec.invalidationSignals,
      phase: spec.phase,
      contextSize: spec.contextSize > 0 ? spec.contextSize : 5,
    );
    final updated = <StudioAgent>[
      ...agents.take(insertAt),
      beauty,
      ...agents.skip(insertAt),
    ];
    return [
      for (var i = 0; i < updated.length; i++) updated[i].copyWith(order: i),
    ];
  }

  bool _isBeautyShard(StudioAgent agent) {
    final id = agent.id.toLowerCase();
    final name = agent.name.toLowerCase();
    final text = '$id\n$name';
    return id == 'beauty' ||
        text.contains('_beauty_') ||
        text.contains('beauty shard') ||
        name == 'beauty';
  }

  bool _isFinalResponder(StudioAgent agent) {
    final id = agent.id.toLowerCase();
    final name = agent.name.toLowerCase();
    final text = '$id\n$name';
    return id == 'final' ||
        text.contains('_final_') ||
        text.contains('main responder') ||
        name == 'final';
  }

  /// True if [agent] is the Meta-Weaver / OOC Policy controller. Matches by
  /// id/name (the controller spec id is `meta`, name is
  /// `Meta-Weaver / OOC Policy`). Falls back to substring contains so older
  /// configs with slightly different names still migrate.
  bool _isMetaWeaver(StudioAgent agent) {
    final id = agent.id.toLowerCase();
    final name = agent.name.toLowerCase();
    return id.contains('_meta_') ||
        id == 'meta' ||
        name.contains('meta-weaver') ||
        name.contains('meta weaver') ||
        name.contains('ooc policy') ||
        name.contains('lumia policy');
  }
}
