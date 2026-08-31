import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/core/utils/sync_deletion_tracker.dart';
import 'package:glaze_flutter/core/application/session_deletion_store.dart';
import 'package:glaze_flutter/core/application/character_deletion_store.dart';
import 'package:glaze_flutter/features/cloud_sync/adapters/ext_blocks_sync_stores.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_repo_interfaces.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_manifest.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_queue.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/extensions_settings.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── In-memory fakes ────────────────────────────────────────────────

class FakeCharacterStore implements SyncCharacterStore {
  final Map<String, Character> data = {};

  @override
  Future<List<Character>> getAll() async => data.values.toList();

  @override
  Future<Character?> getById(String id) async => data[id];

  @override
  Future<void> put(Character c) async {
    data[c.id] = c;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class FakeChatStore implements SyncChatStore {
  final Map<String, ChatSession> data = {};
  Duration putDelay = Duration.zero;

  @override
  Future<List<SessionMetadata>> getAllSessionMetadata() async {
    return data.values
        .map(
          (s) => SessionMetadata(
            sessionId: s.id,
            characterId: s.characterId,
            sessionIndex: s.sessionIndex,
            updatedAt: s.updatedAt,
            messageCount: s.messages.length,
            lastMessageContent: '',
            lastMessageTimestamp: 0,
          ),
        )
        .toList();
  }

  @override
  Future<ChatSession?> getById(String id) async => data[id];

  @override
  Future<void> put(ChatSession s) async {
    if (putDelay > Duration.zero) await Future<void>.delayed(putDelay);
    data[s.id] = s;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class FakeSessionDeletionStore implements SessionDeletionStore {
  final FakeChatStore chats;
  final List<String> deletedSessionIds = [];

  FakeSessionDeletionStore(this.chats);

  @override
  Future<void> deleteSession(String sessionId) async {
    deletedSessionIds.add(sessionId);
    await chats.delete(sessionId);
  }
}

class NoopSessionDeletionStore implements SessionDeletionStore {
  const NoopSessionDeletionStore();

  @override
  Future<void> deleteSession(String sessionId) async {}
}

class FakeCharacterDeletionStore implements CharacterDeletionStore {
  final FakeCharacterStore characters;
  final List<Set<String>> deletedCharacterIds = [];

  FakeCharacterDeletionStore(this.characters);

  @override
  Future<CharacterDeletionResult> deleteCharacters(
    Set<String> characterIds,
  ) async {
    deletedCharacterIds.add(Set.of(characterIds));
    for (final id in characterIds) {
      await characters.delete(id);
    }
    return CharacterDeletionResult(
      characterIds: characterIds,
      sessionIds: const {},
      studioConfigSessionIds: const {},
      lorebookIds: const {},
    );
  }
}

class FakePersonaStore implements SyncPersonaStore {
  final Map<String, Persona> data = {};

  @override
  Future<List<Persona>> getAll() async => data.values.toList();

  @override
  Future<Persona?> getById(String id) async => data[id];

  @override
  Future<void> put(Persona p) async {
    data[p.id] = p;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class FakePresetStore implements SyncPresetStore {
  final Map<String, Preset> data = {};

  @override
  Future<List<Preset>> getAll() async => data.values.toList();

  @override
  Future<Preset?> getById(String id) async => data[id];

  @override
  Future<void> put(Preset p) async {
    data[p.id] = p;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class FakeApiConfigStore implements SyncApiConfigStore {
  final Map<String, ApiConfig> data = {};

  @override
  Future<List<ApiConfig>> getAll() async => data.values.toList();

  @override
  Future<ApiConfig?> getById(String id) async => data[id];

  @override
  Future<void> put(ApiConfig c) async {
    data[c.id] = c;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class FakeThemePresetStore implements SyncThemePresetStore {
  List<ThemePreset> data = [];

  @override
  Future<List<ThemePreset>> getAll() async => data;

  @override
  Future<void> putAll(List<ThemePreset> presets) async {
    data = List.from(presets);
  }
}

class FakeLorebookStore implements SyncLorebookStore {
  final Map<String, Lorebook> data = {};

  @override
  Future<List<Lorebook>> getAll() async => data.values.toList();

  @override
  Future<Lorebook?> getById(String id) async => data[id];

  @override
  Future<void> put(Lorebook l) async {
    data[l.id] = l;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class FakeMemoryBookStore implements SyncMemoryBookStore {
  final Map<String, MemoryBook> data = {};

  @override
  Future<List<MemoryBook>> getAll() async => data.values.toList();

  @override
  Future<MemoryBook?> getBySessionId(String sessionId) async => data[sessionId];

  @override
  Future<void> put(MemoryBook book) async {
    data[book.sessionId] = book;
  }

  @override
  Future<void> deleteBySessionId(String sessionId) async {
    data.remove(sessionId);
  }
}

class FakeEmbeddingStore implements SyncEmbeddingStore {
  final List<String> deletedIds = [];

  @override
  Future<void> deleteBySourceId(String sourceId) async {
    deletedIds.add(sourceId);
  }
}

class FakeExtensionPresetStore implements SyncExtensionPresetStore {
  final Map<String, ExtensionPreset> data = {};
  @override
  Future<List<ExtensionPreset>> getAll() async => data.values.toList();
  @override
  Future<ExtensionPreset?> getById(String id) async => data[id];
  @override
  Future<void> put(ExtensionPreset p) async {
    data[p.id] = p;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class FakeExtensionsSettingsStore implements SyncExtensionsSettingsStore {
  ExtensionsSettings _value = const ExtensionsSettings();
  @override
  Future<ExtensionsSettings> get() async => _value;
  @override
  Future<void> put(ExtensionsSettings s) async {
    _value = s;
  }
}

class FakeInfoBlockStore implements SyncInfoBlockStore {
  final Map<String, List<InfoBlock>> data = {};
  @override
  Future<List<String>> getAllSessionIds() async => data.keys.toList();
  @override
  Future<List<InfoBlock>> getBySessionId(String sid) async => data[sid] ?? [];
  @override
  Future<void> deleteBySessionId(String sid) async {
    data.remove(sid);
  }

  @override
  Future<void> insert(InfoBlock block) async {
    data.putIfAbsent(block.sessionId, () => []).add(block);
  }
}

class FakeTrackerSnapshotStore implements SyncTrackerSnapshotStore {
  final Map<String, List<Map<String, dynamic>>> data = {};
  @override
  Future<List<String>> getAllSessionIds() async => data.keys.toList();
  @override
  Future<List<Map<String, dynamic>>> getBySessionId(String sid) async =>
      data[sid] ?? [];
  @override
  Future<void> deleteBySessionId(String sid) async {
    data.remove(sid);
  }

  @override
  Future<void> insertRaw(Map<String, dynamic> snapshot) async {
    final sid = snapshot['sessionId'] as String? ?? '';
    data.putIfAbsent(sid, () => []).add(snapshot);
  }
}

class FakeTrackerValueStore implements SyncTrackerValueStore {
  final Map<String, List<Map<String, dynamic>>> data = {};
  @override
  Future<List<String>> getAllSessionIds() async => data.keys.toList();
  @override
  Future<List<Map<String, dynamic>>> getBySessionId(String sid) async =>
      data[sid] ?? [];
  @override
  Future<void> deleteBySessionId(String sid) async {
    data.remove(sid);
  }

  @override
  Future<void> insertRaw(Map<String, dynamic> tracker) async {
    final sid = tracker['sessionId'] as String? ?? '';
    data.putIfAbsent(sid, () => []).add(tracker);
  }
}

class FakeStudioConfigStore implements SyncStudioConfigStore {
  final Map<String, StudioConfig> data = {};
  @override
  Future<List<StudioConfig>> getAll() async => data.values.toList();
  @override
  Future<StudioConfig?> getById(String id) async => data[id];
  @override
  Future<void> put(StudioConfig config) async {
    data[config.sessionId] = config;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class FakeStudioPresetStore implements SyncStudioPresetStore {
  final Map<String, StudioPreset> data = {};
  @override
  Future<List<StudioPreset>> getAll() async => data.values.toList();
  @override
  Future<StudioPreset?> getById(String id) async => data[id];
  @override
  Future<void> put(StudioPreset preset) async {
    data[preset.id] = preset;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class FakeImageStore implements SyncImageStore {
  final Map<String, Uint8List> saved = {};

  @override
  String? absolutePath(String? relativePath) => relativePath;

  @override
  Future<String> saveBytes(
    Uint8List bytes,
    String subfolder,
    String filename,
    String ext,
  ) async {
    final key = '$subfolder/$filename.$ext';
    saved[key] = bytes;
    return key;
  }
}

class FakeReconciliationStateStore implements SyncReconciliationStateStore {
  final Map<String, Map<String, dynamic>> data = {};
  bool discardCollectors = false;
  bool discardAll = false;
  Future<void> Function(String sessionId)? beforeMerge;

  @override
  Future<List<String>> getAllSessionIds() async => data.keys.toList();

  @override
  Future<Map<String, dynamic>?> getBySessionId(String sessionId) async =>
      data[sessionId];

  @override
  Future<Map<String, dynamic>> mergeBySessionId(
    String sessionId,
    Map<String, dynamic> incoming,
  ) async {
    await beforeMerge?.call(sessionId);
    if (discardAll) {
      data.remove(sessionId);
      return {};
    }
    final merged = {...?data[sessionId], ...incoming};
    if (discardCollectors) merged['collectors'] = <dynamic>[];
    data[sessionId] = merged;
    return merged;
  }

  @override
  Future<void> deleteBySessionId(String sessionId) async {
    data.remove(sessionId);
  }
}

class FakeSessionLorebookOverlayStore
    implements SyncSessionLorebookOverlayStore {
  final Map<String, Map<String, dynamic>> data = {};
  Future<void> Function(String sessionId)? beforeApply;

  @override
  Future<List<String>> getAllSessionIds() async => data.keys.toList()..sort();

  @override
  Future<Map<String, dynamic>?> getBySessionId(String sessionId) async =>
      data[sessionId];

  @override
  Future<void> applyBySessionId(
    String sessionId,
    Map<String, dynamic> incoming,
  ) async {
    await beforeApply?.call(sessionId);
    data[sessionId] = Map<String, dynamic>.from(incoming);
  }

  @override
  Future<void> deleteBySessionId(String sessionId) async {
    data.remove(sessionId);
  }
}

class FakeCloudAdapter implements CloudAdapter {
  final Map<String, String> files = {};
  final List<String> listFolderCalls = [];
  final Set<String> ensuredFolders = {};
  final Set<String> downloadFailures = {};

  /// When true, [listFolder] returns paths without the `/Glaze` prefix (Dropbox-style).
  bool stripGlazePrefixInList = false;
  bool omitFilesFromList = false;
  bool listFolderThrows = false;
  final Set<String> listFolderFailures = {};
  bool requireEnsuredParentForUpload = false;
  final uploadFailures = <String>{};

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<void> ensureFolder(String path) async {
    ensuredFolders.add(path);
  }

  void _checkUploadParent(String path) {
    if (!requireEnsuredParentForUpload) return;
    final slash = path.lastIndexOf('/');
    if (slash <= 0) return;
    final parent = path.substring(0, slash);
    if (!ensuredFolders.contains(parent)) {
      throw Exception('Parent folder not ensured: $parent');
    }
  }

  @override
  Future<void> upload(String path, String data) async {
    _checkUploadParent(path);
    if (uploadFailures.contains(path)) {
      throw Exception('Upload failed: $path');
    }
    files[path] = data;
  }

  @override
  Future<void> uploadBinary(String path, Uint8List data) async {
    _checkUploadParent(path);
    files[path] = String.fromCharCodes(data);
  }

  @override
  Future<String> download(String path) async {
    if (downloadFailures.contains(path)) {
      throw Exception('Download failed: $path');
    }
    final data = files[path];
    if (data == null) throw CloudFileNotFoundException(path);
    return data;
  }

  @override
  Future<Uint8List> downloadBinary(String path) async {
    final data = files[path];
    if (data == null) throw Exception('File not found: $path');
    return Uint8List.fromList(data.codeUnits);
  }

  @override
  Future<void> deleteFile(String path) async {
    files.remove(path);
  }

  @override
  Future<void> deleteFolder(String path) async {
    files.removeWhere((k, _) => k.startsWith(path));
  }

  @override
  Future<List<CloudFileInfo>> listFolder(String path) async {
    listFolderCalls.add(path);
    if (listFolderThrows || listFolderFailures.contains(path)) {
      throw Exception('listFolder failed: $path');
    }
    if (omitFilesFromList) return [];
    return files.keys.where((k) => k.startsWith(path) && !k.endsWith('/')).map((
      k,
    ) {
      final listedPath = stripGlazePrefixInList && k.startsWith('$cloudBase/')
          ? k.substring(cloudBase.length)
          : k;
      return CloudFileInfo(
        path: listedPath,
        name: k.split('/').last,
        isFolder: false,
      );
    }).toList();
  }

  @override
  Future<Map<String, dynamic>?> getAccountInfo() async => {};

  @override
  Future<void> invalidateFolderCache() async {}
}

// ─── In-memory manifest provider (no SharedPreferences needed) ──────

class InMemoryManifestProvider implements SyncManifestProvider {
  final SyncManifestBuilder _builder;
  SyncManifest _cached = const SyncManifest(deviceId: '', createdAt: 0);
  final Map<String, String> _storage = {};

  InMemoryManifestProvider({
    required SyncCharacterStore characterRepo,
    required SyncChatStore chatRepo,
    required SyncPersonaStore personaRepo,
    required SyncPresetStore presetRepo,
    required SyncApiConfigStore apiRepo,
    required SyncMemoryBookStore memoryBookRepo,
    required SyncLorebookStore lorebookRepo,
    required SyncThemePresetStore themePresetRepo,
    SyncExtensionPresetStore? extensionPresetRepo,
    SyncExtensionsSettingsStore? extensionsSettingsStore,
    SyncInfoBlockStore? infoBlockStore,
    SyncTrackerSnapshotStore? trackerSnapshotStore,
    SyncTrackerValueStore? trackerValueStore,
    SyncStudioConfigStore? studioConfigStore,
    SyncStudioPresetStore? studioPresetStore,
    SyncSessionLorebookOverlayStore? sessionLorebookOverlayStore,
    SyncReconciliationStateStore? reconciliationStateStore,
  }) : _builder = SyncManifestBuilder(
         characterRepo: characterRepo,
         chatRepo: chatRepo,
         personaRepo: personaRepo,
         presetRepo: presetRepo,
         apiRepo: apiRepo,
         memoryBookRepo: memoryBookRepo,
         lorebookRepo: lorebookRepo,
         themePresetRepo: themePresetRepo,
         extensionPresetRepo: extensionPresetRepo ?? FakeExtensionPresetStore(),
         extensionsSettingsStore:
             extensionsSettingsStore ?? FakeExtensionsSettingsStore(),
         infoBlockStore: infoBlockStore ?? FakeInfoBlockStore(),
         trackerSnapshotStore:
             trackerSnapshotStore ?? FakeTrackerSnapshotStore(),
         trackerValueStore: trackerValueStore ?? FakeTrackerValueStore(),
         studioConfigStore: studioConfigStore ?? FakeStudioConfigStore(),
         studioPresetStore: studioPresetStore,
         sessionLorebookOverlayStore: sessionLorebookOverlayStore,
         reconciliationStateStore: reconciliationStateStore,
       );

  @override
  Future<SyncManifest> buildLocalManifest({SyncManifest? cloudManifest}) async {
    // Sync in-memory storage → SharedPreferences so the builder's
    // readLocalManifest() sees the same manifest the tests wrote.
    final raw = _storage['manifest'];
    final prefs = await SharedPreferences.getInstance();
    if (raw != null) {
      await prefs.setString('gz_sync_manifest_v2', raw);
    } else {
      await prefs.remove('gz_sync_manifest_v2');
    }
    return _builder.buildLocalManifest(cloudManifest: cloudManifest);
  }

  @override
  Future<SyncManifest> readLocalManifest() async {
    final raw = _storage['manifest'];
    if (raw == null) return _cached;
    return SyncManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> writeLocalManifest(SyncManifest manifest) async {
    _cached = manifest;
    _storage['manifest'] = jsonEncode(manifest.toJson());
  }

  @override
  Future<void> clearLocalManifest() async {
    _cached = const SyncManifest(deviceId: '', createdAt: 0);
    _storage.remove('manifest');
  }

  @override
  Future<void> clearDeleted() async {}

  @override
  Future<bool> isDeleted(String type, String id) async => false;

  @override
  Future<String> getDeviceId() => _builder.getDeviceId();
}

// ─── Helper: build a complete in-memory environment ─────────────────

class SyncWorld {
  late final FakeCharacterStore characters;
  late final FakeChatStore chats;
  late final FakePersonaStore personas;
  late final FakePresetStore presets;
  late final FakeApiConfigStore apiConfigs;
  late final FakeMemoryBookStore memoryBooks;
  late final FakeLorebookStore lorebooks;
  late final FakeEmbeddingStore embeddings;
  late final FakeImageStore images;
  late final FakeCloudAdapter cloud;
  late final FakeThemePresetStore uiThemes;
  late final InMemoryManifestProvider manifestProvider;
  late final FakeStudioConfigStore studioConfigs;
  late final FakeStudioPresetStore studioPresets;
  late final FakeSessionDeletionStore sessionDeletions;
  late final FakeCharacterDeletionStore characterDeletions;
  late final FakeReconciliationStateStore? reconciliationStates;
  late final FakeSessionLorebookOverlayStore? sessionLorebookOverlays;

  SyncWorld({
    FakeReconciliationStateStore? reconciliationStateStore,
    FakeSessionLorebookOverlayStore? sessionLorebookOverlayStore,
  }) {
    characters = FakeCharacterStore();
    chats = FakeChatStore();
    personas = FakePersonaStore();
    presets = FakePresetStore();
    apiConfigs = FakeApiConfigStore();
    memoryBooks = FakeMemoryBookStore();
    lorebooks = FakeLorebookStore();
    embeddings = FakeEmbeddingStore();
    images = FakeImageStore();
    cloud = FakeCloudAdapter();
    uiThemes = FakeThemePresetStore();
    studioConfigs = FakeStudioConfigStore();
    studioPresets = FakeStudioPresetStore();
    sessionDeletions = FakeSessionDeletionStore(chats);
    characterDeletions = FakeCharacterDeletionStore(characters);
    reconciliationStates = reconciliationStateStore;
    sessionLorebookOverlays = sessionLorebookOverlayStore;
    manifestProvider = InMemoryManifestProvider(
      characterRepo: characters,
      chatRepo: chats,
      personaRepo: personas,
      presetRepo: presets,
      apiRepo: apiConfigs,
      memoryBookRepo: memoryBooks,
      lorebookRepo: lorebooks,
      themePresetRepo: uiThemes,
      studioConfigStore: studioConfigs,
      studioPresetStore: studioPresets,
      sessionLorebookOverlayStore: sessionLorebookOverlays,
      reconciliationStateStore: reconciliationStates,
    );
  }

  SyncEngine get engine => SyncEngine(
    cloud,
    manifestProvider,
    characters,
    chats,
    personas,
    presets,
    apiConfigs,
    memoryBooks,
    lorebooks,
    embeddings,
    images,
    uiThemes,
    FakeExtensionPresetStore(),
    FakeExtensionsSettingsStore(),
    FakeInfoBlockStore(),
    FakeTrackerSnapshotStore(),
    FakeTrackerValueStore(),
    studioConfigs,
    studioPresets,
    null,
    null,
    null,
    null,
    sessionDeletions,
    characterDeletions,
    (_) async {},
    reconciliationStates,
    sessionLorebookOverlays,
  );
}

SyncEngine _realStoreEngine({
  required SyncChatStore chatStore,
  required SyncReconciliationStateStore reconciliationStore,
  required FakeCloudAdapter cloud,
}) {
  final characters = FakeCharacterStore();
  final personas = FakePersonaStore();
  final presets = FakePresetStore();
  final apiConfigs = FakeApiConfigStore();
  final memoryBooks = FakeMemoryBookStore();
  final lorebooks = FakeLorebookStore();
  final uiThemes = FakeThemePresetStore();
  final studioConfigs = FakeStudioConfigStore();
  final studioPresets = FakeStudioPresetStore();
  final manifestProvider = InMemoryManifestProvider(
    characterRepo: characters,
    chatRepo: chatStore,
    personaRepo: personas,
    presetRepo: presets,
    apiRepo: apiConfigs,
    memoryBookRepo: memoryBooks,
    lorebookRepo: lorebooks,
    themePresetRepo: uiThemes,
    studioConfigStore: studioConfigs,
    studioPresetStore: studioPresets,
    reconciliationStateStore: reconciliationStore,
  );
  return SyncEngine(
    cloud,
    manifestProvider,
    characters,
    chatStore,
    personas,
    presets,
    apiConfigs,
    memoryBooks,
    lorebooks,
    FakeEmbeddingStore(),
    FakeImageStore(),
    uiThemes,
    FakeExtensionPresetStore(),
    FakeExtensionsSettingsStore(),
    FakeInfoBlockStore(),
    FakeTrackerSnapshotStore(),
    FakeTrackerValueStore(),
    studioConfigs,
    studioPresets,
    null,
    null,
    null,
    null,
    const NoopSessionDeletionStore(),
    FakeCharacterDeletionStore(characters),
    (_) async {},
    reconciliationStore,
  );
}

// ─── Fixtures ───────────────────────────────────────────────────────

Character makeChar(String id, {String name = 'Test', String? avatarPath}) =>
    Character(id: id, name: name, avatarPath: avatarPath);

Persona makePersona(String id, {String name = 'Persona'}) =>
    Persona(id: id, name: name);

ChatSession makeChat(String id, {String charId = 'char1', int index = 0}) =>
    ChatSession(id: id, characterId: charId, sessionIndex: index);

ApiConfig makeApiConfig(String id, {String name = 'Default'}) =>
    ApiConfig(id: id, name: name);

Preset makePreset(String id, {String name = 'Preset'}) =>
    Preset(id: id, name: name);

Lorebook makeLorebook(String id, {String name = 'Lorebook'}) =>
    Lorebook(id: id, name: name);

MemoryBook makeMemoryBook(String sessionId, {int updatedAt = 1000}) =>
    MemoryBook(
      id: 'memorybook_$sessionId',
      sessionId: sessionId,
      updatedAt: updatedAt,
    );

// ─── Tests ──────────────────────────────────────────────────────────

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  SyncProgress firstTaskProgress(List<SyncProgress> progressList) =>
      progressList.firstWhere(
        (p) => p.total > 0 || p.message?.contains('Nothing to push') == true,
      );

  test('pull applies chat before its reconciliation state', () async {
    final reconciliationStates = FakeReconciliationStateStore();
    final world = SyncWorld(reconciliationStateStore: reconciliationStates);
    const sessionId = 'ordered-pull-session';
    const oldChat = ChatSession(
      id: sessionId,
      characterId: 'character',
      sessionIndex: 0,
      updatedAt: 1000,
      messages: [ChatMessage(id: 'a1', role: 'assistant', content: 'Opening')],
    );
    const cloudChat = ChatSession(
      id: sessionId,
      characterId: 'character',
      sessionIndex: 0,
      updatedAt: 2000,
      messages: [
        ChatMessage(id: 'a1', role: 'assistant', content: 'Opening'),
        ChatMessage(id: 'u1', role: 'user', content: 'Question'),
        ChatMessage(id: 'a2', role: 'assistant', content: 'Answer'),
      ],
    );
    await world.chats.put(oldChat);
    reconciliationStates.data[sessionId] = {
      'runs': [
        {'id': 'local-run', 'ordinal': 1},
      ],
      'collectors': <dynamic>[],
    };
    await world.engine.pushEntities(onProgress: (_) {});
    world.chats.putDelay = const Duration(milliseconds: 50);
    reconciliationStates.beforeMerge = (_) async {
      if (world.chats.data[sessionId]?.messages.length != 3) {
        throw StateError('Reconciliation saw a stale chat transcript');
      }
    };
    final statePayload = <String, dynamic>{
      'runs': [
        {'id': 'cloud-run', 'ordinal': 1},
      ],
      'collectors': <dynamic>[],
    };
    final chatEntry = SyncManifestEntry(
      type: 'chat',
      id: sessionId,
      path: cloudPath('chat', sessionId),
      updatedAt: 2000,
      hash: SyncSerialization.computeChatMetadataHash(
        const SessionMetadata(
          sessionId: sessionId,
          characterId: 'character',
          sessionIndex: 0,
          updatedAt: 2000,
          messageCount: 3,
          lastMessageContent: 'Answer',
          lastMessageTimestamp: 0,
        ),
      ),
    );
    final stateEntry = SyncManifestEntry(
      type: 'reconciliation_state',
      id: sessionId,
      path: cloudPath('reconciliation_state', sessionId),
      updatedAt: 2000,
      hash: SyncSerialization.computeSyncHash(statePayload),
    );
    final cloudManifest = SyncManifest(
      deviceId: 'cloud-device',
      createdAt: 1,
      lastSync: 2000,
      entries: {stateEntry.key: stateEntry, chatEntry.key: chatEntry},
    );
    world.cloud.files[stateEntry.path] = jsonEncode(statePayload);
    world.cloud.files[chatEntry.path] = jsonEncode(cloudChat.toJson());
    world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
      cloudManifest.toJson(),
    );

    await world.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    expect(world.chats.data[sessionId], cloudChat);
    expect(reconciliationStates.data[sessionId], statePayload);
  });

  test('pull applies chat before session lorebook overlays', () async {
    final overlays = FakeSessionLorebookOverlayStore();
    final world = SyncWorld(sessionLorebookOverlayStore: overlays);
    const sessionId = 'overlay-pull-session';
    const cloudChat = ChatSession(
      id: sessionId,
      characterId: 'character',
      sessionIndex: 0,
      updatedAt: 2000,
    );
    final overlayPayload = <String, dynamic>{
      '__sessionLorebookOverlays': true,
      'schemaVersion': 1,
      'sessionId': sessionId,
      'overlays': <dynamic>[],
    };
    overlays.beforeApply = (_) async {
      if (world.chats.data[sessionId] != cloudChat) {
        throw StateError('Lorebook overlay saw a stale owning chat');
      }
    };
    final chatEntry = SyncManifestEntry(
      type: 'chat',
      id: sessionId,
      path: cloudPath('chat', sessionId),
      updatedAt: 2000,
      hash: SyncSerialization.computeChatMetadataHash(
        const SessionMetadata(
          sessionId: sessionId,
          characterId: 'character',
          sessionIndex: 0,
          updatedAt: 2000,
          messageCount: 0,
          lastMessageContent: '',
          lastMessageTimestamp: 0,
        ),
      ),
    );
    final overlayEntry = SyncManifestEntry(
      type: 'session_lorebook_overlays',
      id: sessionId,
      path: cloudPath('session_lorebook_overlays', sessionId),
      updatedAt: 2000,
      hash: SyncSerialization.computeSyncHash(overlayPayload),
    );
    final cloudManifest = SyncManifest(
      deviceId: 'cloud-device',
      createdAt: 1,
      lastSync: 2000,
      entries: {overlayEntry.key: overlayEntry, chatEntry.key: chatEntry},
    );
    world.cloud.files[overlayEntry.path] = jsonEncode(overlayPayload);
    world.cloud.files[chatEntry.path] = jsonEncode(cloudChat.toJson());
    world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
      cloudManifest.toJson(),
    );

    await world.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    expect(overlays.data[sessionId], overlayPayload);
  });

  test(
    'Push pre-merges cloud-only reconciliation state before rebuilding manifest',
    () async {
      final reconciliationStates = FakeReconciliationStateStore();
      final world = SyncWorld(reconciliationStateStore: reconciliationStates);
      const sessionId = 'cloud-only-session';
      const chat = ChatSession(
        id: sessionId,
        characterId: 'cloud-character',
        sessionIndex: 0,
        updatedAt: 1000,
      );
      final payload = <String, dynamic>{
        'runs': [
          {'id': 'cloud-run', 'ordinal': 1},
        ],
        'collectors': <dynamic>[],
      };
      final entry = SyncManifestEntry(
        type: 'reconciliation_state',
        id: sessionId,
        path: cloudPath('reconciliation_state', sessionId),
        updatedAt: 1000,
        hash: SyncSerialization.computeSyncHash(payload),
      );
      final chatEntry = SyncManifestEntry(
        type: 'chat',
        id: sessionId,
        path: cloudPath('chat', sessionId),
        updatedAt: 1000,
        hash: SyncSerialization.computeChatMetadataHash(
          const SessionMetadata(
            sessionId: sessionId,
            characterId: 'cloud-character',
            sessionIndex: 0,
            updatedAt: 1000,
            messageCount: 0,
            lastMessageContent: '',
            lastMessageTimestamp: 0,
          ),
        ),
      );
      final cloudManifest = SyncManifest(
        deviceId: 'cloud-device',
        createdAt: 1,
        lastSync: 1000,
        entries: {chatEntry.key: chatEntry, entry.key: entry},
      );
      world.cloud.files[chatEntry.path] = jsonEncode(chat.toJson());
      world.cloud.files[entry.path] = jsonEncode(payload);
      world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        cloudManifest.toJson(),
      );

      expect(await reconciliationStates.getAllSessionIds(), isEmpty);

      await world.engine.pushEntities(onProgress: (_) {});

      expect(
        await reconciliationStates.getBySessionId(sessionId),
        equals(payload),
      );
      expect(jsonDecode(world.cloud.files[entry.path]!), equals(payload));
      final uploadedManifest = SyncManifest.fromJson(
        jsonDecode(world.cloud.files[cloudPath('manifest', 'manifest')]!)
            as Map<String, dynamic>,
      );
      expect(uploadedManifest.entries[entry.key]?.hash, entry.hash);
    },
  );

  test(
    'normalized reconciliation state does not repeat on the next pull',
    () async {
      final reconciliationStates = FakeReconciliationStateStore()
        ..discardCollectors = true;
      final world = SyncWorld(reconciliationStateStore: reconciliationStates);
      const sessionId = 'normalized-session';
      final payload = <String, dynamic>{
        'runs': [
          {'id': 'cloud-run', 'ordinal': 1},
        ],
        'collectors': [
          {'id': 'stale-collector'},
        ],
      };
      final entry = SyncManifestEntry(
        type: 'reconciliation_state',
        id: sessionId,
        path: cloudPath('reconciliation_state', sessionId),
        updatedAt: 1000,
        hash: SyncSerialization.computeSyncHash(payload),
      );
      final cloudManifest = SyncManifest(
        deviceId: 'cloud-device',
        createdAt: 1,
        lastSync: 1000,
        entries: {entry.key: entry},
      );
      world.cloud.files[entry.path] = jsonEncode(payload);
      world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        cloudManifest.toJson(),
      );

      await world.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});
      final acceptedManifest = await world.manifestProvider.readLocalManifest();
      expect(acceptedManifest.entries[entry.key]?.hash, entry.hash);
      final progress = <SyncProgress>[];
      await world.engine.pullEntities(
        onProgress: progress.add,
        onConflict: (_) {},
      );

      expect(progress.any((item) => item.message == 'Nothing to pull'), isTrue);
      expect(reconciliationStates.data[sessionId]!['collectors'], isEmpty);
    },
  );

  test(
    'reconciliation state normalized to empty does not repeat on next pull',
    () async {
      final reconciliationStates = FakeReconciliationStateStore()
        ..discardAll = true;
      final world = SyncWorld(reconciliationStateStore: reconciliationStates);
      const sessionId = 'discarded-session';
      const chat = ChatSession(
        id: sessionId,
        characterId: 'character',
        sessionIndex: 0,
        updatedAt: 1000,
      );
      await world.chats.put(chat);
      final payload = <String, dynamic>{
        'runs': [
          {'id': 'malformed-cloud-run', 'ordinal': 1},
        ],
      };
      final entry = SyncManifestEntry(
        type: 'reconciliation_state',
        id: sessionId,
        path: cloudPath('reconciliation_state', sessionId),
        updatedAt: 1000,
        hash: SyncSerialization.computeSyncHash(payload),
      );
      final cloudManifest = SyncManifest(
        deviceId: 'cloud-device',
        createdAt: 1,
        lastSync: 1000,
        entries: {entry.key: entry},
      );
      world.cloud.files[entry.path] = jsonEncode(payload);
      world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        cloudManifest.toJson(),
      );

      await world.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});
      final progress = <SyncProgress>[];
      await world.engine.pullEntities(
        onProgress: progress.add,
        onConflict: (_) {},
      );

      expect(progress.any((item) => item.message == 'Nothing to pull'), isTrue);
      expect(reconciliationStates.data[sessionId], isNull);
    },
  );

  test(
    'push-first premerge materializes cloud chat before real reconciliation state',
    () async {
      final sourceDb = AppDatabase.forTesting(NativeDatabase.memory());
      final targetDb = AppDatabase.forTesting(NativeDatabase.memory());
      try {
        const sessionId = 'fresh-device-session';
        const openingContent = 'Welcome to the fresh device.';
        const chat = ChatSession(
          id: sessionId,
          characterId: 'character',
          sessionIndex: 0,
          updatedAt: 1000,
          messages: [
            ChatMessage(
              id: 'opening-assistant',
              role: 'assistant',
              content: openingContent,
              swipes: [openingContent],
            ),
          ],
        );
        final sourceChats = ChatRepo(sourceDb);
        await sourceChats.put(chat);
        final run = LedgerReconciliationRun(
          id: 'source-run',
          sessionId: sessionId,
          ordinal: 1,
          anchors: [
            ReconciliationAnchor(
              messageId: 'opening-assistant',
              swipeId: 0,
              agentSwipeId: 0,
              role: 'assistant',
              contentHash: computeHash(openingContent),
            ),
          ],
          acceptedManifestRefs: const [],
          effectiveCanonStamp: 'source-stamp',
          effectiveCanonRevision: 1,
          effectiveCanonHash: 'source-canon',
          canonicalResult: const {
            'facts': ['fresh-device-fact'],
          },
          predecessorChainHash: '',
          contractVersion: 1,
          opsApplied: const [],
          createdAt: 1,
        );
        expect(
          await LedgerReconciliationRunRepo(sourceDb).append(run),
          isA<ReconciliationRunAppended>(),
        );
        final sourceStore = ReconciliationStateSyncStore(sourceDb);
        final payload = (await sourceStore.getBySessionId(sessionId))!;
        final sourceChat = (await sourceChats.getById(sessionId))!;
        final sourceMetadata =
            (await sourceChats.getAllSessionMetadata()).single;

        final cloud = FakeCloudAdapter();
        final chatEntry = SyncManifestEntry(
          type: 'chat',
          id: sessionId,
          path: cloudPath('chat', sessionId),
          updatedAt: 1000,
          hash: SyncSerialization.computeChatMetadataHash(sourceMetadata),
        );
        final stateEntry = SyncManifestEntry(
          type: 'reconciliation_state',
          id: sessionId,
          path: cloudPath('reconciliation_state', sessionId),
          updatedAt: 1000,
          hash: SyncSerialization.computeSyncHash(payload),
        );
        final cloudManifest = SyncManifest(
          deviceId: 'source-device',
          createdAt: 1,
          lastSync: 1000,
          entries: {chatEntry.key: chatEntry, stateEntry.key: stateEntry},
        );
        cloud.files[chatEntry.path] = jsonEncode(sourceChat.toJson());
        cloud.files[stateEntry.path] = jsonEncode(payload);
        cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
          cloudManifest.toJson(),
        );

        final targetChats = ChatRepo(targetDb);
        final targetStore = ReconciliationStateSyncStore(targetDb);
        expect(await targetChats.getById(sessionId), isNull);
        expect(
          await LedgerReconciliationRunRepo(targetDb).getHead(sessionId),
          isNull,
        );

        final engine = _realStoreEngine(
          chatStore: targetChats,
          reconciliationStore: targetStore,
          cloud: cloud,
        );
        await engine.pushEntities(onProgress: (_) {});

        expect(await targetChats.getById(sessionId), equals(sourceChat));
        final importedHead = await LedgerReconciliationRunRepo(
          targetDb,
        ).getHead(sessionId);
        expect(importedHead?.id, run.id);
        expect(importedHead?.chainHash, run.chainHash);
        expect(jsonDecode(cloud.files[stateEntry.path]!), equals(payload));

        final uploadedManifest = SyncManifest.fromJson(
          jsonDecode(cloud.files[cloudPath('manifest', 'manifest')]!)
              as Map<String, dynamic>,
        );
        expect(uploadedManifest.entries[chatEntry.key]?.hash, chatEntry.hash);
        expect(uploadedManifest.entries[stateEntry.key]?.hash, stateEntry.hash);
      } finally {
        await sourceDb.close();
        await targetDb.close();
      }
    },
  );

  test('Full sync lifecycle: push → pull → conflict → resolve', () async {
    // ── SCENE 1: Device A pushes to empty cloud ──
    final deviceA = SyncWorld();
    final char1 = makeChar('char1', name: 'Alice');
    final persona1 = makePersona('p1', name: 'Bob');
    final chat1 = makeChat('s1', charId: 'char1');

    await deviceA.characters.put(char1);
    await deviceA.personas.put(persona1);
    await deviceA.chats.put(chat1);

    final localManifest = await deviceA.manifestProvider.buildLocalManifest();
    await deviceA.manifestProvider.writeLocalManifest(localManifest);

    await deviceA.engine.pushEntities(onProgress: (_) {});

    expect(
      deviceA.cloud.files.containsKey(cloudPath('character', 'char1')),
      isTrue,
      reason: 'Push should upload character to cloud',
    );
    expect(
      deviceA.cloud.files.containsKey(cloudPath('persona', 'p1')),
      isTrue,
      reason: 'Push should upload persona to cloud',
    );
    expect(
      deviceA.cloud.files.containsKey(cloudPath('chat', 's1')),
      isTrue,
      reason: 'Push should upload chat to cloud',
    );
    expect(
      deviceA.cloud.files.containsKey(cloudPath('manifest', 'manifest')),
      isTrue,
      reason: 'Push should upload manifest',
    );

    // ── SCENE 2: Device B (empty) pulls from cloud ──
    final deviceB = SyncWorld();

    deviceB.cloud.files.addAll(deviceA.cloud.files);

    final conflicts = <SyncConflict>[];
    await deviceB.engine.pullEntities(
      onProgress: (_) {},
      onConflict: (c) => conflicts.add(c),
    );

    // BUG 1: False conflicts on empty device
    expect(
      conflicts,
      isEmpty,
      reason:
          'BUG: Empty device should have NO conflicts when pulling. '
          'The manifest builder creates singleton entries (lorebooks, api_presets, '
          'theme_presets) with updatedAt=now even for empty data. Since now > '
          'cloud.updatedAt, needsConflict returns true → false conflicts.',
    );

    expect(
      deviceB.characters.data['char1'],
      isNotNull,
      reason: 'Pull should download character from cloud',
    );
    expect(
      deviceB.personas.data['p1'],
      isNotNull,
      reason: 'Pull should download persona from cloud',
    );
    expect(
      deviceB.chats.data['s1'],
      isNotNull,
      reason: 'Pull should download chat from cloud',
    );

    // ── SCENE 3: Both modify same entity → conflict ──
    final deviceX = SyncWorld();
    final sharedChar = makeChar('shared1', name: 'Original');
    await deviceX.characters.put(sharedChar);

    final xLocalManifest = await deviceX.manifestProvider.buildLocalManifest();
    await deviceX.manifestProvider.writeLocalManifest(xLocalManifest);
    await deviceX.engine.pushEntities(onProgress: (_) {});

    // Simulate: another device also has this character but modified locally
    // after the push. Its local updatedAt > cloud updatedAt.
    final deviceY = SyncWorld();
    deviceY.cloud.files.addAll(deviceX.cloud.files);

    final modifiedChar = makeChar('shared1', name: 'Device Y Edit');
    await deviceY.characters.put(modifiedChar);

    // Force local manifest to show updatedAt newer than cloud.
    // Set lastSync > 0 so isFirstSync is false (simulates a second sync).
    final yManifest = await deviceY.manifestProvider.buildLocalManifest();
    final patchedEntries = Map<String, SyncManifestEntry>.from(
      yManifest.entries,
    );
    final charEntry = patchedEntries['character:shared1'];
    if (charEntry != null) {
      patchedEntries['character:shared1'] = charEntry.copyWith(
        updatedAt: DateTime.now().millisecondsSinceEpoch + 100000,
        hash: 'y_local_hash',
      );
    }
    await deviceY.manifestProvider.writeLocalManifest(
      yManifest.copyWith(lastSync: 5000, entries: patchedEntries),
    );

    final yConflicts = <SyncConflict>[];
    await deviceY.engine.pullEntities(
      onProgress: (_) {},
      onConflict: (c) => yConflicts.add(c),
    );

    expect(
      yConflicts.any((c) => c.type == 'character' && c.id == 'shared1'),
      isTrue,
      reason:
          'Conflict should be detected when local entity is newer than cloud',
    );

    // ── SCENE 4: Resolve conflict — choose cloud ──
    await deviceY.engine.resolveConflict(
      yConflicts.firstWhere((c) => c.id == 'shared1'),
      'cloud',
    );

    expect(
      deviceY.characters.data['shared1']?.name,
      equals('Original'),
      reason:
          'After resolving conflict with "cloud", local should have cloud data',
    );

    // ── SCENE 5: Second pull after resolution → no duplicate conflict ──
    final yConflicts2 = <SyncConflict>[];
    await deviceY.engine.pullEntities(
      onProgress: (_) {},
      onConflict: (c) => yConflicts2.add(c),
    );

    expect(
      yConflicts2.any((c) => c.id == 'shared1'),
      isFalse,
      reason:
          'BUG: After resolving a conflict, the next pull should not '
          're-trigger the same conflict. But resolveConflict only calls '
          '_pullEntry (which applies the data) without updating the '
          'manifest. The old hash/timestamp remains in the manifest, '
          'so the next pull sees a mismatch again → infinite conflict loop.',
    );
  });

  test(
    'Pull preserves a local entity absent from an older cloud manifest',
    () async {
      final source = SyncWorld();
      await source.characters.put(makeChar('cloud-char', name: 'Cloud'));
      await source.engine.pushEntities(onProgress: (_) {});

      final target = SyncWorld();
      target.cloud.files.addAll(source.cloud.files);
      await target.characters.put(makeChar('local-new', name: 'Local new'));

      await target.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

      expect(target.characters.data['cloud-char'], isNotNull);
      expect(
        target.characters.data['local-new'],
        isNotNull,
        reason:
            'Manifest absence is not a deletion. Only an explicit tombstone may '
            'remove a local entity during pull.',
      );
    },
  );

  test('Pull routes a chat tombstone through the session cascade', () async {
    final world = SyncWorld();
    await world.chats.put(makeChat('deleted-session'));

    final cloudManifest = SyncManifest(
      deviceId: 'cloud-device',
      createdAt: 1,
      entries: {
        'chat:deleted-session': SyncManifestEntry(
          type: 'chat',
          id: 'deleted-session',
          path: cloudPath('chat', 'deleted-session'),
          updatedAt: 2,
          hash: '',
          deleted: true,
        ),
      },
    );
    world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
      cloudManifest.toJson(),
    );

    await world.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    expect(world.chats.data['deleted-session'], isNull);
    expect(world.sessionDeletions.deletedSessionIds, ['deleted-session']);
  });

  test(
    'Pull routes a character tombstone through the character cascade',
    () async {
      final world = SyncWorld();
      await world.characters.put(makeChar('deleted-character'));

      final cloudManifest = SyncManifest(
        deviceId: 'cloud-device',
        createdAt: 1,
        entries: {
          'character:deleted-character': SyncManifestEntry(
            type: 'character',
            id: 'deleted-character',
            path: cloudPath('character', 'deleted-character'),
            updatedAt: 2,
            hash: '',
            deleted: true,
          ),
        },
      );
      world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        cloudManifest.toJson(),
      );

      await world.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

      expect(world.characters.data['deleted-character'], isNull);
      expect(world.characterDeletions.deletedCharacterIds, [
        {'deleted-character'},
      ]);
    },
  );

  test('Cloud round-trip restores the active Studio preset', () async {
    const activePreset = 'studio_loom_causal_direct_v1';
    final source = SyncWorld();
    final sourcePrefs = await SharedPreferences.getInstance();
    await sourcePrefs.setString(
      SyncSerialization.activeStudioPresetKey,
      activePreset,
    );
    await source.engine.pushEntities(onProgress: (_) {});

    final cloudPayload =
        jsonDecode(
              source.cloud.files[cloudPath('local_storage', 'local_storage')]!,
            )
            as Map<String, dynamic>;
    expect(cloudPayload[SyncSerialization.activeStudioPresetKey], activePreset);

    SharedPreferences.setMockInitialValues({});
    final target = SyncWorld();
    target.cloud.files.addAll(source.cloud.files);
    await target.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    final targetPrefs = await SharedPreferences.getInstance();
    expect(
      targetPrefs.getString(SyncSerialization.activeStudioPresetKey),
      activePreset,
    );
  });

  test(
    'Singleton push: lorebooks/api_presets/theme_presets upload as list',
    () async {
      final world = SyncWorld();
      await world.lorebooks.put(makeLorebook('lb1', name: 'World Lore'));
      await world.apiConfigs.put(makeApiConfig('api1', name: 'My API'));
      await world.presets.put(makePreset('pr1', name: 'My Preset'));

      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);

      await world.engine.pushEntities(onProgress: (_) {});

      // BUG: _readLocalEntity('lorebooks', 'lorebooks') calls
      // _lorebookRepo.getById('lorebooks') which returns null because
      // no lorebook has id='lorebooks'. The manifest entry has
      // type='lorebooks', id='lorebooks' (singleton pattern).
      // But _readLocalEntity tries to fetch a single entity by that id,
      // not the full list. Same for api_presets and theme_presets.
      expect(
        world.cloud.files.containsKey(cloudPath('lorebooks', 'lorebooks')),
        isTrue,
        reason:
            'Singleton types should push the entire list wrapped in '
            '{"__singleton": true, "items": [...]} format',
      );

      expect(
        world.cloud.files.containsKey(cloudPath('api_presets', 'api_presets')),
        isTrue,
        reason: 'Same for api_presets singleton',
      );

      expect(
        world.cloud.files.containsKey(
          cloudPath('theme_presets', 'theme_presets'),
        ),
        isTrue,
        reason: 'Same for theme_presets singleton',
      );
    },
  );

  test(
    'Singleton pull: lorebooks/api_presets deserialize items array correctly',
    () async {
      final world = SyncWorld();

      // Simulate cloud having lorebooks in singleton format
      final cloudLorebooks = [
        makeLorebook('lb1', name: 'World').toJson(),
        makeLorebook('lb2', name: 'Characters').toJson(),
      ];

      final manifest = SyncManifest(
        deviceId: 'cloud',
        createdAt: 1000,
        entries: {
          'lorebooks:lorebooks': SyncManifestEntry(
            type: 'lorebooks',
            id: 'lorebooks',
            path: cloudPath('lorebooks', 'lorebooks'),
            updatedAt: 1000,
            hash: 'abc',
          ),
        },
      );

      world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        manifest.toJson(),
      );
      world.cloud.files[cloudPath('lorebooks', 'lorebooks')] = jsonEncode({
        '__singleton': true,
        'items': cloudLorebooks,
      });

      // Device has no lorebooks locally
      final conflicts = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts.add(c),
      );

      // BUG: _applyCloudEntity('lorebooks', 'lorebooks', data) does:
      //   Lorebook.fromJson(data)
      // But data is a List, not a Map. fromJson throws, catch(_){} swallows.
      // The lorebooks are never saved locally.
      expect(
        world.lorebooks.data.length,
        greaterThan(0),
        reason:
            'Cloud lorebooks stored in singleton format should be applied '
            'locally. _applyCloudEntity iterates the items array and '
            'puts each lorebook individually.',
      );
    },
  );

  test('Push includes pipelineSettings in local_storage singleton', () async {
    final world = SyncWorld();
    const settingsJson = '{"studioControllerModelOverride":"gemini-pro"}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pipelineSettings', settingsJson);

    final manifest = await world.manifestProvider.buildLocalManifest();
    await world.manifestProvider.writeLocalManifest(manifest);

    await world.engine.pushEntities(onProgress: (_) {});

    final raw = world.cloud.files[cloudPath('local_storage', 'local_storage')];
    expect(raw, isNotNull);
    final payload = jsonDecode(raw!) as Map<String, dynamic>;
    expect(payload['__localStorage'], isTrue);
    expect(payload['pipelineSettings'], settingsJson);

    final cloudManifest = SyncManifest.fromJson(
      jsonDecode(world.cloud.files[cloudPath('manifest', 'manifest')]!)
          as Map<String, dynamic>,
    );
    expect(
      cloudManifest.entries.containsKey('local_storage:local_storage'),
      isTrue,
    );
  });

  test('Pull applies pipelineSettings from local_storage singleton', () async {
    final world = SyncWorld();
    const settingsJson = '{"postCleanerModel":"claude-sonnet"}';
    final payload = {'__localStorage': true, 'pipelineSettings': settingsJson};
    final entry = SyncManifestEntry(
      type: 'local_storage',
      id: 'local_storage',
      path: cloudPath('local_storage', 'local_storage'),
      updatedAt: 1000,
      hash: SyncSerialization.computeSyncHash(payload),
    );
    final cloudManifest = SyncManifest(
      deviceId: 'cloud',
      createdAt: 1,
      lastSync: 1000,
      entries: {entry.key: entry},
    );
    world.cloud.files[entry.path] = jsonEncode(payload);
    world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
      cloudManifest.toJson(),
    );

    await world.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pipelineSettings'), settingsJson);
  });

  test('Cloud round-trip restores both global regex collections', () async {
    const globalRegex = '[{"id":"global-regex","regex":"foo"}]';
    const studioRegex =
        '[{"script":{"id":"studio-regex","regex":"bar"},"stages":["final"]}]';
    final source = SyncWorld();
    final sourcePrefs = await SharedPreferences.getInstance();
    await sourcePrefs.setString(
      SyncSerialization.globalRegexScriptsKey,
      globalRegex,
    );
    await sourcePrefs.setString(
      SyncSerialization.studioRegexScriptsKey,
      studioRegex,
    );

    await source.engine.pushEntities(onProgress: (_) {});

    final cloudPayload =
        jsonDecode(
              source.cloud.files[cloudPath('local_storage', 'local_storage')]!,
            )
            as Map<String, dynamic>;
    expect(cloudPayload[SyncSerialization.globalRegexScriptsKey], globalRegex);
    expect(cloudPayload[SyncSerialization.studioRegexScriptsKey], studioRegex);

    SharedPreferences.setMockInitialValues({});
    final target = SyncWorld();
    target.cloud.files.addAll(source.cloud.files);
    await target.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    final targetPrefs = await SharedPreferences.getInstance();
    expect(
      targetPrefs.getString(SyncSerialization.globalRegexScriptsKey),
      globalRegex,
    );
    expect(
      targetPrefs.getString(SyncSerialization.studioRegexScriptsKey),
      studioRegex,
    );
  });

  test(
    'Legacy local_storage payload preserves local regex collections',
    () async {
      const globalRegex = '[{"id":"local-global"}]';
      const studioRegex = '[{"script":{"id":"local-studio"}}]';
      final world = SyncWorld();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        SyncSerialization.globalRegexScriptsKey,
        globalRegex,
      );
      await prefs.setString(
        SyncSerialization.studioRegexScriptsKey,
        studioRegex,
      );
      const payload = {
        '__localStorage': true,
        'pipelineSettings': '{"legacy":true}',
      };
      final entry = SyncManifestEntry(
        type: 'local_storage',
        id: 'local_storage',
        path: cloudPath('local_storage', 'local_storage'),
        updatedAt: 1000,
        hash: SyncSerialization.computeSyncHash(payload),
      );
      world.cloud.files[entry.path] = jsonEncode(payload);
      world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        SyncManifest(
          deviceId: 'cloud',
          createdAt: 1,
          lastSync: 1000,
          entries: {entry.key: entry},
        ).toJson(),
      );

      await world.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

      expect(
        prefs.getString(SyncSerialization.globalRegexScriptsKey),
        globalRegex,
      );
      expect(
        prefs.getString(SyncSerialization.studioRegexScriptsKey),
        studioRegex,
      );
    },
  );

  test(
    'Empty device with no API presets should not conflict with cloud',
    () async {
      final world = SyncWorld();

      // Device has NO API configs — completely empty
      final cloudApi = makeApiConfig('default', name: 'Default');
      final cloudManifest = SyncManifest(
        deviceId: 'cloud',
        createdAt: 1000,
        entries: {
          'api_presets:api_presets': SyncManifestEntry(
            type: 'api_presets',
            id: 'api_presets',
            path: cloudPath('api_presets', 'api_presets'),
            updatedAt: 500,
            hash: 'cloud_hash',
          ),
        },
      );

      world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        cloudManifest.toJson(),
      );
      world.cloud.files[cloudPath('api_presets', 'api_presets')] = jsonEncode({
        '__singleton': true,
        'items': [cloudApi.toJson()],
      });

      // Build local manifest — empty singleton should get updatedAt=0
      final localManifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(localManifest);

      // Verify: empty singletons have updatedAt=0
      final apiEntry = localManifest.entries['api_presets:api_presets'];
      expect(
        apiEntry?.updatedAt,
        equals(0),
        reason:
            'Empty singleton entries should have updatedAt=0 so they '
            'never appear "newer" than cloud data',
      );

      final conflicts = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts.add(c),
      );

      expect(
        conflicts,
        isEmpty,
        reason:
            'Empty device with no API presets should NOT conflict with '
            'cloud. Empty singletons get updatedAt=0 which is always <= '
            'cloud updatedAt, so needsConflict returns false.',
      );

      expect(
        world.apiConfigs.data['default'],
        isNotNull,
        reason: 'Cloud API config should be pulled to local',
      );
    },
  );

  test(
    'resolveConflict("cloud") updates manifest — next pull does not re-trigger conflict',
    () async {
      final world = SyncWorld();

      final localChar = makeChar('c1', name: 'Local Version');
      await world.characters.put(localChar);

      final cloudChar = makeChar('c1', name: 'Cloud Version');
      final cloudHash = SyncSerialization.computeSyncHash(cloudChar.toJson());
      final cloudManifest = SyncManifest(
        deviceId: 'cloud',
        createdAt: 1000,
        entries: {
          'character:c1': SyncManifestEntry(
            type: 'character',
            id: 'c1',
            path: cloudPath('character', 'c1'),
            updatedAt: 500,
            hash: cloudHash,
          ),
        },
      );

      world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        cloudManifest.toJson(),
      );
      world.cloud.files[cloudPath('character', 'c1')] = jsonEncode(
        cloudChar.toJson(),
      );

      // Build a real local manifest from data, then write it
      final localManifest = await world.manifestProvider.buildLocalManifest();
      // Patch: make the character entry appear newer than cloud
      final patchedEntries = Map<String, SyncManifestEntry>.from(
        localManifest.entries,
      );
      final charEntry = patchedEntries['character:c1'];
      if (charEntry != null) {
        patchedEntries['character:c1'] = charEntry.copyWith(
          updatedAt: DateTime.now().millisecondsSinceEpoch + 100000,
        );
      }
      await world.manifestProvider.writeLocalManifest(
        localManifest.copyWith(lastSync: 5000, entries: patchedEntries),
      );

      // First pull — detects conflict
      final conflicts1 = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts1.add(c),
      );

      expect(conflicts1.length, 1, reason: 'Should detect one conflict');

      // Resolve: choose cloud
      await world.engine.resolveConflict(conflicts1.first, 'cloud');

      expect(
        world.characters.data['c1']?.name,
        equals('Cloud Version'),
        reason:
            'After resolving conflict with "cloud", local should have cloud data',
      );

      // Rebuild manifest from current data (now cloud version)
      final resolvedManifest = await world.manifestProvider
          .buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(resolvedManifest);

      // Second pull — should NOT conflict because hashes now match
      final conflicts2 = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts2.add(c),
      );

      expect(
        conflicts2,
        isEmpty,
        reason:
            'After resolving a conflict and rebuilding the manifest, '
            'the next pull should not re-trigger the same conflict. '
            'The rebuilt manifest should have the same hash as cloud.',
      );
    },
  );

  test(
    'Wipe resets status to idle — subsequent push does not show wipe state',
    () async {
      final world = SyncWorld();

      // Push some data first
      await world.characters.put(makeChar('c1', name: 'Alice'));
      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      expect(
        world.cloud.files.isNotEmpty,
        isTrue,
        reason: 'Cloud should have data before wipe',
      );

      // Wipe cloud data — engine resets to idle after wipe
      await world.engine.wipeCloudData(onProgress: (_) {});

      expect(
        world.cloud.files.isEmpty,
        isTrue,
        reason: 'Cloud should be empty after wipe',
      );

      // Simulate the SyncService status transition:
      // wipeCloudData sets _status = SyncStatus.syncing, then idle on success
      // The UI must read service.status after wipe completes
      // If it doesn't, the status provider stays at SyncStatus.syncing

      // Push again after wipe
      await world.characters.put(makeChar('c2', name: 'Bob'));
      final manifest2 = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest2);

      // This should work without issues — no stale wipe state
      await world.engine.pushEntities(onProgress: (_) {});

      expect(
        world.cloud.files.containsKey(cloudPath('character', 'c2')),
        isTrue,
        reason: 'Push after wipe should upload new character',
      );
      expect(
        world.cloud.files.containsKey(cloudPath('character', 'c1')),
        isTrue,
        reason: 'Push after wipe should upload previously wiped character too',
      );
    },
  );

  test(
    'Push progress reports correct current/total (tasks, not entries)',
    () async {
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'Alpha'));
      await world.characters.put(makeChar('c2', name: 'Beta'));
      await world.characters.put(makeChar('c3', name: 'Gamma'));

      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);

      await world.engine.pushEntities(onProgress: (_) {});

      await world.characters.put(makeChar('c2', name: 'Beta Updated'));
      final manifest2 = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest2);

      final progressList = <SyncProgress>[];
      await world.engine.pushEntities(onProgress: (p) => progressList.add(p));

      final initial = firstTaskProgress(progressList);
      expect(
        initial.total,
        equals(1),
        reason: 'Only c2 needs pushing, so total should be 1',
      );

      final itemProgress = progressList.where(
        (p) => p.message?.contains('c2') ?? false,
      );
      expect(itemProgress.length, 1);
      expect(itemProgress.first.current, equals(1));
      expect(itemProgress.first.total, equals(1));
    },
  );

  test(
    'Pull progress reports correct current/total (tasks, not entries)',
    () async {
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'Alpha'));
      await world.characters.put(makeChar('c2', name: 'Beta'));
      await world.characters.put(makeChar('c3', name: 'Gamma'));

      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      world.characters.data.clear();

      final progressList = <SyncProgress>[];
      await world.engine.pullEntities(
        onProgress: (p) => progressList.add(p),
        onConflict: (_) {},
      );

      final initial = progressList.first;
      expect(initial.total, equals(3), reason: 'All 3 characters need pulling');

      final itemProgresses = progressList.where((p) => p.current > 0);
      for (final p in itemProgresses) {
        expect(p.total, equals(3));
      }

      final last = itemProgresses.last;
      expect(last.current, equals(3));
    },
  );

  test('Push with nothing to push reports total=0', () async {
    final world = SyncWorld();

    await world.characters.put(makeChar('c1', name: 'Alpha'));
    final manifest = await world.manifestProvider.buildLocalManifest();
    await world.manifestProvider.writeLocalManifest(manifest);
    await world.engine.pushEntities(onProgress: (_) {});

    final progressList = <SyncProgress>[];
    await world.engine.pushEntities(onProgress: (p) => progressList.add(p));

    expect(progressList.isNotEmpty, isTrue);
    final initial = firstTaskProgress(progressList);
    expect(
      initial.total,
      equals(0),
      reason: 'Nothing changed, so total tasks should be 0',
    );
    expect(initial.message, contains('Nothing to push'));
  });

  test('Push failure after wipe does not write success manifest', () async {
    final world = SyncWorld();

    await world.characters.put(makeChar('c1', name: 'Alpha'));
    final manifest = await world.manifestProvider.buildLocalManifest();
    await world.manifestProvider.writeLocalManifest(manifest);
    await world.engine.pushEntities(onProgress: (_) {});

    await world.engine.wipeCloudData(onProgress: (_) {});

    final c1Path = cloudPath('character', 'c1');
    world.cloud.uploadFailures.add(c1Path);
    await expectLater(
      world.engine.pushEntities(onProgress: (_) {}),
      throwsA(isA<SyncQueueAggregateError>()),
    );

    world.cloud.uploadFailures.clear();
    await world.engine.pushEntities(onProgress: (_) {});

    expect(
      world.cloud.files.containsKey(c1Path),
      isTrue,
      reason: 'A failed push must retry entity uploads on the next push',
    );
  });

  test('Push skips upload when cloud listing omits /Glaze prefix', () async {
    final world = SyncWorld();

    await world.characters.put(makeChar('c1', name: 'Alpha'));
    final manifest = await world.manifestProvider.buildLocalManifest();
    await world.manifestProvider.writeLocalManifest(manifest);
    await world.engine.pushEntities(onProgress: (_) {});

    world.cloud.stripGlazePrefixInList = true;

    final progressList = <SyncProgress>[];
    await world.engine.pushEntities(onProgress: (p) => progressList.add(p));

    final initial = firstTaskProgress(progressList);
    expect(
      initial.total,
      equals(0),
      reason: 'Hash match + file exists (Dropbox-style paths) → no uploads',
    );
    expect(initial.message, contains('Nothing to push'));
  });

  test(
    'Push does not skip uploads when cloud listing is empty after wipe',
    () async {
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'Alpha'));
      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      world.cloud.files.clear();
      world.cloud.omitFilesFromList = true;

      final progressList = <SyncProgress>[];
      await world.engine.pushEntities(onProgress: (p) => progressList.add(p));

      expect(
        world.cloud.files.containsKey(cloudPath('character', 'c1')),
        isTrue,
      );
      expect(firstTaskProgress(progressList).total, greaterThan(0));
    },
  );

  test(
    'Push skips upload when cloud manifest hash matches but listFolder is empty',
    () async {
      // Regression: previously, when the manifest hash matched but a fresh
      // folder listing came back empty (provider propagation lag, a transient
      // listFolder error, or any cause), every hash-matching entry fell through
      // an empty `if` body and was re-uploaded — a full-cloud re-push with no
      // duplicates. The fix trusts the manifest hash unless the listing
      // positively confirms the file is absent.
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'Alpha'));
      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      // Cloud files and the cloud manifest are intact (hash matches), but the
      // provider returns an empty listing — simulating a failed/lagging
      // listFolder without wiping actual data.
      world.cloud.omitFilesFromList = true;

      final progressList = <SyncProgress>[];
      await world.engine.pushEntities(onProgress: (p) => progressList.add(p));

      final initial = firstTaskProgress(progressList);
      expect(
        initial.total,
        equals(0),
        reason:
            'Manifest hash match must skip even when the file listing is empty; '
            'the listing is only consulted to repair genuinely missing files.',
      );
      expect(initial.message, contains('Nothing to push'));
    },
  );

  test(
    'Push skips upload when cloud manifest hash matches but listFolder throws',
    () async {
      // Same regression class as above, but via a thrown listing error instead
      // of an empty result. The swallow in _loadCloudFilePathsForEntries must
      // not collapse the skip gate.
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'Alpha'));
      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      world.cloud.listFolderThrows = true;

      final progressList = <SyncProgress>[];
      await world.engine.pushEntities(onProgress: (p) => progressList.add(p));

      final initial = firstTaskProgress(progressList);
      expect(
        initial.total,
        equals(0),
        reason:
            'A failed listFolder must not force a re-upload of entries whose '
            'cloud manifest hash already matches.',
      );
      expect(initial.message, contains('Nothing to push'));
    },
  );

  test(
    'Push aborts instead of re-uploading everything when manifest download fails',
    () async {
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'Alpha'));
      await world.engine.pushEntities(onProgress: (_) {});

      final manifestPath = cloudPath('manifest', 'manifest');
      final characterPath = cloudPath('character', 'c1');
      final characterJson = world.cloud.files[characterPath];
      world.cloud.downloadFailures.add(manifestPath);

      await expectLater(
        world.engine.pushEntities(onProgress: (_) {}),
        throwsA(isA<Exception>()),
      );

      expect(world.cloud.files[characterPath], characterJson);
      expect(world.cloud.files[manifestPath], isNotNull);
    },
  );

  test('Push trusts matching hashes for folders whose listing fails', () async {
    final world = SyncWorld();

    await world.characters.put(makeChar('c1', name: 'Alpha'));
    await world.chats.put(makeChat('s1', charId: 'c1'));
    await world.engine.pushEntities(onProgress: (_) {});

    world.cloud.listFolderFailures.add('$cloudBase/chats');
    final progressList = <SyncProgress>[];
    await world.engine.pushEntities(onProgress: progressList.add);

    final initial = firstTaskProgress(progressList);
    expect(initial.total, 0);
    expect(initial.message, contains('Nothing to push'));
  });

  test(
    'Push after wipe with no cloud manifest does not scan cloud files',
    () async {
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'Alpha'));
      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);

      final progressList = <SyncProgress>[];
      await world.engine.pushEntities(onProgress: (p) => progressList.add(p));

      expect(
        world.cloud.files.containsKey(cloudPath('character', 'c1')),
        isTrue,
      );
      expect(
        progressList.any((p) => p.message == 'Scanning cloud files...'),
        isFalse,
      );
    },
  );

  test(
    'Push with full cloud checks manifest parent folders instead of recursive root scan',
    () async {
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'Alpha'));
      await world.personas.put(makePersona('p1', name: 'Persona'));
      await world.chats.put(makeChat('s1', charId: 'c1'));
      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      world.cloud.files['$cloudBase/gallery/c1/deep/unused-1.png'] = 'x';
      world.cloud.files['$cloudBase/gallery/c1/deep/unused-2.png'] = 'x';
      world.cloud.listFolderCalls.clear();

      final progressList = <SyncProgress>[];
      await world.engine.pushEntities(onProgress: (p) => progressList.add(p));

      expect(
        world.cloud.listFolderCalls,
        isNot(contains('$cloudBase/gallery')),
      );
      expect(
        world.cloud.listFolderCalls.any(
          (p) => p.startsWith('$cloudBase/gallery/'),
        ),
        isFalse,
      );
      expect(
        progressList.any((p) => p.message == 'Checking cloud files...'),
        isTrue,
      );
    },
  );

  test('Wipe progress reports indeterminate (no total)', () async {
    final world = SyncWorld();

    await world.characters.put(makeChar('c1', name: 'Alpha'));
    final manifest = await world.manifestProvider.buildLocalManifest();
    await world.manifestProvider.writeLocalManifest(manifest);
    await world.engine.pushEntities(onProgress: (_) {});

    final progressList = <SyncProgress>[];
    await world.engine.wipeCloudData(onProgress: (p) => progressList.add(p));

    expect(progressList.isNotEmpty, isTrue);
    for (final p in progressList) {
      expect(
        p.total,
        equals(0),
        reason: 'Wipe progress should be indeterminate (total=0)',
      );
    }
    expect(
      progressList.any((p) => p.message?.contains('Deleting') == true),
      isTrue,
    );
    expect(
      progressList.any((p) => p.message?.contains('Recreating') == true),
      isTrue,
    );
  });

  test(
    'Push progress: final event has current == total (bar reaches 100%)',
    () async {
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'A'));
      await world.characters.put(makeChar('c2', name: 'B'));
      await world.characters.put(makeChar('c3', name: 'C'));

      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);

      final progressList = <SyncProgress>[];
      await world.engine.pushEntities(onProgress: (p) => progressList.add(p));

      final last = progressList.lastWhere((p) => p.total > 0);
      expect(
        last.current,
        equals(last.total),
        reason:
            'Final progress event must have current == total so bar reaches 100%',
      );
    },
  );

  test(
    'Pull progress: final event has current == total (bar reaches 100%)',
    () async {
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'A'));
      await world.characters.put(makeChar('c2', name: 'B'));

      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      world.characters.data.clear();
      world.personas.data.clear();
      world.chats.data.clear();

      final progressList = <SyncProgress>[];
      await world.engine.pullEntities(
        onProgress: (p) => progressList.add(p),
        onConflict: (_) {},
      );

      final last = progressList.lastWhere((p) => p.total > 0);
      expect(
        last.current,
        equals(last.total),
        reason:
            'Final progress event must have current == total so bar reaches 100%',
      );
    },
  );

  test('Push progress events are emitted between start and end', () async {
    final world = SyncWorld();

    await world.characters.put(makeChar('c1', name: 'A'));
    await world.characters.put(makeChar('c2', name: 'B'));

    final manifest = await world.manifestProvider.buildLocalManifest();
    await world.manifestProvider.writeLocalManifest(manifest);

    final progressList = <SyncProgress>[];
    await world.engine.pushEntities(onProgress: (p) => progressList.add(p));

    expect(
      progressList.length,
      greaterThanOrEqualTo(3),
      reason: 'Should have initial + per-item + completion events',
    );

    final initial = firstTaskProgress(progressList);
    expect(
      initial.total,
      greaterThanOrEqualTo(2),
      reason:
          'Initial event should report total >= 2 (characters + singleton types)',
    );

    expect(
      progressList.lastWhere((p) => p.total > 0).current,
      equals(progressList.lastWhere((p) => p.total > 0).total),
      reason: 'Last event should report all items done',
    );
  });

  test(
    'SyncService-style status transitions: idle → syncing → idle on push success',
    () async {
      final world = SyncWorld();
      await world.characters.put(makeChar('c1', name: 'A'));
      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);

      final statusLog = <SyncStatus>[];
      var currentStatus = SyncStatus.idle;
      void trackStatus(SyncStatus s) {
        currentStatus = s;
        statusLog.add(s);
      }

      trackStatus(SyncStatus.syncing);
      await world.engine.pushEntities(onProgress: (_) {});
      trackStatus(SyncStatus.idle);

      expect(
        statusLog,
        equals([SyncStatus.syncing, SyncStatus.idle]),
        reason: 'Status should go idle → syncing → idle after successful push',
      );
      expect(currentStatus, equals(SyncStatus.idle));
    },
  );

  test(
    'SyncService-style status transitions: idle → syncing → error on push failure',
    () async {
      final world = SyncWorld();

      final statusLog = <SyncStatus>[];
      var currentStatus = SyncStatus.idle;
      void trackStatus(SyncStatus s) {
        currentStatus = s;
        statusLog.add(s);
      }

      trackStatus(SyncStatus.syncing);
      try {
        await world.engine.pushEntities(onProgress: (_) {});
        trackStatus(SyncStatus.idle);
      } catch (e) {
        trackStatus(SyncStatus.error);
      }

      expect(
        statusLog,
        equals([SyncStatus.syncing, SyncStatus.idle]),
        reason: 'Pushing with no data should succeed (nothing to push)',
      );
      expect(currentStatus, equals(SyncStatus.idle));
    },
  );

  test('Persona avatar is pushed to cloud and pulled back', () async {
    final deviceA = SyncWorld();
    deviceA.cloud.requireEnsuredParentForUpload = true;

    final avatarBytes = Uint8List.fromList([1, 2, 3, 4, 5]);

    final tmpDir = Directory.systemTemp.createTempSync('glaze_test_avatar');
    final avatarFile = File('${tmpDir.path}/p1.png');
    await avatarFile.writeAsBytes(avatarBytes);

    final persona = Persona(
      id: 'p1',
      name: 'Test',
      avatarPath: avatarFile.path,
    );
    await deviceA.personas.put(persona);

    final manifest = await deviceA.manifestProvider.buildLocalManifest();
    await deviceA.manifestProvider.writeLocalManifest(manifest);

    await deviceA.engine.pushEntities(onProgress: (_) {});

    final avatarCloudPath = personaAvatarCloudPath('p1', 'png');
    expect(
      deviceA.cloud.ensuredFolders,
      contains('$cloudBase/persona_avatars/p1'),
      reason: 'Dropbox upload requires the persona avatar parent folder',
    );
    expect(
      deviceA.cloud.files.containsKey(avatarCloudPath),
      isTrue,
      reason: 'Persona avatar should be uploaded to cloud',
    );

    final deviceB = SyncWorld();
    deviceB.cloud.files.addAll(deviceA.cloud.files);

    await deviceB.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    final pulled = deviceB.personas.data['p1'];
    expect(pulled, isNotNull, reason: 'Persona should be pulled');
    expect(
      pulled!.avatarPath,
      isNotNull,
      reason: 'Persona avatar path should be set after pull',
    );

    final savedKey = 'avatars/p1.png';
    expect(
      deviceB.images.saved[savedKey],
      isNotNull,
      reason: 'Persona avatar bytes should be saved to image storage',
    );

    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  test('Push strips API keys when includeApiKeys is false', () async {
    final world = SyncWorld();

    final apiConfig = ApiConfig(
      id: 'api1',
      name: 'Test API',
      apiKey: 'sk-secret-key-12345',
      embeddingApiKey: 'emb-secret-67890',
    );
    await world.apiConfigs.put(apiConfig);

    final manifest = await world.manifestProvider.buildLocalManifest();
    await world.manifestProvider.writeLocalManifest(manifest);

    await world.engine.pushEntities(onProgress: (_) {}, includeApiKeys: false);

    final cloudData =
        world.cloud.files[cloudPath('api_presets', 'api_presets')];
    expect(cloudData, isNotNull);

    final decoded = jsonDecode(cloudData!) as Map<String, dynamic>;
    final items = decoded['items'] as List;
    expect(items, isNotEmpty);

    final pushedApi = items.first as Map<String, dynamic>;
    expect(
      pushedApi['apiKey'],
      equals(''),
      reason: 'API key should be stripped when includeApiKeys=false',
    );
    expect(
      pushedApi['embeddingApiKey'],
      equals(''),
      reason: 'Embedding API key should be stripped when includeApiKeys=false',
    );
    expect(
      pushedApi['name'],
      equals('Test API'),
      reason: 'Non-key fields should be preserved',
    );
  });

  test('Push includes API keys when includeApiKeys is true', () async {
    final world = SyncWorld();

    final apiConfig = ApiConfig(
      id: 'api1',
      name: 'Test API',
      apiKey: 'sk-secret-key-12345',
      embeddingApiKey: 'emb-secret-67890',
    );
    await world.apiConfigs.put(apiConfig);

    final manifest = await world.manifestProvider.buildLocalManifest();
    await world.manifestProvider.writeLocalManifest(manifest);

    await world.engine.pushEntities(onProgress: (_) {}, includeApiKeys: true);

    final cloudData =
        world.cloud.files[cloudPath('api_presets', 'api_presets')];
    expect(cloudData, isNotNull);

    final decoded = jsonDecode(cloudData!) as Map<String, dynamic>;
    final items = decoded['items'] as List;
    final pushedApi = items.first as Map<String, dynamic>;
    expect(
      pushedApi['apiKey'],
      equals('sk-secret-key-12345'),
      reason: 'API key should be included when includeApiKeys=true',
    );
    expect(
      pushedApi['embeddingApiKey'],
      equals('emb-secret-67890'),
      reason: 'Embedding API key should be included when includeApiKeys=true',
    );
  });

  test(
    'needsConflict returns false when hashes match (same data, different timestamps)',
    () async {
      final world = SyncWorld();

      await world.characters.put(makeChar('c1', name: 'Alice'));
      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      world.characters.data.clear();
      world.personas.data.clear();
      world.chats.data.clear();

      final conflicts = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts.add(c),
      );

      expect(
        conflicts,
        isEmpty,
        reason: 'Pull on empty device should produce no conflicts',
      );

      await world.characters.put(makeChar('c1', name: 'Alice'));
      final manifest2 = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest2);

      final conflicts2 = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts2.add(c),
      );

      expect(
        conflicts2,
        isEmpty,
        reason:
            'Same data (same hash) should not conflict even if timestamps differ',
      );
    },
  );

  test(
    'resolveConflict("local") preserves local data — next push uploads it',
    () async {
      final world = SyncWorld();

      final localChar = makeChar('c1', name: 'Local Version');
      await world.characters.put(localChar);

      final cloudChar = makeChar('c1', name: 'Cloud Version');
      final cloudHash = SyncSerialization.computeSyncHash(cloudChar.toJson());
      final cloudManifest = SyncManifest(
        deviceId: 'cloud',
        createdAt: 1000,
        entries: {
          'character:c1': SyncManifestEntry(
            type: 'character',
            id: 'c1',
            path: cloudPath('character', 'c1'),
            updatedAt: 500,
            hash: cloudHash,
          ),
        },
      );

      world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        cloudManifest.toJson(),
      );
      world.cloud.files[cloudPath('character', 'c1')] = jsonEncode(
        cloudChar.toJson(),
      );

      final localManifest = await world.manifestProvider.buildLocalManifest();
      final patchedEntries = Map<String, SyncManifestEntry>.from(
        localManifest.entries,
      );
      final charEntry = patchedEntries['character:c1'];
      if (charEntry != null) {
        patchedEntries['character:c1'] = charEntry.copyWith(
          updatedAt: DateTime.now().millisecondsSinceEpoch + 100000,
        );
      }
      await world.manifestProvider.writeLocalManifest(
        localManifest.copyWith(lastSync: 5000, entries: patchedEntries),
      );

      final conflicts = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts.add(c),
      );

      expect(conflicts.length, 1);

      await world.engine.resolveConflict(conflicts.first, 'local');

      expect(
        world.characters.data['c1']?.name,
        equals('Local Version'),
        reason: 'Keep Local should preserve local data',
      );

      final rebuiltManifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(rebuiltManifest);

      await world.engine.pushEntities(onProgress: (_) {});

      final cloudData = world.cloud.files[cloudPath('character', 'c1')];
      expect(cloudData, isNotNull);
      final pushed = jsonDecode(cloudData!) as Map<String, dynamic>;
      expect(
        pushed['name'],
        equals('Local Version'),
        reason: 'After Keep Local, push should upload local version to cloud',
      );
    },
  );

  test(
    'applyPendingPull downloads remaining items after conflicts resolved',
    () async {
      final world = SyncWorld();

      final cloudChar1 = makeChar('c1', name: 'Alice');
      final cloudHash1 = SyncSerialization.computeSyncHash(cloudChar1.toJson());
      final cloudChar2 = makeChar('c2', name: 'Cloud Bob');
      final cloudHash2 = SyncSerialization.computeSyncHash(cloudChar2.toJson());
      final localChar2 = makeChar('c2', name: 'Local Bob');

      await world.characters.put(localChar2);

      final cloudManifest = SyncManifest(
        deviceId: 'cloud',
        createdAt: 1000,
        entries: {
          'character:c1': SyncManifestEntry(
            type: 'character',
            id: 'c1',
            path: cloudPath('character', 'c1'),
            updatedAt: 500,
            hash: cloudHash1,
          ),
          'character:c2': SyncManifestEntry(
            type: 'character',
            id: 'c2',
            path: cloudPath('character', 'c2'),
            updatedAt: 500,
            hash: cloudHash2,
          ),
        },
      );

      world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        cloudManifest.toJson(),
      );
      world.cloud.files[cloudPath('character', 'c1')] = jsonEncode(
        cloudChar1.toJson(),
      );
      world.cloud.files[cloudPath('character', 'c2')] = jsonEncode(
        cloudChar2.toJson(),
      );

      final localManifest = await world.manifestProvider.buildLocalManifest();
      final patchedEntries = Map<String, SyncManifestEntry>.from(
        localManifest.entries,
      );
      final charEntry = patchedEntries['character:c2'];
      if (charEntry != null) {
        patchedEntries['character:c2'] = charEntry.copyWith(
          updatedAt: DateTime.now().millisecondsSinceEpoch + 100000,
        );
      }
      await world.manifestProvider.writeLocalManifest(
        localManifest.copyWith(lastSync: 5000, entries: patchedEntries),
      );

      final conflicts = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts.add(c),
      );

      expect(
        world.characters.data['c1'],
        isNotNull,
        reason: 'Non-conflicting character should be pulled immediately',
      );

      expect(conflicts.length, 1);
      expect(conflicts.first.id, equals('c2'));

      await world.engine.resolveConflict(conflicts.first, 'cloud');

      expect(
        world.characters.data['c2']?.name,
        equals('Cloud Bob'),
        reason: 'Cloud version should be applied after resolve',
      );
    },
  );

  test(
    'chat with same session id but different messages surfaces conflict',
    () async {
      final deviceA = SyncWorld();
      await deviceA.characters.put(makeChar('char1', name: 'Alice'));
      await deviceA.chats.put(
        ChatSession(
          id: 's1',
          characterId: 'char1',
          sessionIndex: 0,
          updatedAt: 1000,
          messages: [
            const ChatMessage(
              id: 'm1',
              role: 'assistant',
              content: 'Hello from cloud',
              timestamp: 1000,
            ),
          ],
        ),
      );

      final aManifest = await deviceA.manifestProvider.buildLocalManifest();
      await deviceA.manifestProvider.writeLocalManifest(
        aManifest.copyWith(lastSync: 5000),
      );
      await deviceA.engine.pushEntities(onProgress: (_) {});

      final deviceB = SyncWorld();
      deviceB.cloud.files.addAll(deviceA.cloud.files);
      await deviceB.characters.put(makeChar('char1', name: 'Alice'));
      await deviceB.chats.put(
        ChatSession(
          id: 's1',
          characterId: 'char1',
          sessionIndex: 0,
          updatedAt: 9000,
          messages: [
            const ChatMessage(
              id: 'm2',
              role: 'assistant',
              content: 'Hello from local device',
              timestamp: 9000,
            ),
          ],
        ),
      );

      final bManifest = await deviceB.manifestProvider.buildLocalManifest();
      await deviceB.manifestProvider.writeLocalManifest(
        bManifest.copyWith(lastSync: 8000),
      );

      final conflicts = <SyncConflict>[];
      await deviceB.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts.add(c),
      );

      expect(
        conflicts.any((c) => c.type == 'chat' && c.id == 's1'),
        isTrue,
        reason:
            'Divergent chat content must not be skipped when session ids match',
      );
      expect(
        deviceB.chats.data['s1']?.messages.first.content,
        equals('Hello from local device'),
        reason: 'Unresolved conflict must keep local chat',
      );
    },
  );

  test('chat metadata hash reflects message content, not only session id', () {
    const base = SessionMetadata(
      sessionId: 's1',
      characterId: 'char1',
      sessionIndex: 0,
      updatedAt: 1000,
      messageCount: 0,
      lastMessageContent: '',
      lastMessageTimestamp: 0,
    );
    const withMessages = SessionMetadata(
      sessionId: 's1',
      characterId: 'char1',
      sessionIndex: 0,
      updatedAt: 1000,
      messageCount: 3,
      lastMessageContent: 'Hello',
      lastMessageTimestamp: 2000,
    );

    final idOnlyHash = SyncSerialization.computeSyncHash('s1');
    final metadataHash = SyncSerialization.computeChatMetadataHash(base);
    final divergentHash = SyncSerialization.computeChatMetadataHash(
      withMessages,
    );

    expect(
      metadataHash,
      isNot(equals(idOnlyHash)),
      reason: 'Manifest hash must not be session id alone',
    );
    expect(
      divergentHash,
      isNot(equals(metadataHash)),
      reason: 'Message changes must change the manifest hash',
    );
  });

  test(
    'stale local manifest does not false-conflict characters matching cloud',
    () async {
      final deviceA = SyncWorld();
      await deviceA.characters.put(makeChar('c1', name: 'Alice'));
      await deviceA.characters.put(makeChar('c2', name: 'Bob'));
      final aManifest = await deviceA.manifestProvider.buildLocalManifest();
      await deviceA.manifestProvider.writeLocalManifest(
        aManifest.copyWith(lastSync: 5000),
      );
      await deviceA.engine.pushEntities(onProgress: (_) {});

      final deviceB = SyncWorld();
      deviceB.cloud.files.addAll(deviceA.cloud.files);
      await deviceB.characters.put(makeChar('c1', name: 'Alice'));
      await deviceB.characters.put(makeChar('c2', name: 'Bob'));

      // Stale manifest: wrong hashes but same DB content as cloud.
      final stale = await deviceB.manifestProvider.buildLocalManifest();
      final staleEntries = Map<String, SyncManifestEntry>.from(stale.entries);
      for (final key in ['character:c1', 'character:c2']) {
        final e = staleEntries[key]!;
        staleEntries[key] = e.copyWith(
          hash: 'stale-hash-${e.id}',
          updatedAt: DateTime.now().millisecondsSinceEpoch + 100000,
        );
      }
      await deviceB.manifestProvider.writeLocalManifest(
        stale.copyWith(lastSync: 9000, entries: staleEntries),
      );

      final conflicts = <SyncConflict>[];
      await deviceB.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts.add(c),
      );

      expect(
        conflicts.where((c) => c.type == 'character'),
        isEmpty,
        reason: 'Same character data as cloud must not conflict on stale hash',
      );
    },
  );

  test('resolve all cloud pulls data and rebuilds manifest', () async {
    final deviceA = SyncWorld();
    for (var i = 0; i < 27; i++) {
      await deviceA.characters.put(makeChar('c$i', name: 'Cloud $i'));
    }
    final aManifest = await deviceA.manifestProvider.buildLocalManifest();
    await deviceA.manifestProvider.writeLocalManifest(
      aManifest.copyWith(lastSync: 5000),
    );
    await deviceA.engine.pushEntities(onProgress: (_) {});

    final deviceB = SyncWorld();
    deviceB.cloud.files.addAll(deviceA.cloud.files);
    for (var i = 0; i < 27; i++) {
      await deviceB.characters.put(makeChar('c$i', name: 'Local $i'));
    }

    final yManifest = await deviceB.manifestProvider.buildLocalManifest();
    final patched = Map<String, SyncManifestEntry>.from(yManifest.entries);
    for (var i = 0; i < 27; i++) {
      final key = 'character:c$i';
      patched[key] = patched[key]!.copyWith(
        updatedAt: DateTime.now().millisecondsSinceEpoch + 100000,
      );
    }
    await deviceB.manifestProvider.writeLocalManifest(
      yManifest.copyWith(lastSync: 8000, entries: patched),
    );

    final conflicts = <SyncConflict>[];
    await deviceB.engine.pullEntities(
      onProgress: (_) {},
      onConflict: (c) => conflicts.add(c),
    );
    expect(conflicts, hasLength(27));

    final resolvedKeys = conflicts.map((conflict) => conflict.key).toList();
    await deviceB.engine.applyPendingPull(
      onProgress: (_) {},
      resolvedAsCloud: resolvedKeys,
    );

    for (var i = 0; i < 27; i++) {
      expect(deviceB.characters.data['c$i']?.name, equals('Cloud $i'));
    }
    final manifest = await deviceB.manifestProvider.readLocalManifest();
    expect(manifest.lastSync, greaterThan(0));
    final cloudManifest = SyncManifest.fromJson(
      jsonDecode(deviceB.cloud.files[cloudPath('manifest', 'manifest')]!)
          as Map<String, dynamic>,
    );
    final rebuilt = await deviceB.manifestProvider.buildLocalManifest(
      cloudManifest: cloudManifest,
    );
    expect(
      rebuilt.entries['character:c1']?.hash,
      manifest.entries['character:c1']?.hash,
      reason:
          'Finalize must persist hashes from local DB, not stale cloud manifest',
    );
  });

  test('memory_book push/pull per-entity: push → pull syncs entries', () async {
    final deviceA = SyncWorld();

    final mb = makeMemoryBook('s1', updatedAt: 1000);
    await deviceA.memoryBooks.put(mb);
    await deviceA.chats.put(makeChat('s1', charId: 'char1'));

    final manifest = await deviceA.manifestProvider.buildLocalManifest();
    await deviceA.manifestProvider.writeLocalManifest(manifest);
    await deviceA.engine.pushEntities(onProgress: (_) {});

    expect(
      deviceA.cloud.files.containsKey(cloudPath('memory_book', 's1')),
      isTrue,
      reason: 'memory_book should be pushed as a per-entity file',
    );

    final deviceB = SyncWorld();
    deviceB.cloud.files.addAll(deviceA.cloud.files);

    final conflicts = <SyncConflict>[];
    await deviceB.engine.pullEntities(
      onProgress: (_) {},
      onConflict: (c) => conflicts.add(c),
    );

    expect(
      conflicts.where((c) => c.type == 'memory_book'),
      isEmpty,
      reason: 'Empty device should have no memory_book conflicts on first pull',
    );
    expect(
      deviceB.memoryBooks.data['s1'],
      isNotNull,
      reason: 'memory_book should be pulled to device B',
    );
    expect(deviceB.memoryBooks.data['s1']?.sessionId, equals('s1'));
  });

  test(
    'session lorebook overlays push and pull as one session aggregate',
    () async {
      final sourceOverlays = FakeSessionLorebookOverlayStore();
      final deviceA = SyncWorld(sessionLorebookOverlayStore: sourceOverlays);
      const sessionId = 's1';
      final payload = <String, dynamic>{
        '__sessionLorebookOverlays': true,
        'schemaVersion': 1,
        'sessionId': sessionId,
        'overlays': [
          {
            'chatSessionId': sessionId,
            'lorebookId': 'book',
            'entryId': 'entry',
            'baseContent': 'base',
            'baseContentHash': 'base-hash',
            'content': 'evolved',
            'contentHash': 'content-hash',
          },
        ],
      };
      sourceOverlays.data[sessionId] = payload;
      await deviceA.chats.put(makeChat(sessionId, charId: 'char1'));

      await deviceA.engine.pushEntities(onProgress: (_) {});

      final path = cloudPath('session_lorebook_overlays', sessionId);
      expect(deviceA.cloud.files[path], jsonEncode(payload));
      expect(
        deviceA.cloud.ensuredFolders,
        contains('$cloudBase/session_lorebook_overlays'),
      );

      final targetOverlays = FakeSessionLorebookOverlayStore();
      final deviceB = SyncWorld(sessionLorebookOverlayStore: targetOverlays);
      deviceB.cloud.files.addAll(deviceA.cloud.files);
      await deviceB.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

      expect(targetOverlays.data[sessionId], payload);
    },
  );

  test(
    'memory_book deletion tombstone propagates to cloud on next push',
    () async {
      final world = SyncWorld();

      final mb = makeMemoryBook('s1', updatedAt: 1000);
      await world.memoryBooks.put(mb);
      await world.chats.put(makeChat('s1', charId: 'char1'));

      final manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      expect(
        world.cloud.files.containsKey(cloudPath('memory_book', 's1')),
        isTrue,
      );

      // Simulate deletion: remove from local store + record tombstone
      world.memoryBooks.data.remove('s1');
      world.chats.data.remove('s1');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('gz_sync_deleted_entries');
      final deleted = raw != null
          ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>().toList()
          : <Map<String, dynamic>>[];
      deleted.add({'type': 'memory_book', 'id': 's1'});
      deleted.add({'type': 'chat', 'id': 's1'});
      await prefs.setString('gz_sync_deleted_entries', jsonEncode(deleted));

      final manifest2 = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest2);

      final deletedEntry = manifest2.entries['memory_book:s1'];
      expect(
        deletedEntry?.deleted,
        isTrue,
        reason: 'Deleted memory_book should appear as tombstone in manifest',
      );
    },
  );

  test('chat conflict detection uses metadata hash and updatedAt', () {
    final localHash = SyncSerialization.computeChatMetadataHash(
      const SessionMetadata(
        sessionId: 's1',
        characterId: 'char1',
        sessionIndex: 0,
        updatedAt: 100,
        messageCount: 0,
        lastMessageContent: '',
        lastMessageTimestamp: 0,
      ),
    );
    final cloudHash = SyncSerialization.computeChatMetadataHash(
      const SessionMetadata(
        sessionId: 's1',
        characterId: 'char1',
        sessionIndex: 0,
        updatedAt: 5000,
        messageCount: 2,
        lastMessageContent: 'Cloud',
        lastMessageTimestamp: 5000,
      ),
    );

    final localEntry = SyncManifestEntry(
      type: 'chat',
      id: 's1',
      path: cloudPath('chat', 's1'),
      updatedAt: 100,
      hash: localHash,
    );
    final cloudEntry = SyncManifestEntry(
      type: 'chat',
      id: 's1',
      path: cloudPath('chat', 's1'),
      updatedAt: 5000,
      hash: cloudHash,
    );

    expect(SyncConflictDetector.needsConflict(localEntry, cloudEntry), isFalse);
    expect(
      SyncConflictDetector.needsConflict(
        localEntry.copyWith(updatedAt: 9000),
        cloudEntry,
      ),
      isTrue,
    );
  });

  test(
    'Push skips singleton upload when cloud manifest hash matches but file was wiped',
    () async {
      final world = SyncWorld();
      await world.apiConfigs.put(makeApiConfig('api1', name: 'Test API'));

      final localManifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(localManifest);
      await world.engine.pushEntities(onProgress: (_) {});

      expect(
        world.cloud.files.containsKey(cloudPath('api_presets', 'api_presets')),
        isTrue,
      );

      // Simulate partial wipe: manifest survives, entity JSON deleted.
      world.cloud.files.remove(cloudPath('api_presets', 'api_presets'));
      expect(
        world.cloud.files.containsKey(cloudPath('manifest', 'manifest')),
        isTrue,
        reason: 'Stale manifest remains after partial wipe',
      );

      await world.engine.pushEntities(onProgress: (_) {});

      expect(
        world.cloud.files.containsKey(cloudPath('api_presets', 'api_presets')),
        isTrue,
        reason:
            'Push must re-upload api_presets when manifest hash matches '
            'but the JSON file was deleted during wipe',
      );
    },
  );

  test(
    'Pull character does not keep foreign avatarPath when cloud avatar missing',
    () async {
      final deviceA = SyncWorld();
      const androidAvatarPath =
          '/data/user/0/com.glaze/files/avatars/tokyo.png';
      await deviceA.characters.put(
        makeChar('tokyo', name: 'Project Tokyo', avatarPath: androidAvatarPath),
      );

      final manifest = await deviceA.manifestProvider.buildLocalManifest();
      await deviceA.manifestProvider.writeLocalManifest(manifest);
      await deviceA.engine.pushEntities(onProgress: (_) {});

      deviceA.cloud.files.remove(galleryCloudPath('tokyo', 'avatar', 'png'));

      final deviceB = SyncWorld();
      deviceB.cloud.files.addAll(deviceA.cloud.files);

      await deviceB.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

      final pulled = deviceB.characters.data['tokyo'];
      expect(pulled, isNotNull);
      expect(
        pulled!.avatarPath,
        isNot(anyOf(contains('/data/user/'), contains('com.glaze'))),
        reason:
            'Foreign device avatarPath must not be stored when cloud avatar '
            'binary is missing',
      );
    },
  );

  test(
    'Pull chat re-fetches character avatar when cloud binary exists',
    () async {
      final deviceA = SyncWorld();
      const androidAvatarPath =
          '/data/user/0/com.glaze/files/avatars/tokyo.png';
      await deviceA.characters.put(
        makeChar('tokyo', name: 'Project Tokyo', avatarPath: androidAvatarPath),
      );
      await deviceA.chats.put(makeChat('s1', charId: 'tokyo'));

      final avatarBytes = Uint8List.fromList([10, 20, 30, 40]);
      deviceA.cloud.files[galleryCloudPath('tokyo', 'avatar', 'png')] =
          String.fromCharCodes(avatarBytes);

      final manifest = await deviceA.manifestProvider.buildLocalManifest();
      await deviceA.manifestProvider.writeLocalManifest(manifest);
      await deviceA.engine.pushEntities(onProgress: (_) {});

      final deviceB = SyncWorld();
      deviceB.cloud.files.addAll(deviceA.cloud.files);
      await deviceB.characters.put(makeChar('tokyo', name: 'Project Tokyo'));

      await deviceB.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

      final pulled = deviceB.characters.data['tokyo'];
      expect(pulled?.avatarPath, isNotNull);
      expect(deviceB.images.saved.containsKey('avatars/tokyo.png'), isTrue);
    },
  );

  test(
    'memory_book with local device-specific fields does not false-conflict on pull',
    () async {
      final deviceA = SyncWorld();
      final cloudMb = makeMemoryBook('s1', updatedAt: 1000);
      await deviceA.memoryBooks.put(cloudMb);
      await deviceA.chats.put(makeChat('s1', charId: 'char1'));

      final manifest = await deviceA.manifestProvider.buildLocalManifest();
      await deviceA.manifestProvider.writeLocalManifest(manifest);
      await deviceA.engine.pushEntities(onProgress: (_) {});

      final deviceB = SyncWorld();
      deviceB.cloud.files.addAll(deviceA.cloud.files);
      await deviceB.memoryBooks.put(
        cloudMb.copyWith(updatedAt: 999999, lastProcessedMessageCount: 99),
      );
      await deviceB.chats.put(makeChat('s1', charId: 'char1'));

      final cloudManifest = SyncManifest.fromJson(
        jsonDecode(deviceB.cloud.files[cloudPath('manifest', 'manifest')]!)
            as Map<String, dynamic>,
      );
      final localManifest = await deviceB.manifestProvider.buildLocalManifest(
        cloudManifest: cloudManifest,
      );
      await deviceB.manifestProvider.writeLocalManifest(
        localManifest.copyWith(lastSync: 5000),
      );

      final conflicts = <SyncConflict>[];
      await deviceB.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts.add(c),
      );

      expect(
        conflicts.where((c) => c.type == 'memory_book'),
        isEmpty,
        reason:
            'Semantic memory_book hash ignores device-local updatedAt and '
            'lastProcessedMessageCount (generation LLM settings now live on '
            'PipelineSettings, which is not synced)',
      );
    },
  );

  test(
    'memory_book with local pending drafts does not false-conflict on pull',
    () async {
      final deviceA = SyncWorld();
      final cloudMb = makeMemoryBook('s1', updatedAt: 1000);
      await deviceA.memoryBooks.put(cloudMb);
      await deviceA.chats.put(makeChat('s1', charId: 'char1'));

      final manifest = await deviceA.manifestProvider.buildLocalManifest();
      await deviceA.manifestProvider.writeLocalManifest(manifest);
      await deviceA.engine.pushEntities(onProgress: (_) {});

      final deviceB = SyncWorld();
      deviceB.cloud.files.addAll(deviceA.cloud.files);
      await deviceB.memoryBooks.put(
        cloudMb.copyWith(
          updatedAt: 999999,
          pendingDrafts: const [
            MemoryDraft(
              id: 'draft-local',
              title: 'Local draft',
              content: 'Still being reviewed',
            ),
          ],
        ),
      );
      await deviceB.chats.put(makeChat('s1', charId: 'char1'));

      final cloudManifest = SyncManifest.fromJson(
        jsonDecode(deviceB.cloud.files[cloudPath('manifest', 'manifest')]!)
            as Map<String, dynamic>,
      );
      final localManifest = await deviceB.manifestProvider.buildLocalManifest(
        cloudManifest: cloudManifest,
      );
      await deviceB.manifestProvider.writeLocalManifest(
        localManifest.copyWith(lastSync: 5000),
      );

      final conflicts = <SyncConflict>[];
      await deviceB.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (c) => conflicts.add(c),
      );

      expect(
        conflicts.where((c) => c.type == 'memory_book'),
        isEmpty,
        reason:
            'Local transient pending drafts should not conflict with cloud memory entries',
      );
    },
  );

  test(
    'push records apiKeysIncluded=false in cloud manifest by default',
    () async {
      final world = SyncWorld();
      await world.apiConfigs.put(makeApiConfig('api1', name: 'Test'));
      await world.engine.pushEntities(onProgress: (_) {});

      final raw = world.cloud.files[cloudPath('manifest', 'manifest')];
      expect(raw, isNotNull);
      final manifest = SyncManifest.fromJson(
        jsonDecode(raw!) as Map<String, dynamic>,
      );
      expect(manifest.apiKeysIncluded, isFalse);
    },
  );

  test(
    'Studio preset deletion tombstone propagates to cloud on next push',
    () async {
      SharedPreferences.setMockInitialValues({});
      final world = SyncWorld();
      const preset = StudioPreset(id: 'doomed', name: 'Doomed Preset');
      await world.studioPresets.put(preset);

      var manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      expect(
        world.cloud.files.containsKey(cloudPath('studio_preset', 'doomed')),
        isTrue,
      );

      await world.studioPresets.delete('doomed');
      await SyncDeletionTracker.record('studio_preset', 'doomed');

      manifest = await world.manifestProvider.buildLocalManifest();
      await world.manifestProvider.writeLocalManifest(manifest);
      await world.engine.pushEntities(onProgress: (_) {});

      expect(
        world.cloud.files.containsKey(cloudPath('studio_preset', 'doomed')),
        isFalse,
        reason: 'Cloud file should be deleted after tombstone push',
      );

      final cloudManifest = SyncManifest.fromJson(
        jsonDecode(world.cloud.files[cloudPath('manifest', 'manifest')]!)
            as Map<String, dynamic>,
      );
      expect(
        cloudManifest.entries.containsKey(entryKey('studio_preset', 'doomed')),
        isFalse,
        reason: 'Cloud manifest should no longer list the deleted preset',
      );
    },
  );

  test(
    'Studio config syncs by session id and does not resurrect on pull',
    () async {
      SharedPreferences.setMockInitialValues({});
      final source = SyncWorld();
      await source.studioConfigs.put(
        const StudioConfig(sessionId: 's1', enabled: true),
      );

      var manifest = await source.manifestProvider.buildLocalManifest();
      await source.manifestProvider.writeLocalManifest(manifest);
      await source.engine.pushEntities(onProgress: (_) {});

      expect(
        source.cloud.files.containsKey(cloudPath('studio_config', 's1')),
        isTrue,
      );

      SharedPreferences.setMockInitialValues({});
      final target = SyncWorld();
      target.cloud.files.addAll(source.cloud.files);
      await target.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

      final pulled = await target.studioConfigs.getById('s1');
      expect(pulled, isNotNull);
      expect(pulled!.sessionId, 's1');
      expect(pulled.enabled, isTrue);

      final repeatConflicts = <SyncConflict>[];
      await target.engine.pullEntities(
        onProgress: (_) {},
        onConflict: repeatConflicts.add,
      );
      expect(
        repeatConflicts.where((conflict) => conflict.type == 'studio_config'),
        isEmpty,
      );
    },
  );
}
