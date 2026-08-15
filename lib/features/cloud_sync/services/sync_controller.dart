import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/character_provider.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/chat_session_ops_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';
import '../../../shared/theme/theme_provider.dart';
import '../../personas/persona_list_provider.dart';
import '../../settings/api_list_provider.dart';
import '../../chat_history/chat_history_provider.dart';
import '../sync_provider.dart';
import '../sync_models.dart';
import 'sync_engine.dart';
import 'sync_service.dart';
import 'sync_conflict.dart';

/// Controller for cloud sync operations, separating business logic from UI.
class SyncController {
  final WidgetRef _ref;
  final bool Function() isMounted;

  bool _isConnecting = false;
  bool _isConnectingGdrive = false;
  bool _isDisconnecting = false;
  bool _isWiping = false;
  Map<String, dynamic>? _syncResult;
  bool _syncIncludeApiKeys = false;
  String? _gdriveFolderId;

  SyncController(this._ref, {required this.isMounted});

  bool get isConnecting => _isConnecting;
  bool get isConnectingGdrive => _isConnectingGdrive;
  bool get isDisconnecting => _isDisconnecting;
  bool get isWiping => _isWiping;
  Map<String, dynamic>? get syncResult => _syncResult;
  bool get syncIncludeApiKeys => _syncIncludeApiKeys;
  String? get gdriveFolderId => _gdriveFolderId;

  Future<void> loadIncludeApiKeys() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final raw = prefs.get('gz_sync_include_api_keys');
    _syncIncludeApiKeys = raw is bool ? raw : false;
  }

  Future<void> setIncludeApiKeys(bool val) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    if (prefs.get('gz_sync_include_api_keys') is! bool) {
      await prefs.remove('gz_sync_include_api_keys');
    }
    await prefs.setBool('gz_sync_include_api_keys', val);
    _syncIncludeApiKeys = val;
  }

  Future<void> resolveFolderIdIfNeeded() async {
    final service = _ref.read(syncServiceProvider).value;
    if (service != null &&
        service.provider == SyncProvider.gdrive &&
        service.isConnected()) {
      if (service.gdriveFolderId != null) {
        _gdriveFolderId = service.gdriveFolderId;
      } else {
        _gdriveFolderId = await service.resolveGDriveFolderId();
      }
    }
  }

  void initStateFromService() {
    final service = _ref.read(syncServiceProvider).value;
    if (service != null) {
      _ref.read(syncStatusProvider.notifier).state = service.status;
      _ref.read(syncConnectedProvider.notifier).state = service.isConnected();
      _ref.read(syncProviderProvider.notifier).state = service.provider;
      _ref.read(syncAutoEnabledProvider.notifier).state =
          service.autoSyncEnabled;
    }
  }

  /// Returns error message or null on success.
  Future<String?> connectDropbox() async {
    _isConnecting = true;
    try {
      final service = await _ref.read(syncServiceProvider.future);
      await service.connectDropbox();
      _ref.read(syncConnectedProvider.notifier).state = true;
      _ref.read(syncProviderProvider.notifier).state = SyncProvider.dropbox;
      _ref.read(syncStatusProvider.notifier).state = service.status;
      _ref.read(syncLastErrorProvider.notifier).state = null;
      await resolveFolderIdIfNeeded();
      return null;
    } catch (e) {
      return 'Dropbox connection failed: $e';
    } finally {
      _isConnecting = false;
    }
  }

  Future<String?> connectGDrive() async {
    _isConnectingGdrive = true;
    try {
      final service = await _ref.read(syncServiceProvider.future);
      await service.connectGDrive();
      _ref.read(syncConnectedProvider.notifier).state = true;
      _ref.read(syncProviderProvider.notifier).state = SyncProvider.gdrive;
      _ref.read(syncStatusProvider.notifier).state = service.status;
      _ref.read(syncLastErrorProvider.notifier).state = null;
      await resolveFolderIdIfNeeded();
      return null;
    } catch (e) {
      return 'Google Drive connection failed: $e';
    } finally {
      _isConnectingGdrive = false;
    }
  }

  Future<String?> disconnect() async {
    final service = _ref.read(syncServiceProvider).value;
    if (service == null) return null;

    _isDisconnecting = true;
    try {
      await service.disconnect();
      _ref.read(syncConnectedProvider.notifier).state = false;
      _ref.read(syncProviderProvider.notifier).state = SyncProvider.dropbox;
      _ref.read(syncStatusProvider.notifier).state = service.status;
      _syncResult = null;
      _gdriveFolderId = null;
      return null;
    } catch (e) {
      return 'Disconnect failed: $e';
    } finally {
      _isDisconnecting = false;
    }
  }

  /// Returns a result map or throws.
  Future<Map<String, dynamic>?> wipeCloudData({
    required void Function(SyncProgress p) onProgress,
    required String providerLabel,
  }) async {
    final service = _ref.read(syncServiceProvider).value;
    if (service == null) return null;
    final statusNotifier = _ref.read(syncStatusProvider.notifier);
    final progressNotifier = _ref.read(syncProgressProvider.notifier);

    _isWiping = true;
    _syncResult = null;
    statusNotifier.state = SyncStatus.syncing;

    try {
      await service.wipeCloudData(onProgress: onProgress);
      statusNotifier.state = service.status;
      _syncResult = {'type': 'wipe', 'total': 'all'};
      return _syncResult;
    } catch (e) {
      statusNotifier.state = SyncStatus.error;
      rethrow;
    } finally {
      _isWiping = false;
      progressNotifier.state = null;
      statusNotifier.state = service.status;
    }
  }

  Future<String?> doSync(String mode) async {
    final statusNotifier = _ref.read(syncStatusProvider.notifier);
    final lastErrorNotifier = _ref.read(syncLastErrorProvider.notifier);
    final progressNotifier = _ref.read(syncProgressProvider.notifier);
    final conflictsNotifier = _ref.read(syncConflictsProvider.notifier);

    statusNotifier.state = SyncStatus.syncing;
    lastErrorNotifier.state = null;
    _syncResult = null;

    int itemsCount = 0;
    late final SyncService service;
    var serviceReady = false;
    try {
      service = await _ref.read(syncServiceProvider.future);
      serviceReady = true;
      switch (mode) {
        case 'push':
          await service.fullPush(
            includeApiKeys: _syncIncludeApiKeys,
            onProgress: (p) {
              if (isMounted()) progressNotifier.state = p;
              itemsCount = p.total;
            },
          );
          _syncResult = {'type': 'push', 'pushed': itemsCount};
          statusNotifier.state = service.status;
          conflictsNotifier.state = service.conflicts;
          return 'Push completed ($itemsCount items)';

        case 'pull':
          await service.fullPull(
            onProgress: (p) {
              if (isMounted()) progressNotifier.state = p;
              itemsCount = p.total;
            },
          );
          _syncResult = {
            'type': 'pull',
            'pulled': itemsCount,
            'conflictsCount': service.conflicts.length,
          };
          invalidateDataProviders();
          statusNotifier.state = service.status;
          conflictsNotifier.state = service.conflicts;
          if (service.conflicts.isNotEmpty) {
            return 'Pull completed with ${service.conflicts.length} conflicts';
          }
          return 'Pull completed ($itemsCount items)';

        case 'full':
          await service.fullSync(
            includeApiKeys: _syncIncludeApiKeys,
            onProgress: (p) {
              if (isMounted()) progressNotifier.state = p;
              itemsCount = p.total;
            },
          );
          _syncResult = {'type': 'full'};
          invalidateDataProviders();
          statusNotifier.state = service.status;
          conflictsNotifier.state = service.conflicts;
          return 'sync_full_done'.tr();
      }
    } catch (e) {
      lastErrorNotifier.state = e.toString();
      statusNotifier.state = serviceReady ? service.status : SyncStatus.error;
      conflictsNotifier.state = serviceReady ? service.conflicts : const [];
      return 'Sync failed: $e';
    } finally {
      progressNotifier.state = null;
    }
    return null;
  }

  Future<String?> resolveConflict(SyncConflict conflict, String choice) async {
    final service = _ref.read(syncServiceProvider).value;
    if (service == null) return null;
    final conflictsNotifier = _ref.read(syncConflictsProvider.notifier);
    final errorNotifier = _ref.read(syncLastErrorProvider.notifier);
    final statusNotifier = _ref.read(syncStatusProvider.notifier);
    final progressNotifier = _ref.read(syncProgressProvider.notifier);

    // Optimistically remove from UI immediately — the user should not wait
    // for a manifest-rewrite before seeing the conflict row disappear.
    final optimistic = _ref
        .read(syncConflictsProvider)
        .where((c) => c.key != conflict.key)
        .toList();
    conflictsNotifier.state = optimistic;
    statusNotifier.state = SyncStatus.syncing;

    try {
      await service.resolveConflict(conflict, choice);
      // Sync provider state with service truth (in case of partial failure).
      conflictsNotifier.state = List.from(service.conflicts);

      if (service.conflicts.isEmpty) {
        return await _applyPendingPullAndFinalize(
          service,
          setStatus: (value) => statusNotifier.state = value,
          setProgress: (value) => progressNotifier.state = value,
          setError: (value) => errorNotifier.state = value,
        );
      }
      statusNotifier.state = SyncStatus.conflict;
      return null;
    } catch (e) {
      // Roll back optimistic removal on error.
      conflictsNotifier.state = List.from(service.conflicts);
      errorNotifier.state = e.toString();
      statusNotifier.state = service.status;
      return 'Could not resolve conflict: $e';
    }
  }

  Future<String?> resolveAllConflicts(String choice) async {
    final service = _ref.read(syncServiceProvider).value;
    if (service == null) return null;
    final conflictsNotifier = _ref.read(syncConflictsProvider.notifier);
    final errorNotifier = _ref.read(syncLastErrorProvider.notifier);
    final statusNotifier = _ref.read(syncStatusProvider.notifier);
    final progressNotifier = _ref.read(syncProgressProvider.notifier);
    // Optimistically clear all conflict rows immediately.
    conflictsNotifier.state = [];
    statusNotifier.state = SyncStatus.syncing;
    try {
      await service.resolveAllConflicts(choice);
      conflictsNotifier.state = List.from(service.conflicts);
      return await _applyPendingPullAndFinalize(
        service,
        setStatus: (value) => statusNotifier.state = value,
        setProgress: (value) => progressNotifier.state = value,
        setError: (value) => errorNotifier.state = value,
      );
    } catch (e) {
      errorNotifier.state = e.toString();
      conflictsNotifier.state = List.from(service.conflicts);
      statusNotifier.state = service.status;
      return 'Could not resolve conflicts: $e';
    }
  }

  /// Called after all conflicts are resolved. Applies the pending pull,
  /// shows progress, invalidates data providers, and returns a toast message.
  Future<String?> _applyPendingPullAndFinalize(
    SyncService service, {
    required void Function(SyncStatus value) setStatus,
    required void Function(SyncProgress? value) setProgress,
    required void Function(String? value) setError,
  }) async {
    setStatus(SyncStatus.syncing);
    try {
      await service.applyPendingPullAfterResolve(
        onProgress: (p) {
          setProgress(p);
        },
      );
      if (isMounted()) invalidateDataProviders();
      return 'Sync complete';
    } catch (e) {
      setError(e.toString());
      return 'Sync failed: $e';
    } finally {
      setStatus(service.status);
      setProgress(null);
    }
  }

  void invalidateDataProviders() {
    // Evict all cached avatar images so that Image.file widgets re-read the
    // updated files from disk immediately (without a full app restart).
    _evictAvatarImageCache();

    _ref.invalidate(charactersProvider);
    _ref.invalidate(personaListProvider);
    _ref.invalidate(apiListProvider);
    _ref.invalidate(lorebooksProvider);
    _ref.invalidate(chatSessionOpsProvider);
    _ref.invalidate(chatHistoryProvider);
    _ref.invalidate(activeStudioPresetProvider);
    _ref.invalidate(studioPresetProvider);
    _ref.read(themeProvider.notifier).reload();

    // Bump the version counter so widgets that watch avatarVersionProvider
    // (chat_header, character_list) rebuild and pick up the new paths.
    bumpAvatarVersion(_ref);
  }

  void _evictAvatarImageCache() {
    try {
      // Collect avatar paths from characters currently in the provider.
      final chars = _ref.read(charactersProvider).value ?? [];
      for (final c in chars) {
        if (c.avatarPath != null && c.avatarPath!.isNotEmpty) {
          FileImage(File(c.avatarPath!)).evict();
        }
      }
      // Also clear live images (includes images whose path hasn't changed but
      // whose bytes on disk have been replaced by the sync pull).
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
  }

  Future<void> setAutoSync(bool val) async {
    final service = _ref.read(syncServiceProvider).value;
    if (service != null) {
      await service.setAutoSync(
        val,
        messageCount: service.autoSyncMessageCount,
      );
      _ref.read(syncAutoEnabledProvider.notifier).state = val;
    }
  }

  Future<void> updateAutoSyncThreshold(int count) async {
    final service = _ref.read(syncServiceProvider).value;
    if (service != null) {
      await service.setAutoSync(service.autoSyncEnabled, messageCount: count);
    }
  }
}
