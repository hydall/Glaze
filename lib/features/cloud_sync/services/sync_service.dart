import 'dart:convert';

// ignore_for_file: prefer_initializing_formals

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/generation_notification_service.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/application/session_deletion_store.dart';
import '../../../core/application/character_deletion_store.dart';
import '../sync_repo_interfaces.dart';
import 'dropbox/dropbox_adapter.dart';
import 'dropbox/dropbox_auth.dart';
import 'gdrive/gdrive_adapter.dart';
import 'gdrive/gdrive_auth.dart';
import 'sync_conflict.dart';
import 'sync_engine.dart';
import 'sync_manifest.dart';
import '../cloud_adapter.dart';
import '../sync_models.dart';

class SyncService {
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
  final SessionDeletionStore _sessionDeletionStore;
  final CharacterDeletionStore _characterDeletionStore;
  final Future<void> Function(LorebookActivations) _saveLorebookActivations;

  SyncProvider _provider = SyncProvider.dropbox;
  SyncStatus _status = SyncStatus.idle;
  String? _lastError;
  int? _lastSyncTime;
  final List<SyncConflict> _conflicts = [];
  final List<String> _resolvedAsCloud = [];
  bool _resolvedAsLocal = false;
  Map<String, dynamic>? _accountInfo;
  bool _autoSyncEnabled = false;
  int _autoSyncMessageCount = 5;
  int _messageCounter = 0;

  final DropboxAuth _dropboxAuth = DropboxAuth();
  final GDriveAuth _gdriveAuth = GDriveAuth();

  SyncProvider get provider => _provider;
  SyncStatus get status => _status;
  String? get lastError => _lastError;
  int? get lastSyncTime => _lastSyncTime;
  List<SyncConflict> get conflicts => _conflicts;
  Map<String, dynamic>? get accountInfo => _accountInfo;
  bool get autoSyncEnabled => _autoSyncEnabled;
  int get autoSyncMessageCount => _autoSyncMessageCount;
  bool get isSyncing => _status == SyncStatus.syncing;
  bool get hasConflicts => _conflicts.isNotEmpty;

  String? get gdriveFolderId {
    if (_provider != SyncProvider.gdrive) return null;
    final adapter = _adapter;
    if (adapter is GDriveAdapter) {
      return adapter.glazeFolderId;
    }
    return null;
  }

  Future<String?> resolveGDriveFolderId() async {
    if (_provider != SyncProvider.gdrive) return null;
    final adapter = _adapter;
    if (adapter is GDriveAdapter) {
      return await adapter.getGlazeFolderId();
    }
    return null;
  }

  SyncService({
    required this._characterRepo,
    required this._chatRepo,
    required this._personaRepo,
    required this._presetRepo,
    required this._apiRepo,
    required this._memoryBookRepo,
    required this._lorebookRepo,
    required this._embeddingRepo,
    required this._imageStorage,
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
    this._reconciliationStateStore,
    required SessionDeletionStore sessionDeletionStore,
    required CharacterDeletionStore characterDeletionStore,
    required Future<void> Function(LorebookActivations) saveLorebookActivations,
  }) : _sessionDeletionStore = sessionDeletionStore,
       _characterDeletionStore = characterDeletionStore,
       _saveLorebookActivations = saveLorebookActivations;

  CloudAdapter get _adapter {
    switch (_provider) {
      case SyncProvider.dropbox:
        return DropboxAdapter(_dropboxAuth);
      case SyncProvider.gdrive:
        return GDriveAdapter(_gdriveAuth);
    }
  }

  SyncManifestBuilder get _manifestBuilder => SyncManifestBuilder(
    characterRepo: _characterRepo,
    chatRepo: _chatRepo,
    personaRepo: _personaRepo,
    presetRepo: _presetRepo,
    apiRepo: _apiRepo,
    memoryBookRepo: _memoryBookRepo,
    lorebookRepo: _lorebookRepo,
    themePresetRepo: _themePresetRepo,
    extensionPresetRepo: _extensionPresetRepo,
    extensionsSettingsStore: _extensionsSettingsStore,
    infoBlockStore: _infoBlockStore,
    trackerSnapshotStore: _trackerSnapshotStore,
    trackerValueStore: _trackerValueStore,
    studioConfigStore: _studioConfigStore,
    studioPresetStore: _studioPresetStore,
    chatSummaryStore: _chatSummaryStore,
    characterFolderStore: _characterFolderStore,
    memoryGraphStore: _memoryGraphStore,
    characterKnowledgeStore: _characterKnowledgeStore,
    reconciliationStateStore: _reconciliationStateStore,
    imageStore: _imageStorage,
  );

  SyncEngine get _engine => SyncEngine(
    _adapter,
    _manifestBuilder,
    _characterRepo,
    _chatRepo,
    _personaRepo,
    _presetRepo,
    _apiRepo,
    _memoryBookRepo,
    _lorebookRepo,
    _embeddingRepo,
    _imageStorage,
    _themePresetRepo,
    _extensionPresetRepo,
    _extensionsSettingsStore,
    _infoBlockStore,
    _trackerSnapshotStore,
    _trackerValueStore,
    _studioConfigStore,
    _studioPresetStore,
    _chatSummaryStore,
    _characterFolderStore,
    _memoryGraphStore,
    _characterKnowledgeStore,
    _sessionDeletionStore,
    _characterDeletionStore,
    _saveLorebookActivations,
    _reconciliationStateStore,
  );

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final providerStr = prefs.getString('gz_sync_provider');
    if (providerStr == 'gdrive') _provider = SyncProvider.gdrive;
    _autoSyncEnabled = prefs.getBool('gz_sync_auto') ?? false;
    _autoSyncMessageCount = prefs.getInt('gz_sync_auto_count') ?? 5;
    _lastSyncTime = prefs.getInt('gz_sync_last');

    final tokensRaw = prefs.getString('gz_sync_tokens');
    if (tokensRaw != null) {
      final tokens = jsonDecode(tokensRaw) as Map<String, dynamic>;
      _dropboxAuth.loadTokens(tokens);
      _gdriveAuth.loadTokens(tokens);
    }

    _accountInfo = await _adapter.getAccountInfo();
  }

  Future<void> setProvider(SyncProvider p) async {
    _provider = p;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gz_sync_provider', p.name);
    _accountInfo = await _adapter.getAccountInfo();
  }

  Future<void> fullPush({
    void Function(SyncProgress)? onProgress,
    bool includeApiKeys = false,
  }) async {
    await _withSyncForeground(() async {
      _status = SyncStatus.syncing;
      _lastError = null;

      try {
        final engine = _engine;
        await engine.pushEntities(
          onProgress: onProgress ?? (_) {},
          includeApiKeys: includeApiKeys,
        );
        _lastSyncTime = DateTime.now().millisecondsSinceEpoch;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('gz_sync_last', _lastSyncTime!);
        _status = SyncStatus.idle;
      } catch (e) {
        _lastError = e.toString();
        _status = SyncStatus.error;
        rethrow;
      }
    });
  }

  Future<void> fullPull({void Function(SyncProgress)? onProgress}) async {
    await _withSyncForeground(() async {
      _status = SyncStatus.syncing;
      _lastError = null;
      _conflicts.clear();
      _resolvedAsCloud.clear();
      _resolvedAsLocal = false;

      try {
        final engine = _engine;
        await engine.pullEntities(
          onProgress: onProgress ?? (_) {},
          onConflict: (c) => _conflicts.add(c),
        );
        if (_conflicts.isNotEmpty) {
          _status = SyncStatus.conflict;
        } else {
          _lastSyncTime = DateTime.now().millisecondsSinceEpoch;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('gz_sync_last', _lastSyncTime!);
          _status = SyncStatus.idle;
        }
      } catch (e) {
        _lastError = e.toString();
        _status = SyncStatus.error;
        rethrow;
      }
    });
  }

  Future<void> fullSync({
    void Function(SyncProgress)? onProgress,
    bool includeApiKeys = false,
  }) async {
    await fullPush(onProgress: onProgress, includeApiKeys: includeApiKeys);
    if (_status != SyncStatus.error) {
      await fullPull(onProgress: onProgress);
    }
  }

  Future<void> wipeCloudData({void Function(SyncProgress)? onProgress}) async {
    if (_status == SyncStatus.syncing) return;
    await _withSyncForeground(() async {
      _status = SyncStatus.syncing;
      _lastError = null;

      try {
        final engine = _engine;
        await engine.wipeCloudData(onProgress: onProgress ?? (_) {});
        await _manifestBuilder.clearLocalManifest();
        _conflicts.clear();
        _resolvedAsCloud.clear();
        _status = SyncStatus.idle;
      } catch (e) {
        _lastError = e.toString();
        _status = SyncStatus.error;
        rethrow;
      }
    });
  }

  Future<void> resolveAllConflicts(String choice) async {
    if (_conflicts.isEmpty) return;
    final conflicts = List<SyncConflict>.from(_conflicts);
    try {
      for (final conflict in conflicts) {
        await _engine.resolveConflict(conflict, choice);
        if (choice == 'cloud') {
          _resolvedAsCloud.add(conflict.key);
        } else {
          _resolvedAsLocal = true;
        }
      }
      _conflicts.clear();
    } catch (e) {
      _lastError = e.toString();
      _status = SyncStatus.error;
      rethrow;
    }
  }

  /// Records the conflict resolution choice (updates manifest, tracks
  /// cloud-resolved keys). Does NOT trigger a pull — call [applyPendingPull]
  /// once all conflicts have been resolved.
  Future<void> resolveConflict(SyncConflict conflict, String choice) async {
    try {
      await _engine.resolveConflict(conflict, choice);
      if (choice == 'cloud') {
        _resolvedAsCloud.add(conflict.key);
      } else {
        _resolvedAsLocal = true;
      }
      _conflicts.removeWhere((c) => c.key == conflict.key);
    } catch (e) {
      _lastError = e.toString();
      _status = SyncStatus.error;
      rethrow;
    }
  }

  /// Applies the pending pull after all conflicts have been resolved.
  /// Should be called by the controller once [conflicts] is empty.
  Future<void> applyPendingPullAfterResolve({
    required void Function(SyncProgress) onProgress,
  }) async {
    await _withSyncForeground(() async {
      try {
        _status = SyncStatus.syncing;
        await _engine.applyPendingPull(
          onProgress: onProgress,
          resolvedAsCloud: _resolvedAsCloud.isNotEmpty
              ? List.from(_resolvedAsCloud)
              : null,
          pushLocalChanges: _resolvedAsLocal,
        );
        _resolvedAsCloud.clear();
        _resolvedAsLocal = false;
        _lastSyncTime = DateTime.now().millisecondsSinceEpoch;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('gz_sync_last', _lastSyncTime!);
        _status = SyncStatus.idle;
      } catch (e) {
        _lastError = e.toString();
        _status = SyncStatus.error;
        rethrow;
      }
    });
  }

  Future<void> _withSyncForeground(Future<void> Function() action) async {
    await GenerationNotificationService.instance.onSyncStarted();
    try {
      await action();
    } finally {
      await GenerationNotificationService.instance.onSyncFinished();
    }
  }

  Future<void> connectDropbox() async {
    await _dropboxAuth.connect();
    await _saveTokens();
    _accountInfo = await _adapter.getAccountInfo();
  }

  Future<void> connectGDrive() async {
    await _gdriveAuth.connect();
    await _saveTokens();
    _accountInfo = await _adapter.getAccountInfo();
  }

  Future<void> disconnect() async {
    switch (_provider) {
      case SyncProvider.dropbox:
        await _dropboxAuth.disconnect();
        break;
      case SyncProvider.gdrive:
        await _gdriveAuth.disconnect();
        break;
    }
    _accountInfo = null;
    _conflicts.clear();
    _resolvedAsCloud.clear();
    _lastSyncTime = null;
    _status = SyncStatus.idle;
    await _manifestBuilder.clearLocalManifest();
    await _saveTokens();
  }

  Future<void> setAutoSync(bool enabled, {int messageCount = 5}) async {
    _autoSyncEnabled = enabled;
    _autoSyncMessageCount = messageCount;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('gz_sync_auto', enabled);
    await prefs.setInt('gz_sync_auto_count', messageCount);
  }

  Future<void> incrementMessageCounter() async {
    if (!_autoSyncEnabled) return;
    _messageCounter++;
    if (_messageCounter >= _autoSyncMessageCount) {
      _messageCounter = 0;
      await fullPush();
    }
  }

  bool isConnected() {
    switch (_provider) {
      case SyncProvider.dropbox:
        return _dropboxAuth.isConnected;
      case SyncProvider.gdrive:
        return _gdriveAuth.isConnected;
    }
  }

  Future<void> _saveTokens() async {
    final prefs = await SharedPreferences.getInstance();
    final dbTokens = _dropboxAuth.saveTokens();
    final gdTokens = _gdriveAuth.saveTokens();
    final merged = <String, dynamic>{};
    if (dbTokens != null) merged.addAll(dbTokens);
    if (gdTokens != null) merged.addAll(gdTokens);
    await prefs.setString('gz_sync_tokens', jsonEncode(merged));
  }
}
