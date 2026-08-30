import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cloud_adapter.dart';
import '../sync_models.dart';
import 'sync_binary_asset_syncer.dart';
import 'sync_conflict.dart';
import 'sync_queue.dart';
import 'sync_image_stripper.dart';
import 'sync_serialization.dart';
import '../../../core/models/character.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/models/persona.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/preset.dart';
import '../../../core/models/studio_agent_codec.dart';
import '../../../core/models/studio_preset_codec.dart';
import '../../../core/application/session_deletion_store.dart';
import '../../../core/application/character_deletion_store.dart';
import '../../../shared/theme/theme_preset.dart';
import '../sync_repo_interfaces.dart';
import '../../../features/extensions/models/extension_preset.dart';
import '../../../features/extensions/models/extensions_settings.dart';
import '../../../features/extensions/models/info_block.dart';

class SyncProgress {
  final int current;
  final int total;
  final String? message;

  const SyncProgress({this.current = 0, this.total = 0, this.message});
}

class SyncEngine {
  final CloudAdapter _adapter;
  final SyncManifestProvider _manifestBuilder;
  final SyncCharacterStore _characterRepo;
  final SyncChatStore _chatRepo;
  final SyncPersonaStore _personaRepo;
  final SyncPresetStore _presetRepo;
  final SyncApiConfigStore _apiRepo;
  final SyncMemoryBookStore _memoryBookRepo;
  final SyncLorebookStore _lorebookRepo;
  final SyncEmbeddingStore _embeddingRepo;
  final SyncImageStore _imageStorage;
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
  final SyncReconciliationStateStore? _reconciliationStateStore;
  final SyncSessionLorebookOverlayStore? _sessionLorebookOverlayStore;
  final SessionDeletionStore _sessionDeletionStore;
  final CharacterDeletionStore _characterDeletionStore;
  final Future<void> Function(LorebookActivations) _saveLorebookActivations;
  final SyncQueue _queue = SyncQueue();
  late final SyncBinaryAssetSyncer _binarySyncer;
  bool _includeApiKeys = false;

  SyncEngine(
    this._adapter,
    this._manifestBuilder,
    this._characterRepo,
    this._chatRepo,
    this._personaRepo,
    this._presetRepo,
    this._apiRepo,
    this._memoryBookRepo,
    this._lorebookRepo,
    this._embeddingRepo,
    this._imageStorage,
    this._themePresetRepo,
    this._extensionPresetRepo,
    this._extensionsSettingsStore,
    this._infoBlockStore,
    this._trackerSnapshotStore,
    this._trackerValueStore,
    this._studioConfigStore,
    this._studioPresetStore,
    this._chatSummaryStore,
    this._characterFolderStore,
    this._memoryGraphStore,
    this._characterKnowledgeStore,
    this._sessionDeletionStore,
    this._characterDeletionStore,
    this._saveLorebookActivations, [
    this._reconciliationStateStore,
    this._sessionLorebookOverlayStore,
  ]) {
    _binarySyncer = SyncBinaryAssetSyncer(
      _adapter,
      _characterRepo,
      _personaRepo,
      _presetRepo,
      _imageStorage,
    );
  }

  Future<void> pushEntities({
    required void Function(SyncProgress) onProgress,
    bool includeApiKeys = false,
  }) async {
    _includeApiKeys = includeApiKeys;
    await _adapter.ensureFolder(cloudBase);
    await _adapter.ensureFolder('$cloudBase/characters');
    await _adapter.ensureFolder('$cloudBase/personas');
    await _adapter.ensureFolder('$cloudBase/chats');
    await _adapter.ensureFolder('$cloudBase/memory_books');
    await _adapter.ensureFolder('$cloudBase/persona_avatars');
    await _adapter.ensureFolder('$cloudBase/preset_images');
    await _adapter.ensureFolder('$cloudBase/extension_presets');
    await _adapter.ensureFolder('$cloudBase/info_blocks');
    await _adapter.ensureFolder('$cloudBase/tracker_snapshots');
    await _adapter.ensureFolder('$cloudBase/tracker_values');
    await _adapter.ensureFolder('$cloudBase/studio_configs');
    await _adapter.ensureFolder('$cloudBase/studio_presets');
    await _adapter.ensureFolder('$cloudBase/chat_summaries');
    await _adapter.ensureFolder('$cloudBase/memory_graphs');
    await _adapter.ensureFolder('$cloudBase/character_knowledge');
    await _adapter.ensureFolder('$cloudBase/session_lorebook_overlays');
    await _adapter.ensureFolder('$cloudBase/reconciliation_state');

    onProgress(const SyncProgress(message: 'Building sync manifest...'));
    SyncManifest? cloudManifest;
    try {
      final raw = await _adapter.download(cloudPath('manifest', 'manifest'));
      cloudManifest = SyncManifest.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on CloudFileNotFoundException {
      // A missing manifest means this is the first push or cloud data was wiped.
    } catch (e, st) {
      debugPrint('[sync] cloud manifest download failed: $e\n$st');
      rethrow;
    }
    await _mergeCloudReconciliationState(cloudManifest);
    final localManifest = await _manifestBuilder.buildLocalManifest(
      cloudManifest: cloudManifest,
    );

    final entries = localManifest.entries.values.toList();
    final candidatePaths = cloudManifest == null
        ? const <String>[]
        : entries
              .where((entry) {
                if (entry.deleted) return false;
                final cloudEntry = cloudManifest?.entries[entry.key];
                return cloudEntry != null &&
                    !cloudEntry.deleted &&
                    cloudEntry.hash == entry.hash;
              })
              .map((entry) => entry.path)
              .toList();
    final cloudListing = candidatePaths.isEmpty
        ? (paths: <String>{}, foldersWithFiles: <String>{})
        : await _loadCloudFilePathsForEntries(
            candidatePaths,
            onProgress: onProgress,
          );

    final galleryDirs = <String>{};
    for (final entry in entries) {
      if (entry.type == 'character' && !entry.deleted) {
        galleryDirs.add('$cloudBase/gallery/${entry.id}');
      }
    }
    for (final dir in galleryDirs) {
      await _adapter.ensureFolder(dir);
    }

    final tasks = <Future<void> Function()>[];
    var processed = 0;
    final hashSkippedKeys = <String>[];

    for (final entry in entries) {
      final cloudEntry = cloudManifest?.entries[entry.key];

      if (entry.deleted) {
        if (cloudEntry != null && !cloudEntry.deleted) {
          tasks.add(() async {
            processed++;
            onProgress(
              SyncProgress(
                current: processed,
                total: tasks.length,
                message: 'Deleting ${entry.type}:${entry.id}',
              ),
            );
            await SyncSerialization.deleteCloudFileIfExists(_adapter, entry);
          });
        }
        continue;
      }

      final cloudFileExists = cloudSyncPathExists(
        cloudListing.paths,
        entry.path,
      );

      // Trust the cloud manifest hash for the skip decision. A fresh folder
      // listing only serves to repair an entry whose file is genuinely missing.
      // Previously, when the listing came back empty or errored, every
      // hash-matching entry was re-uploaded because file existence could not be
      // confirmed — producing a full-cloud re-push with no duplicates. See the
      // empty-body fall-through that this replaces.
      if (cloudEntry != null &&
          !cloudEntry.deleted &&
          cloudEntry.hash == entry.hash) {
        final listingVerifiedMissing =
            cloudListing.foldersWithFiles.contains(
              _cloudParentFolder(entry.path),
            ) &&
            !cloudFileExists;
        if (listingVerifiedMissing) {
          // Listing succeeded and the file is actually absent — repair it.
          // Falls through to the push task below.
        } else {
          hashSkippedKeys.add(entry.key);
          continue;
        }
      }

      tasks.add(() async {
        processed++;
        onProgress(
          SyncProgress(
            current: processed,
            total: tasks.length,
            message: 'Pushing ${entry.type}:${entry.id}',
          ),
        );
        await _pushEntry(entry);
      });
    }

    onProgress(
      SyncProgress(
        current: 0,
        total: tasks.length,
        message: tasks.isEmpty
            ? 'Nothing to push'
            : 'Pushing ${tasks.length} items...',
      ),
    );

    List<Object>? taskErrors;
    if (tasks.isNotEmpty) {
      final result = await _queue.enqueueAll(
        tasks,
        concurrency: 3,
        delayMs: 300,
      );
      taskErrors = result.errors;
    }

    if (taskErrors != null && taskErrors.isNotEmpty) {
      throw SyncQueueAggregateError(taskErrors);
    }

    final cleanedEntries = Map<String, SyncManifestEntry>.from(
      localManifest.entries,
    )..removeWhere((_, e) => e.deleted);

    final updatedManifest = localManifest.copyWith(
      version: SyncManifest.currentVersion,
      lastSync: DateTime.now().millisecondsSinceEpoch,
      entries: cleanedEntries,
      apiKeysIncluded: _includeApiKeys,
    );
    final manifestJson = jsonEncode(updatedManifest.toJson());
    await _adapter.upload(cloudPath('manifest', 'manifest'), manifestJson);
    await _manifestBuilder.writeLocalManifest(updatedManifest);
    await _manifestBuilder.clearDeleted();
  }

  Future<({Set<String> paths, Set<String> foldersWithFiles})>
  _loadCloudFilePathsForEntries(
    List<String> entryPaths, {
    required void Function(SyncProgress) onProgress,
  }) async {
    onProgress(const SyncProgress(message: 'Checking cloud files...'));
    final folders = entryPaths.map(_cloudParentFolder).toSet();
    final paths = <String>{};
    final foldersWithFiles = <String>{};
    for (final folder in folders) {
      try {
        final files = await _adapter.listFolder(folder);
        if (files.any((file) => !file.isFolder)) {
          foldersWithFiles.add(folder);
        }
        paths.addAll(
          files
              .where((f) => !f.isFolder)
              .map((f) => normalizeCloudSyncPath(f.path)),
        );
      } catch (e, st) {
        // A failed listing used to silently drop the folder from cloudFilePaths,
        // which collapsed the skip gate and triggered a full re-push. Log it so
        // the cause is visible; the skip logic now trusts the manifest hash
        // regardless of listing success.
        debugPrint('[sync] listFolder failed for "$folder": $e\n$st');
      }
    }
    return (paths: paths, foldersWithFiles: foldersWithFiles);
  }

  String _cloudParentFolder(String path) {
    final slash = path.lastIndexOf('/');
    if (slash <= 0) return cloudBase;
    return path.substring(0, slash);
  }

  Future<void> pullEntities({
    required void Function(SyncProgress) onProgress,
    required void Function(SyncConflict) onConflict,
  }) async {
    final cloudManifest = await _downloadCloudManifest();
    if (cloudManifest == null) return;
    final previousManifest = await _manifestBuilder.readLocalManifest();
    final isFirstSync = previousManifest.lastSync == 0;
    final localManifest = await _manifestBuilder.buildLocalManifest(
      cloudManifest: cloudManifest,
    );

    final entries = cloudManifest.entries.values.toList();
    final conflicts = <SyncConflict>[];
    final pullEntries = <SyncManifestEntry>[];
    final acceptedCloudEntries = <SyncManifestEntry>[];

    for (final cloudEntry in entries) {
      final localEntry = localManifest.entries[cloudEntry.key];
      final previouslyAccepted = previousManifest.entries[cloudEntry.key];

      if (_isAlreadyCurrentOrAccepted(
        cloudEntry,
        localEntry,
        previouslyAccepted,
      )) {
        continue;
      }

      // Before first successful sync, local manifest timestamps are unreliable
      // (no previous entries → updatedAt defaults to now or entity timestamp).
      // Auto-prefer cloud for everything on first sync.
      if (isFirstSync && localEntry != null) {
        pullEntries.add(cloudEntry);
        continue;
      }

      // This aggregate is merge-only, but validating it reads the owning chat.
      // Defer the merge until the ordered pull phase has applied that chat.
      if (cloudEntry.type == 'reconciliation_state') {
        pullEntries.add(cloudEntry);
        continue;
      }

      if (await _entriesSemanticallyEqual(
        cloudEntry,
        localEntry,
        cloudManifest,
      )) {
        acceptedCloudEntries.add(cloudEntry);
        continue;
      }

      if (SyncConflictDetector.needsConflict(localEntry, cloudEntry)) {
        final localData = await _readLocalEntity(
          cloudEntry.type,
          cloudEntry.id,
        );
        String? characterName;
        if (cloudEntry.type == 'chat') {
          final charId = localData?['characterId'] as String?;
          if (charId != null) {
            final character = await _characterRepo.getById(charId);
            characterName = character?.name;
          }
        }
        final name = SyncConflictDetector.getConflictName(
          cloudEntry.type,
          localData,
          null,
          cloudEntry.id,
          characterName: characterName,
        );
        conflicts.add(
          SyncConflict(
            key: cloudEntry.key,
            type: cloudEntry.type,
            id: cloudEntry.id,
            localEntry: localEntry!,
            cloudEntry: cloudEntry,
            name: name,
          ),
        );
        continue;
      }

      pullEntries.add(cloudEntry);
    }

    for (final c in conflicts) {
      onConflict(c);
    }

    if (pullEntries.isNotEmpty) {
      await _applyPullEntries(
        pullEntries,
        localManifest,
        cloudManifest,
        onProgress,
        acceptedCloudEntries: acceptedCloudEntries,
      );
    } else if (conflicts.isEmpty) {
      onProgress(
        const SyncProgress(current: 0, total: 0, message: 'Nothing to pull'),
      );
      await _finalizePull(
        localManifest,
        cloudManifest,
        acceptedCloudEntries: acceptedCloudEntries,
      );
    } else {
      await _saveCloudManifestForPendingPull(cloudManifest);
    }
  }

  Future<void> applyPendingPull({
    required void Function(SyncProgress) onProgress,
    List<String>? resolvedAsCloud,
    bool pushLocalChanges = false,
  }) async {
    final cloudManifest =
        await _loadCloudManifestForPendingPull() ??
        await _downloadCloudManifest();
    if (cloudManifest == null) return;
    final previousManifest = await _manifestBuilder.readLocalManifest();
    final localManifest = await _manifestBuilder.buildLocalManifest(
      cloudManifest: cloudManifest,
    );

    final pullEntries = <SyncManifestEntry>[];
    final acceptedCloudEntries = <SyncManifestEntry>[];

    for (final cloudEntry in cloudManifest.entries.values) {
      final localEntry = localManifest.entries[cloudEntry.key];
      final previouslyAccepted = previousManifest.entries[cloudEntry.key];
      if (_isAlreadyCurrentOrAccepted(
        cloudEntry,
        localEntry,
        previouslyAccepted,
      )) {
        continue;
      }
      if (cloudEntry.type == 'reconciliation_state') {
        pullEntries.add(cloudEntry);
        continue;
      }
      if (await _entriesSemanticallyEqual(
        cloudEntry,
        localEntry,
        cloudManifest,
      )) {
        acceptedCloudEntries.add(cloudEntry);
        continue;
      }
      if (SyncConflictDetector.needsConflict(localEntry, cloudEntry)) {
        if (resolvedAsCloud != null &&
            resolvedAsCloud.contains(cloudEntry.key)) {
          pullEntries.add(cloudEntry);
        }
        continue;
      }
      pullEntries.add(cloudEntry);
    }

    if (pullEntries.isNotEmpty) {
      await _applyPullEntries(
        pullEntries,
        localManifest,
        cloudManifest,
        onProgress,
        acceptedCloudEntries: acceptedCloudEntries,
      );
    } else {
      onProgress(
        const SyncProgress(current: 0, total: 0, message: 'Nothing to pull'),
      );
      await _finalizePull(
        localManifest,
        cloudManifest,
        acceptedCloudEntries: acceptedCloudEntries,
      );
    }

    // A local conflict winner must become cloud truth immediately. In
    // particular, this preserves additive local entities (such as Loom
    // presets) absent from an older cloud manifest.
    if (pushLocalChanges) {
      await pushEntities(
        onProgress: onProgress,
        includeApiKeys: _includeApiKeys,
      );
    }

    await _clearPendingPullManifest();
  }

  Future<void> _applyPullEntries(
    List<SyncManifestEntry> pullEntries,
    SyncManifest localManifest,
    SyncManifest cloudManifest,
    void Function(SyncProgress) onProgress, {
    List<SyncManifestEntry> acceptedCloudEntries = const [],
  }) async {
    final appliedEntries = <SyncManifestEntry>[];
    var processed = 0;
    final primaryEntries = pullEntries
        .where(
          (entry) =>
              entry.type != 'session_lorebook_overlays' &&
              entry.type != 'reconciliation_state',
        )
        .toList(growable: false);
    final overlayEntries = pullEntries
        .where((entry) => entry.type == 'session_lorebook_overlays')
        .toList(growable: false);
    final reconciliationEntries = pullEntries
        .where((entry) => entry.type == 'reconciliation_state')
        .toList(growable: false);

    Future<List<Object>> applyEntries(List<SyncManifestEntry> entries) async {
      final tasks = <Future<void> Function()>[];
      for (final entry in entries) {
        tasks.add(() async {
          processed++;
          onProgress(
            SyncProgress(
              current: processed,
              total: pullEntries.length,
              message: 'Pulling ${entry.type}:${entry.id}',
            ),
          );
          await _pullEntry(entry);
          appliedEntries.add(entry);
        });
      }
      if (tasks.isEmpty) return const [];
      final result = await _queue.enqueueAll(
        tasks,
        concurrency: 3,
        delayMs: 300,
      );
      return result.errors;
    }

    onProgress(
      SyncProgress(
        current: 0,
        total: pullEntries.length,
        message: 'Pulling ${pullEntries.length} items...',
      ),
    );

    // Both dependent aggregates validate against chats/base lorebooks. Apply
    // primary entities first, current lore projections second, and immutable
    // reconciliation provenance last.
    final taskErrors = <Object>[
      ...await applyEntries(primaryEntries),
      ...await applyEntries(overlayEntries),
      ...await applyEntries(reconciliationEntries),
    ];

    await _finalizePull(
      localManifest,
      cloudManifest,
      acceptedCloudEntries: [...acceptedCloudEntries, ...appliedEntries],
    );

    if (taskErrors.isNotEmpty) {
      throw SyncQueueAggregateError(taskErrors);
    }
  }

  Future<void> _finalizePull(
    SyncManifest localManifest,
    SyncManifest cloudManifest, {
    List<SyncManifestEntry> acceptedCloudEntries = const [],
  }) async {
    final rebuilt = await _manifestBuilder.buildLocalManifest(
      cloudManifest: cloudManifest,
    );
    final entries = Map<String, SyncManifestEntry>.from(rebuilt.entries);
    for (final entry in acceptedCloudEntries) {
      if (entry.type == 'reconciliation_state' ||
          entry.type == 'session_lorebook_overlays') {
        entries[entry.key] = entry;
      }
    }
    await _manifestBuilder.writeLocalManifest(
      rebuilt.copyWith(
        createdAt: cloudManifest.createdAt != 0
            ? cloudManifest.createdAt
            : rebuilt.createdAt,
        lastSync: DateTime.now().millisecondsSinceEpoch,
        entries: entries,
      ),
    );
    await _manifestBuilder.clearDeleted();
  }

  bool _isAlreadyCurrentOrAccepted(
    SyncManifestEntry cloudEntry,
    SyncManifestEntry? localEntry,
    SyncManifestEntry? previouslyAccepted,
  ) {
    if (cloudEntry.hash == localEntry?.hash &&
        cloudEntry.deleted == localEntry?.deleted) {
      return true;
    }
    return (cloudEntry.type == 'reconciliation_state' ||
            cloudEntry.type == 'session_lorebook_overlays') &&
        cloudEntry.hash == previouslyAccepted?.hash &&
        cloudEntry.deleted == previouslyAccepted?.deleted;
  }

  Future<SyncManifest?> _downloadCloudManifest() async {
    try {
      final raw = await _adapter.download(cloudPath('manifest', 'manifest'));
      return SyncManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static const _pendingManifestKey = 'gz_sync_pending_pull_manifest';

  Future<void> _saveCloudManifestForPendingPull(SyncManifest manifest) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingManifestKey, jsonEncode(manifest.toJson()));
  }

  Future<SyncManifest?> _loadCloudManifestForPendingPull() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingManifestKey);
    if (raw == null) return null;
    try {
      return SyncManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearPendingPullManifest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingManifestKey);
  }

  Future<void> resolveConflict(SyncConflict conflict, String choice) async {
    final deferCloudApply =
        conflict.type == 'session_lorebook_overlays' && choice == 'cloud';
    if (choice == 'cloud' && !deferCloudApply) {
      await _pullEntry(conflict.cloudEntry);
    }

    final rebuiltManifest = await _manifestBuilder.buildLocalManifest();
    final updatedEntries = Map<String, SyncManifestEntry>.from(
      rebuiltManifest.entries,
    );
    final rebuiltEntry = updatedEntries[conflict.key];

    if (choice == 'cloud' && !deferCloudApply) {
      // Align manifest with cloud so the same conflict does not reappear.
      updatedEntries[conflict.key] = conflict.cloudEntry;
    } else if (choice == 'local' && rebuiltEntry != null) {
      updatedEntries[conflict.key] = rebuiltEntry.copyWith(
        updatedAt: conflict.localEntry.updatedAt,
      );
    }

    await _manifestBuilder.writeLocalManifest(
      rebuiltManifest.copyWith(entries: updatedEntries),
    );
  }

  Future<bool> cloudHasData() async {
    try {
      final files = await _adapter.listFolder(cloudBase);
      return files.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> wipeCloudData({
    required void Function(SyncProgress) onProgress,
  }) async {
    onProgress(const SyncProgress(message: 'Deleting cloud data...'));
    try {
      await _adapter.deleteFolder(cloudBase);
    } catch (e) {
      final msg = e.toString();
      if (!msg.contains('not_found') && !msg.contains('path_not_found')) {
        rethrow;
      }
    }

    onProgress(const SyncProgress(message: 'Waiting for cloud to finalize...'));
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        final files = await _adapter.listFolder(cloudBase);
        if (files.isEmpty) break;
      } catch (_) {
        break;
      }
    }

    onProgress(const SyncProgress(message: 'Recreating cloud folder...'));
    await _adapter.invalidateFolderCache();
    try {
      await _adapter.ensureFolder(cloudBase);
    } catch (_) {}
  }

  Future<void> _pushEntry(SyncManifestEntry entry) async {
    final data = await _readLocalEntity(entry.type, entry.id);
    if (data == null) return;
    final json = jsonEncode(data);
    if (json.length > maxSyncPayloadBytes) {
      throw Exception('Payload exceeds limit for ${entry.key}');
    }
    await _adapter.upload(entry.path, json);

    if (entry.type == 'character') {
      await _binarySyncer.pushCharacterAvatar(entry.id);
      await _binarySyncer.pushCharacterGallery(entry.id);
    }
    if (entry.type == 'persona') {
      await _binarySyncer.pushPersonaAvatar(entry.id);
    }
    // Presets travel as one singleton entry, so their covers are pushed as a
    // batch keyed by preset id rather than per manifest entry.
    if (entry.type == 'theme_presets') {
      await _binarySyncer.pushPresetImages();
    }
  }

  Future<void> _pullEntry(SyncManifestEntry entry) async {
    if (entry.deleted) {
      await _deleteLocalEntity(entry.type, entry.id);
      return;
    }

    final cloudData = await SyncSerialization.readCloudEntity(_adapter, entry);
    if (cloudData == null) return;

    await _applyCloudEntity(entry.type, entry.id, cloudData);

    if (entry.type == 'character') {
      await _binarySyncer.pullCharacterAvatar(entry.id);
      await _binarySyncer.pullCharacterGallery(entry.id);
    }
    if (entry.type == 'persona') {
      await _binarySyncer.pullPersonaAvatar(entry.id);
    }
    if (entry.type == 'theme_presets') {
      await _binarySyncer.pullPresetImages();
    }
    if (entry.type == 'chat') {
      final charId = cloudData['characterId'] as String?;
      if (charId != null) {
        await _binarySyncer.sanitizeInvalidAvatarPath(charId);
        await _binarySyncer.pullCharacterAvatar(charId);
      }
    }
  }

  Future<bool> _entriesSemanticallyEqual(
    SyncManifestEntry cloudEntry,
    SyncManifestEntry? localEntry,
    SyncManifest cloudManifest,
  ) async {
    if (localEntry == null) return false;
    if (cloudEntry.hash == localEntry.hash) return true;

    switch (cloudEntry.type) {
      case 'reconciliation_state':
        final store = _reconciliationStateStore;
        if (store == null) return false;
        final cloudData = await SyncSerialization.readRequiredCloudEntity(
          _adapter,
          cloudEntry,
        );
        await store.mergeBySessionId(cloudEntry.id, cloudData);
        // This aggregate intentionally normalizes or discards stale derived
        // provenance. A successful merge is therefore semantic equality even
        // when the resulting canonical payload no longer has the cloud hash.
        return true;
      case 'memory_book':
        final localMb = await _memoryBookRepo.getBySessionId(cloudEntry.id);
        if (localMb == null) return false;
        final cloudData = await SyncSerialization.readCloudEntity(
          _adapter,
          cloudEntry,
        );
        if (cloudData == null) return false;
        final localHash = SyncSerialization.computeMemoryBookHash(
          localMb.toJson(),
        );
        final cloudHash = SyncSerialization.computeMemoryBookHash(cloudData);
        final equal = localHash == cloudHash;
        return equal;
      case 'studio_config':
        final localConfig = await _studioConfigStore.getById(cloudEntry.id);
        if (localConfig == null) return false;
        final cloudData = await SyncSerialization.readCloudEntity(
          _adapter,
          cloudEntry,
        );
        if (cloudData == null) return false;
        return SyncSerialization.computeStudioConfigHash(cloudData) ==
            SyncSerialization.computeStudioConfigHash(localConfig.toJson());
      case 'api_presets':
        if (cloudManifest.apiKeysIncluded) return false;
        final localAll = await _apiRepo.getAll();
        final cloudData = await SyncSerialization.readCloudEntity(
          _adapter,
          cloudEntry,
        );
        if (cloudData == null) return false;
        final List<Map<String, dynamic>> cloudItems;
        if (cloudData['__singleton'] == true) {
          cloudItems = (cloudData['items'] as List)
              .cast<Map<String, dynamic>>();
        } else if (cloudData.containsKey('items')) {
          cloudItems = (cloudData['items'] as List)
              .cast<Map<String, dynamic>>();
        } else {
          cloudItems = [cloudData];
        }
        final localHash = SyncSerialization.computeApiPresetsHash(
          localAll.map((a) => a.toJson()),
        );
        final cloudHash = SyncSerialization.computeApiPresetsHash(cloudItems);
        return localHash == cloudHash;
      default:
        return false;
    }
  }

  Future<Map<String, dynamic>?> _readLocalEntity(String type, String id) async {
    try {
      switch (type) {
        case 'character':
          final c = await _characterRepo.getById(id);
          if (c == null) return null;
          return c.toJson();
        case 'persona':
          final p = await _personaRepo.getById(id);
          if (p == null) return null;
          return p.toJson();
        case 'chat':
          final s = await _chatRepo.getById(id);
          if (s == null) return null;
          return stripImagesFromSession(s.toJson());
        case 'memory_book':
          final mb = await _memoryBookRepo.getBySessionId(id);
          if (mb == null) return null;
          return mb.toJson();
        case 'lorebooks':
          final all = await _lorebookRepo.getAll();
          return {
            '__singleton': true,
            'items': all.map((l) => l.toJson()).toList(),
          };
        case 'api_presets':
          final all = await _apiRepo.getAll();
          final items = all.map((a) {
            if (!_includeApiKeys) {
              return a.copyWith(apiKey: '', embeddingApiKey: '').toJson();
            }
            return a.toJson();
          }).toList();
          return {'__singleton': true, 'items': items};
        case 'theme_presets':
          final all = await _presetRepo.getAll();
          return {
            '__singleton': true,
            'items': all.map((p) => p.toJson()).toList(),
          };
        case 'ui_themes':
          final all = await _themePresetRepo.getAll();
          return {
            '__singleton': true,
            'items': all.map((t) => t.toJson()).toList(),
          };
        case 'extension_preset':
          final ep = await _extensionPresetRepo.getById(id);
          if (ep == null) return null;
          return ep.toJson();
        case 'extensions_settings':
          final s = await _extensionsSettingsStore.get();
          return {'__singleton': true, 'settings': s.toJson()};
        case 'local_storage':
          return _readLocalStorage();
        case 'info_block':
          // id == sessionId for info_block entries
          final blocks = await _infoBlockStore.getBySessionId(id);
          if (blocks.isEmpty) return null;
          return SyncSerialization.infoBlocksPayload(blocks);
        case 'tracker_snapshot':
          final snaps = await _trackerSnapshotStore.getBySessionId(id);
          if (snaps.isEmpty) return null;
          return {'__trackerSnapshots': true, 'items': snaps};
        case 'tracker_value':
          final trackers = await _trackerValueStore.getBySessionId(id);
          if (trackers.isEmpty) return null;
          return {'__trackerValues': true, 'items': trackers};
        case 'studio_config':
          final config = await _studioConfigStore.getById(id);
          return config?.toJson();
        case 'studio_preset':
          if (_studioPresetStore == null) return null;
          final preset = await _studioPresetStore.getById(id);
          return preset?.toJson();
        case 'chat_summary':
          if (_chatSummaryStore == null) return null;
          return _chatSummaryStore.getBySessionId(id);
        case 'character_folders':
          if (_characterFolderStore == null) return null;
          return _characterFolderStore.getAll();
        case 'memory_graph':
          if (_memoryGraphStore == null) return null;
          return _memoryGraphStore.getBySessionId(id);
        case 'character_knowledge':
          if (_characterKnowledgeStore == null) return null;
          return _characterKnowledgeStore.getBySessionId(id);
        case 'session_lorebook_overlays':
          if (_sessionLorebookOverlayStore == null) return null;
          return _sessionLorebookOverlayStore.getBySessionId(id);
        case 'reconciliation_state':
          if (_reconciliationStateStore == null) return null;
          return _reconciliationStateStore.getBySessionId(id);
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> _applyCloudEntity(
    String type,
    String id,
    Map<String, dynamic> data,
  ) async {
    try {
      switch (type) {
        case 'character':
          await _applyCloudCharacter(id, data);
          break;
        case 'persona':
          await _applyCloudPersona(id, data);
          break;
        case 'chat':
          await _chatRepo.put(ChatSession.fromJson(data));
          break;
        case 'memory_book':
          await _memoryBookRepo.put(MemoryBook.fromJson(data));
          break;
        case 'lorebooks':
          await _applyLorebooksWithEmbeddingCleanup(data);
          break;
        case 'api_presets':
          await _applyApiConfigs(data);
          break;
        case 'theme_presets':
          await _applySingleton<Preset>(
            data,
            Preset.fromJson,
            _presetRepo,
            idOf: (p) => p.id,
          );
          break;
        case 'ui_themes':
          await _applyUiThemes(data);
          break;
        case 'extension_preset':
          await _extensionPresetRepo.put(ExtensionPreset.fromJson(data));
          break;
        case 'extensions_settings':
          final settingsJson = data['settings'] as Map<String, dynamic>?;
          if (settingsJson != null) {
            await _extensionsSettingsStore.put(
              ExtensionsSettings.fromJson(settingsJson),
            );
          }
          break;
        case 'local_storage':
          await _applyLocalStorage(data);
          break;
        case 'info_block':
          await _applyCloudInfoBlocks(id, data);
          break;
        case 'tracker_snapshot':
          await _applyCloudTrackerSnapshots(id, data);
          break;
        case 'tracker_value':
          await _applyCloudTrackerValues(id, data);
          break;
        case 'studio_config':
          await _studioConfigStore.put(StudioAgentCodec.decodeConfig(data));
          break;
        case 'studio_preset':
          if (_studioPresetStore != null) {
            await _studioPresetStore.put(
              StudioPresetCodec.decodePreset(data).preset,
            );
          }
          break;
        case 'chat_summary':
          if (_chatSummaryStore != null) {
            await _chatSummaryStore.putRaw(data);
          }
          break;
        case 'character_folders':
          if (_characterFolderStore != null) {
            await _characterFolderStore.applyAll(data);
          }
          break;
        case 'memory_graph':
          if (_memoryGraphStore != null) {
            await _memoryGraphStore.applyBySessionId(id, data);
          }
          break;
        case 'character_knowledge':
          if (_characterKnowledgeStore != null) {
            await _characterKnowledgeStore.applyBySessionId(id, data);
          }
          break;
        case 'session_lorebook_overlays':
          if (_sessionLorebookOverlayStore != null) {
            await _sessionLorebookOverlayStore.applyBySessionId(id, data);
          }
          break;
        case 'reconciliation_state':
          if (_reconciliationStateStore != null) {
            await _reconciliationStateStore.mergeBySessionId(id, data);
          }
          break;
      }
    } catch (_) {
      if (type == 'reconciliation_state' ||
          type == 'session_lorebook_overlays') {
        rethrow;
      }
    }
  }

  Future<void> _applyCloudInfoBlocks(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    final List<Map<String, dynamic>> items;
    if (data['__infoBlocks'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      return;
    }

    // Replace existing blocks for this session with the cloud version.
    await _infoBlockStore.deleteBySessionId(sessionId);
    for (final item in items) {
      await _infoBlockStore.insert(InfoBlock.fromJson(item));
    }
  }

  Future<void> _applyCloudTrackerSnapshots(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    final List<Map<String, dynamic>> items;
    if (data['__trackerSnapshots'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      return;
    }

    // Replace existing snapshots for this session with the cloud version.
    await _trackerSnapshotStore.deleteBySessionId(sessionId);
    for (final item in items) {
      await _trackerSnapshotStore.insertRaw(item);
    }
  }

  Future<void> _applyCloudTrackerValues(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    final List<Map<String, dynamic>> items;
    if (data['__trackerValues'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      return;
    }

    await _trackerValueStore.deleteBySessionId(sessionId);
    for (final item in items) {
      await _trackerValueStore.insertRaw(item);
    }
  }

  /// avatarPath and gallery hold device-local paths; never apply cloud values
  /// directly — binary assets are synced in [_pullCharacterAvatar] /
  /// [_pullCharacterGallery].
  Future<void> _applyCloudCharacter(
    String id,
    Map<String, dynamic> data,
  ) async {
    final local = await _characterRepo.getById(id);
    final json = Map<String, dynamic>.from(data);
    json.remove('avatarPath');
    json.remove('gallery');
    var character = Character.fromJson(json);
    if (local != null) {
      character = character.copyWith(
        avatarPath: local.avatarPath,
        gallery: local.gallery,
      );
    }
    await _characterRepo.put(character);
  }

  Future<void> _applyCloudPersona(String id, Map<String, dynamic> data) async {
    final local = await _personaRepo.getById(id);
    final json = Map<String, dynamic>.from(data);
    json.remove('avatarPath');
    var persona = Persona.fromJson(json);
    if (local != null) {
      persona = persona.copyWith(avatarPath: local.avatarPath);
    }
    await _personaRepo.put(persona);
  }

  Future<void> _applySingleton<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic>) fromJson,
    dynamic repo, {
    String Function(T)? idOf,
  }) async {
    final List<Map<String, dynamic>> items;
    if (data['__singleton'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      items = [data];
    }

    final getAll = repo.getAll as Future<List<T>> Function();
    final put = repo.put as Future<void> Function(T);
    final delete = repo.delete as Future<void> Function(String);

    final cloudIds = <String>{};
    final parsed = <T>[];
    for (final item in items) {
      final entity = fromJson(item);
      parsed.add(entity);
      if (idOf != null) {
        cloudIds.add(idOf(entity));
      }
    }

    if (idOf != null) {
      final existing = await getAll();
      for (final entity in existing) {
        final id = idOf(entity);
        if (!cloudIds.contains(id)) {
          await delete(id);
        }
      }
    }

    for (final entity in parsed) {
      await put(entity);
    }
  }

  /// Applies the lorebook singleton from cloud data, cleaning up embeddings for
  /// removed lorebooks and rebuilding the lorebookActivations SharedPreferences
  /// from the DB truth after the apply completes.
  Future<void> _applyLorebooksWithEmbeddingCleanup(
    Map<String, dynamic> data,
  ) async {
    final List<Map<String, dynamic>> items;
    if (data['__singleton'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      items = [data];
    }

    final parsed = items.map(Lorebook.fromJson).toList();
    final cloudIds = {for (final lb in parsed) lb.id};

    // Delete lorebooks no longer in the cloud, including their embedding vectors.
    final existing = await _lorebookRepo.getAll();
    for (final lb in existing) {
      if (!cloudIds.contains(lb.id)) {
        await _lorebookRepo.delete(lb.id);
        await _embeddingRepo.deleteBySourceId(lb.id);
      }
    }

    // Upsert all cloud lorebooks.
    for (final lb in parsed) {
      await _lorebookRepo.put(lb);
    }

    // Rebuild lorebookActivations prefs from the DB truth so that the
    // connections UI and the scanner use consistent data across devices.
    await _rebuildLorebookActivationsPrefs();
  }

  /// Reads all lorebooks from the DB and rewrites the `lorebookActivations`
  /// SharedPreferences key from their activationScope / activationTargetId
  /// fields. Called after a lorebook pull to eliminate stale prefs that would
  /// otherwise show phantom character/chat connections in the UI.
  Future<void> _rebuildLorebookActivationsPrefs() async {
    final all = await _lorebookRepo.getAll();
    final charMap = <String, List<String>>{};
    final chatMap = <String, List<String>>{};
    for (final lb in all) {
      final targetId = lb.activationTargetId;
      if (targetId == null) continue;
      if (lb.activationScope == 'character') {
        charMap.putIfAbsent(targetId, () => []).add(lb.id);
      } else if (lb.activationScope == 'chat') {
        chatMap.putIfAbsent(targetId, () => []).add(lb.id);
      }
    }
    final activations = LorebookActivations(character: charMap, chat: chatMap);
    await _saveLorebookActivations(activations);
  }

  /// Applies cloud api_presets while preserving local API keys and embedding
  /// keys. Cloud payloads strip keys (empty string) when includeApiKeys=false;
  /// blindly writing them would wipe the user's credentials on every pull.
  Future<void> _applyApiConfigs(Map<String, dynamic> data) async {
    final List<Map<String, dynamic>> items;
    if (data['__singleton'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      items = [data];
    }

    final existing = await _apiRepo.getAll();
    final localById = {for (final a in existing) a.id: a};

    final cloudIds = <String>{};
    for (final item in items) {
      final cloudConfig = ApiConfig.fromJson(item);
      cloudIds.add(cloudConfig.id);

      final local = localById[cloudConfig.id];
      final merged = cloudConfig.copyWith(
        // Preserve local keys: use cloud key only when it is non-empty
        // (i.e. when includeApiKeys=true was used during push).
        apiKey: cloudConfig.apiKey.isNotEmpty
            ? cloudConfig.apiKey
            : (local?.apiKey ?? ''),
        embeddingApiKey: cloudConfig.embeddingApiKey.isNotEmpty
            ? cloudConfig.embeddingApiKey
            : (local?.embeddingApiKey ?? ''),
      );
      await _apiRepo.put(merged);
    }

    // Delete local configs that no longer exist in cloud.
    for (final local in existing) {
      if (!cloudIds.contains(local.id)) {
        await _apiRepo.delete(local.id);
      }
    }
  }

  Future<void> _applyUiThemes(Map<String, dynamic> data) async {
    final List<Map<String, dynamic>> items;
    if (data['__singleton'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      items = [data];
    }
    final presets = items.map((j) => themePresetFromStoredJson(j)).toList();
    await _themePresetRepo.putAll(presets);
  }

  Future<void> _deleteLocalEntity(String type, String id) async {
    try {
      switch (type) {
        case 'character':
          await _characterDeletionStore.deleteCharacters({id});
          break;
        case 'persona':
          await _personaRepo.delete(id);
          break;
        case 'chat':
          await _sessionDeletionStore.deleteSession(id);
          break;
        case 'memory_book':
          await _memoryBookRepo.deleteBySessionId(id);
          break;
        case 'lorebooks':
          final all = await _lorebookRepo.getAll();
          for (final lb in all) {
            await _lorebookRepo.delete(lb.id);
            await _embeddingRepo.deleteBySourceId(lb.id);
          }
          break;
        case 'api_presets':
          final apis = await _apiRepo.getAll();
          for (final a in apis) {
            await _apiRepo.delete(a.id);
          }
          break;
        case 'theme_presets':
          final presets = await _presetRepo.getAll();
          for (final p in presets) {
            await _presetRepo.delete(p.id);
          }
          break;
        case 'ui_themes':
          await _themePresetRepo.putAll([]);
          break;
        case 'local_storage':
          await _deleteLocalStorage();
          break;
        case 'extension_preset':
          await _extensionPresetRepo.delete(id);
          break;
        case 'info_block':
          // id == sessionId for info_block entries
          await _infoBlockStore.deleteBySessionId(id);
          break;
        case 'tracker_snapshot':
          await _trackerSnapshotStore.deleteBySessionId(id);
          break;
        case 'tracker_value':
          await _trackerValueStore.deleteBySessionId(id);
          break;
        case 'studio_config':
          await _studioConfigStore.delete(id);
          break;
        case 'studio_preset':
          if (_studioPresetStore != null) {
            await _studioPresetStore.delete(id);
          }
          break;
        case 'chat_summary':
          if (_chatSummaryStore != null) {
            await _chatSummaryStore.deleteBySessionId(id);
          }
          break;
        case 'memory_graph':
          if (_memoryGraphStore != null) {
            await _memoryGraphStore.deleteBySessionId(id);
          }
          break;
        case 'character_knowledge':
          if (_characterKnowledgeStore != null) {
            await _characterKnowledgeStore.deleteBySessionId(id);
          }
          break;
        case 'session_lorebook_overlays':
          if (_sessionLorebookOverlayStore != null) {
            await _sessionLorebookOverlayStore.deleteBySessionId(id);
          }
          break;
        case 'reconciliation_state':
          if (_reconciliationStateStore != null) {
            await _reconciliationStateStore.deleteBySessionId(id);
          }
          break;
        // extensions_settings has no meaningful "delete" — it's always present.
      }
    } catch (_) {}
  }

  Future<void> _mergeCloudReconciliationState(
    SyncManifest? cloudManifest,
  ) async {
    final store = _reconciliationStateStore;
    if (store == null || cloudManifest == null) return;
    for (final entry in cloudManifest.entries.values) {
      if (entry.type != 'reconciliation_state' || entry.deleted) continue;
      if (await _manifestBuilder.isDeleted(entry.type, entry.id) ||
          await _manifestBuilder.isDeleted('chat', entry.id)) {
        continue;
      }
      if (await _chatRepo.getById(entry.id) == null) {
        final chatEntry = cloudManifest.entries[entryKey('chat', entry.id)];
        if (chatEntry == null || chatEntry.deleted) {
          throw StateError(
            'Reconciliation state has no owning cloud chat: ${entry.id}',
          );
        }
        final chatData = await SyncSerialization.readRequiredCloudEntity(
          _adapter,
          chatEntry,
        );
        await _chatRepo.put(ChatSession.fromJson(chatData));
      }
      final cloudData = await SyncSerialization.readRequiredCloudEntity(
        _adapter,
        entry,
      );
      await store.mergeBySessionId(entry.id, cloudData);
    }
  }

  Future<Map<String, dynamic>?> _readLocalStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final pipelineSettings = prefs.getString(
      SyncSerialization.pipelineSettingsKey,
    );
    final activeStudioPresetId = prefs.getString(
      SyncSerialization.activeStudioPresetKey,
    );
    final globalRegexScripts = prefs.getString(
      SyncSerialization.globalRegexScriptsKey,
    );
    final studioRegexScripts = prefs.getString(
      SyncSerialization.studioRegexScriptsKey,
    );
    if (pipelineSettings == null &&
        activeStudioPresetId == null &&
        globalRegexScripts == null &&
        studioRegexScripts == null) {
      return null;
    }
    return SyncSerialization.localStoragePayload(
      pipelineSettings: pipelineSettings,
      activeStudioPresetId: activeStudioPresetId,
      globalRegexScripts: globalRegexScripts,
      studioRegexScripts: studioRegexScripts,
    );
  }

  Future<void> _applyLocalStorage(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final pipelineSettings = data[SyncSerialization.pipelineSettingsKey];
    if (pipelineSettings is String) {
      if (pipelineSettings.isEmpty) {
        await prefs.remove(SyncSerialization.pipelineSettingsKey);
      } else {
        await prefs.setString(
          SyncSerialization.pipelineSettingsKey,
          pipelineSettings,
        );
      }
    }
    final activeStudioPresetId = data[SyncSerialization.activeStudioPresetKey];
    if (activeStudioPresetId is String) {
      if (activeStudioPresetId.isEmpty) {
        await prefs.remove(SyncSerialization.activeStudioPresetKey);
      } else {
        await prefs.setString(
          SyncSerialization.activeStudioPresetKey,
          activeStudioPresetId,
        );
      }
    }
    await _applyLocalStorageString(
      prefs,
      data,
      SyncSerialization.globalRegexScriptsKey,
    );
    await _applyLocalStorageString(
      prefs,
      data,
      SyncSerialization.studioRegexScriptsKey,
    );
  }

  Future<void> _applyLocalStorageString(
    SharedPreferences prefs,
    Map<String, dynamic> data,
    String key,
  ) async {
    final value = data[key];
    if (value is! String) return;
    if (value.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }

  Future<void> _deleteLocalStorage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(SyncSerialization.pipelineSettingsKey);
    await prefs.remove(SyncSerialization.activeStudioPresetKey);
    await prefs.remove(SyncSerialization.globalRegexScriptsKey);
    await prefs.remove(SyncSerialization.studioRegexScriptsKey);
  }
}
