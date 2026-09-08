import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'sync_serialization.dart';
import '../sync_models.dart';
import '../sync_repo_interfaces.dart';

class SyncManifestBuilder implements SyncManifestProvider {
  final SyncCharacterStore _characterRepo;
  final SyncChatStore _chatRepo;
  final SyncPersonaStore _personaRepo;
  final SyncPresetStore _presetRepo;
  final SyncApiConfigStore _apiRepo;
  final SyncMemoryBookStore _memoryBookRepo;
  final SyncLorebookStore _lorebookRepo;
  final SyncThemePresetStore _themePresetRepo;
  final SyncExtensionPresetStore _extensionPresetRepo;
  final SyncExtensionsSettingsStore _extensionsSettingsStore;
  final SyncInfoBlockStore _infoBlockStore;
  final SyncTrackerSnapshotStore _trackerSnapshotStore;
  final SyncTrackerValueStore _trackerValueStore;
  final SyncStudioConfigStore _studioConfigStore;
  final SyncStudioPresetStore? _studioPresetStore;
  final SyncChatSummaryStore? _chatSummaryStore;
  final SyncCharacterFolderStore? _characterFolderStore;
  final SyncMemoryGraphStore? _memoryGraphStore;
  final SyncCharacterKnowledgeStore? _characterKnowledgeStore;
  final SyncImageStore? _imageStore;

  static const _manifestKey = 'gz_sync_manifest_v2';
  static const _deviceIdKey = 'gz_sync_device_id';
  static const _deletedKey = 'gz_sync_deleted_entries';

  SyncManifestBuilder({
    required this._characterRepo,
    required this._chatRepo,
    required this._personaRepo,
    required this._presetRepo,
    required this._apiRepo,
    required this._memoryBookRepo,
    required this._lorebookRepo,
    required this._themePresetRepo,
    required this._extensionPresetRepo,
    required this._extensionsSettingsStore,
    required this._infoBlockStore,
    required this._trackerSnapshotStore,
    required this._trackerValueStore,
    required this._studioConfigStore,
    this._studioPresetStore,
    this._chatSummaryStore,
    this._characterFolderStore,
    this._memoryGraphStore,
    this._characterKnowledgeStore,
    this._imageStore,
  });

  @override
  Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id =
          '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999999)}';
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  /// [cloudManifest] — when pulling, used to avoid bumping updatedAt to now for
  /// entities that only differ from a stale local manifest but match cloud.
  @override
  Future<SyncManifest> buildLocalManifest({SyncManifest? cloudManifest}) async {
    final deviceId = await getDeviceId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final entries = <String, SyncManifestEntry>{};

    final previous = await readLocalManifest();

    final characters = await _characterRepo.getAll();
    for (final c in characters) {
      final json = c.toJson();
      final hash = SyncSerialization.computeSyncHash(_normalizeForHash(json));
      final key = entryKey('character', c.id);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      var updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );
      if (c.updatedAt > updatedAt) updatedAt = c.updatedAt;

      entries[key] = SyncManifestEntry(
        type: 'character',
        id: c.id,
        path: cloudPath('character', c.id),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final personas = await _personaRepo.getAll();
    for (final p in personas) {
      final json = p.toJson();
      final hash = SyncSerialization.computeSyncHash(_normalizeForHash(json));
      final key = entryKey('persona', p.id);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: 'persona',
        id: p.id,
        path: cloudPath('persona', p.id),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final extensionPresets = await _extensionPresetRepo.getAll();
    for (final ep in extensionPresets) {
      final json = ep.toJson();
      final hash = SyncSerialization.computeSyncHash(json);
      final key = entryKey('extension_preset', ep.id);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: 'extension_preset',
        id: ep.id,
        path: cloudPath('extension_preset', ep.id),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final sessions = await _chatRepo.getAllSessionMetadata();
    for (final s in sessions) {
      final hash = SyncSerialization.computeChatMetadataHash(s);
      final key = entryKey('chat', s.sessionId);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      var updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );
      if (s.updatedAt > updatedAt) updatedAt = s.updatedAt;

      entries[key] = SyncManifestEntry(
        type: 'chat',
        id: s.sessionId,
        path: cloudPath('chat', s.sessionId),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final memoryBooks = await _memoryBookRepo.getAll();
    for (final mb in memoryBooks) {
      final json = mb.toJson();
      final hash = SyncSerialization.computeMemoryBookHash(json);
      final key = entryKey('memory_book', mb.sessionId);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      var updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );
      if (mb.updatedAt > updatedAt) updatedAt = mb.updatedAt;

      entries[key] = SyncManifestEntry(
        type: 'memory_book',
        id: mb.sessionId,
        path: cloudPath('memory_book', mb.sessionId),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final infoBlockSessionIds = await _infoBlockStore.getAllSessionIds();
    for (final sessionId in infoBlockSessionIds) {
      final blocks = await _infoBlockStore.getBySessionId(sessionId);
      if (blocks.isEmpty) continue;
      final hash = SyncSerialization.computeSyncHash(
        SyncSerialization.infoBlocksPayload(blocks),
      );
      final key = entryKey('info_block', sessionId);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: 'info_block',
        id: sessionId,
        path: cloudPath('info_block', sessionId),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final trackerSnapshotSessionIds = await _trackerSnapshotStore
        .getAllSessionIds();
    for (final sessionId in trackerSnapshotSessionIds) {
      final snapshots = await _trackerSnapshotStore.getBySessionId(sessionId);
      if (snapshots.isEmpty) continue;
      final payload = {'__trackerSnapshots': true, 'items': snapshots};
      final hash = SyncSerialization.computeSyncHash(payload);
      final key = entryKey('tracker_snapshot', sessionId);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: 'tracker_snapshot',
        id: sessionId,
        path: cloudPath('tracker_snapshot', sessionId),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final trackerValueSessionIds = await _trackerValueStore.getAllSessionIds();
    for (final sessionId in trackerValueSessionIds) {
      final trackers = await _trackerValueStore.getBySessionId(sessionId);
      if (trackers.isEmpty) continue;
      final payload = {'__trackerValues': true, 'items': trackers};
      final hash = SyncSerialization.computeSyncHash(payload);
      final key = entryKey('tracker_value', sessionId);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: 'tracker_value',
        id: sessionId,
        path: cloudPath('tracker_value', sessionId),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final studioConfigs = await _studioConfigStore.getAll();
    for (final config in studioConfigs) {
      final id = config.profileId.isNotEmpty
          ? config.profileId
          : config.sessionId;
      final json = config.toJson();
      final hash = SyncSerialization.computeSyncHash(json);
      final key = entryKey('studio_config', id);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      var updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );
      if (config.updatedAt > updatedAt) updatedAt = config.updatedAt;

      entries[key] = SyncManifestEntry(
        type: 'studio_config',
        id: id,
        path: cloudPath('studio_config', id),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    if (_studioPresetStore != null) {
      final studioPresets = await _studioPresetStore.getAll();
      for (final preset in studioPresets) {
        final json = preset.toJson();
        final hash = SyncSerialization.computeSyncHash(json);
        final key = entryKey('studio_preset', preset.id);
        final prevEntry = previous.entries[key];
        final cloudEntry = cloudManifest?.entries[key];
        var updatedAt = _resolveUpdatedAt(
          hash: hash,
          prevEntry: prevEntry,
          cloudEntry: cloudEntry,
          now: now,
        );
        if (preset.updatedAt > updatedAt) updatedAt = preset.updatedAt;

        entries[key] = SyncManifestEntry(
          type: 'studio_preset',
          id: preset.id,
          path: cloudPath('studio_preset', preset.id),
          updatedAt: updatedAt,
          hash: hash,
        );
      }
    }

    // Chat summaries — per-session, like tracker_value.
    if (_chatSummaryStore != null) {
      final summarySessionIds = await _chatSummaryStore.getAllSessionIds();
      for (final sessionId in summarySessionIds) {
        final summary = await _chatSummaryStore.getBySessionId(sessionId);
        if (summary == null) continue;
        final hash = SyncSerialization.computeSyncHash(summary);
        final key = entryKey('chat_summary', sessionId);
        final prevEntry = previous.entries[key];
        final cloudEntry = cloudManifest?.entries[key];
        final updatedAt = _resolveUpdatedAt(
          hash: hash,
          prevEntry: prevEntry,
          cloudEntry: cloudEntry,
          now: now,
        );

        entries[key] = SyncManifestEntry(
          type: 'chat_summary',
          id: sessionId,
          path: cloudPath('chat_summary', sessionId),
          updatedAt: updatedAt,
          hash: hash,
        );
      }
    }

    // Memory graph — per-session, packs 5 tables into one JSON.
    if (_memoryGraphStore != null) {
      final graphSessionIds = await _memoryGraphStore.getAllSessionIds();
      for (final sessionId in graphSessionIds) {
        final graph = await _memoryGraphStore.getBySessionId(sessionId);
        if (graph == null) continue;
        final hash = SyncSerialization.computeSyncHash(graph);
        final key = entryKey('memory_graph', sessionId);
        final prevEntry = previous.entries[key];
        final cloudEntry = cloudManifest?.entries[key];
        final updatedAt = _resolveUpdatedAt(
          hash: hash,
          prevEntry: prevEntry,
          cloudEntry: cloudEntry,
          now: now,
        );

        entries[key] = SyncManifestEntry(
          type: 'memory_graph',
          id: sessionId,
          path: cloudPath('memory_graph', sessionId),
          updatedAt: updatedAt,
          hash: hash,
        );
      }
    }

    if (_characterKnowledgeStore != null) {
      final sessionIds = await _characterKnowledgeStore.getAllSessionIds();
      for (final sessionId in sessionIds) {
        final knowledge = await _characterKnowledgeStore.getBySessionId(
          sessionId,
        );
        if (knowledge == null) continue;
        final hash = SyncSerialization.computeSyncHash(knowledge);
        final key = entryKey('character_knowledge', sessionId);
        final prevEntry = previous.entries[key];
        final cloudEntry = cloudManifest?.entries[key];
        final updatedAt = _resolveUpdatedAt(
          hash: hash,
          prevEntry: prevEntry,
          cloudEntry: cloudEntry,
          now: now,
        );
        entries[key] = SyncManifestEntry(
          type: 'character_knowledge',
          id: sessionId,
          path: cloudPath('character_knowledge', sessionId),
          updatedAt: updatedAt,
          hash: hash,
        );
      }
    }

    await _addSingletons(entries, previous, now, cloudManifest);
    await _addDeletedEntries(entries, now);

    return SyncManifest(
      deviceId: deviceId,
      createdAt: previous.createdAt,
      lastSync: previous.lastSync,
      entries: entries,
    );
  }

  /// Decides manifest updatedAt without spurious "now" bumps on hash drift.
  static int _resolveUpdatedAt({
    required String hash,
    required SyncManifestEntry? prevEntry,
    required SyncManifestEntry? cloudEntry,
    required int now,
  }) {
    if (prevEntry != null && hash == prevEntry.hash) {
      return prevEntry.updatedAt;
    }
    if (cloudEntry != null && hash == cloudEntry.hash) {
      return cloudEntry.updatedAt;
    }
    if (prevEntry != null &&
        cloudEntry != null &&
        prevEntry.hash == cloudEntry.hash) {
      // Was aligned with cloud; local DB changed → treat as local edit.
      return now;
    }
    // No previous manifest entry — entity was never synced from this device.
    // Don't claim "now" (would always beat cloud); let entity-level updatedAt
    // (c.updatedAt, s.updatedAt) override if the entity was genuinely edited.
    return prevEntry?.updatedAt ?? 0;
  }

  /// Returns the size of the avatar file in bytes, or 0 if the file doesn't
  /// exist or avatarPath is null. The size is platform-neutral (same bytes on
  /// Android and Windows for the same image), unlike the path itself.
  int _avatarFileSize(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty) return 0;
    final store = _imageStore;
    if (store == null) return 0;
    try {
      final absPath = store.absolutePath(avatarPath);
      if (absPath == null) return 0;
      final file = File(absPath);
      if (!file.existsSync()) return 0;
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// Remove device-specific fields from entity JSON before hashing so that
  /// the same logical entity produces the same hash on every device.
  /// avatarPath is replaced by _avatarFileSize (platform-neutral) so that
  /// a missing or changed avatar binary triggers a re-push without causing
  /// Android↔Windows false-conflicts from differing absolute paths.
  /// Gallery is excluded entirely: image paths are device-local, and gallery
  /// metadata (ids, labels, order) can drift between devices without
  /// representing a meaningful content change.
  Map<String, dynamic> _normalizeForHash(Map<String, dynamic> json) {
    final out = Map<String, dynamic>.from(json);
    final avatarPath = out['avatarPath'] as String?;
    out.remove('avatarPath');
    out.remove('gallery');
    // Include avatar file size so that uploading/deleting the avatar binary
    // changes the hash and triggers a re-push, even when the JSON is unchanged.
    // Using file size (not path) keeps hashes consistent across platforms.
    final avatarSize = _avatarFileSize(avatarPath);
    if (avatarSize > 0) {
      out['_avatarFileSize'] = avatarSize;
    }
    return out;
  }

  Future<void> _addSingletons(
    Map<String, SyncManifestEntry> entries,
    SyncManifest previous,
    int now,
    SyncManifest? cloudManifest,
  ) async {
    final singletons = <String, dynamic>{};

    final lorebooks = await _lorebookRepo.getAll();
    singletons['lorebooks'] = lorebooks.map((l) => l.toJson()).toList();

    final apiConfigs = await _apiRepo.getAll();
    singletons['api_presets'] = apiConfigs
        .map((a) => a.copyWith(apiKey: '', embeddingApiKey: '').toJson())
        .toList();

    final presets = await _presetRepo.getAll();
    singletons['theme_presets'] = presets.map((p) => p.toJson()).toList();

    final uiThemes = await _themePresetRepo.getAll();
    singletons['ui_themes'] = uiThemes.map((t) => t.toJson()).toList();

    for (final entry in singletons.entries) {
      final type = entry.key;
      final items = entry.value as List;
      final hash = SyncSerialization.computeSyncHash(entry.value);
      final key = entryKey(type, type);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = items.isEmpty
          ? 0
          : _resolveUpdatedAt(
              hash: hash,
              prevEntry: prevEntry,
              cloudEntry: cloudEntry,
              now: now,
            );

      entries[key] = SyncManifestEntry(
        type: type,
        id: type,
        path: cloudPath(type, type),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    // extensions_settings is a Map singleton (not a list), handled separately.
    {
      const type = 'extensions_settings';
      final settings = await _extensionsSettingsStore.get();
      final settingsJson = settings.toJson();
      final hash = SyncSerialization.computeSyncHash(settingsJson);
      final key = entryKey(type, type);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: type,
        id: type,
        path: cloudPath(type, type),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    // Character folders — singleton (all folders + members in one JSON).
    if (_characterFolderStore != null) {
      const type = 'character_folders';
      final data = await _characterFolderStore.getAll();
      final hash = SyncSerialization.computeSyncHash(data);
      final key = entryKey(type, type);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: type,
        id: type,
        path: cloudPath(type, type),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final pipelineSettings = prefs.getString(
      SyncSerialization.pipelineSettingsKey,
    );
    final activeStudioPresetId = prefs.getString(
      SyncSerialization.activeStudioPresetKey,
    );
    if (pipelineSettings != null || activeStudioPresetId != null) {
      const type = 'local_storage';
      final payload = SyncSerialization.localStoragePayload(
        pipelineSettings: pipelineSettings,
        activeStudioPresetId: activeStudioPresetId,
      );
      final hash = SyncSerialization.computeSyncHash(payload);
      final key = entryKey(type, type);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: type,
        id: type,
        path: cloudPath(type, type),
        updatedAt: updatedAt,
        hash: hash,
      );
    }
  }

  Future<void> _addDeletedEntries(
    Map<String, SyncManifestEntry> entries,
    int now,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_deletedKey);
    if (raw == null) return;

    final deleted = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    for (final d in deleted) {
      final type = d['type'] as String;
      final id = d['id'] as String;
      final key = entryKey(type, id);
      if (!entries.containsKey(key)) {
        entries[key] = SyncManifestEntry(
          type: type,
          id: id,
          path: cloudPath(type, id),
          updatedAt: now,
          hash: '',
          deleted: true,
        );
      }
    }
  }

  @override
  Future<SyncManifest> readLocalManifest() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_manifestKey);
    if (raw == null) return const SyncManifest(deviceId: '', createdAt: 0);
    try {
      return SyncManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const SyncManifest(deviceId: '', createdAt: 0);
    }
  }

  @override
  Future<void> writeLocalManifest(SyncManifest manifest) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_manifestKey, jsonEncode(manifest.toJson()));
  }

  Future<void> markDeleted(String type, String id) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_deletedKey);
    final deleted = raw != null
        ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>().toList()
        : <Map<String, dynamic>>[];
    deleted.add({'type': type, 'id': id});
    await prefs.setString(_deletedKey, jsonEncode(deleted));
  }

  @override
  Future<void> clearLocalManifest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_manifestKey);
    await prefs.remove(_deletedKey);
  }

  @override
  Future<void> clearDeleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_deletedKey);
  }
}
