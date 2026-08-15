import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_repo_interfaces.dart';
import 'package:glaze_flutter/core/utils/sync_deletion_tracker.dart';
import 'package:glaze_flutter/core/application/session_deletion_store.dart';
import 'package:glaze_flutter/core/application/character_deletion_store.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_manifest.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_run_status.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/extension_context_policy.dart';
import 'package:glaze_flutter/features/extensions/models/extensions_settings.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';

// ─── In-memory fakes (reuse pattern from sync_lifecycle_test) ───────

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
  @override
  Future<List<SessionMetadata>> getAllSessionMetadata() async => [];
  @override
  Future<ChatSession?> getById(String id) async => data[id];
  @override
  Future<void> put(ChatSession s) async {
    data[s.id] = s;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class FakeSessionDeletionStore implements SessionDeletionStore {
  final FakeChatStore chats;

  FakeSessionDeletionStore(this.chats);

  @override
  Future<void> deleteSession(String sessionId) => chats.delete(sessionId);
}

class FakeCharacterDeletionStore implements CharacterDeletionStore {
  final FakeCharacterStore characters;

  FakeCharacterDeletionStore(this.characters);

  @override
  Future<CharacterDeletionResult> deleteCharacters(
    Set<String> characterIds,
  ) async {
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

class FakeMemoryBookStore implements SyncMemoryBookStore {
  final Map<String, MemoryBook> data = {};
  @override
  Future<List<MemoryBook>> getAll() async => data.values.toList();
  @override
  Future<MemoryBook?> getBySessionId(String sid) async => data[sid];
  @override
  Future<void> put(MemoryBook b) async {
    data[b.sessionId] = b;
  }

  @override
  Future<void> deleteBySessionId(String sid) async {
    data.remove(sid);
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

class FakeThemePresetStore implements SyncThemePresetStore {
  List<ThemePreset> data = [];
  @override
  Future<List<ThemePreset>> getAll() async => data;
  @override
  Future<void> putAll(List<ThemePreset> p) async {
    data = List.from(p);
  }
}

class FakeEmbeddingStore implements SyncEmbeddingStore {
  @override
  Future<void> deleteBySourceId(String id) async {}
}

class FakeImageStore implements SyncImageStore {
  @override
  String? absolutePath(String? p) => p;
  @override
  Future<String> saveBytes(
    Uint8List b,
    String sub,
    String fn,
    String ext,
  ) async => '$sub/$fn.$ext';
}

// ─── New fakes for ext-blocks types ─────────────────────────────────

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
  // sessionId → list of blocks
  final Map<String, List<InfoBlock>> data = {};

  @override
  Future<List<String>> getAllSessionIds() async => data.keys.toList();

  @override
  Future<List<InfoBlock>> getBySessionId(String sessionId) async =>
      data[sessionId] ?? [];

  @override
  Future<void> deleteBySessionId(String sessionId) async {
    data.remove(sessionId);
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
  Future<List<Map<String, dynamic>>> getBySessionId(String sessionId) async =>
      data[sessionId] ?? [];

  @override
  Future<void> deleteBySessionId(String sessionId) async {
    data.remove(sessionId);
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
  Future<List<Map<String, dynamic>>> getBySessionId(String sessionId) async =>
      data[sessionId] ?? [];

  @override
  Future<void> deleteBySessionId(String sessionId) async {
    data.remove(sessionId);
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

// ─── Cloud adapter (in-memory) ───────────────────────────────────────

class FakeCloudAdapter implements CloudAdapter {
  final Map<String, String> files = {};

  @override
  Future<bool> isConnected() async => true;
  @override
  Future<void> ensureFolder(String path) async {}
  @override
  Future<void> upload(String path, String data) async {
    files[path] = data;
  }

  @override
  Future<void> uploadBinary(String path, Uint8List data) async {}
  @override
  Future<String> download(String path) async {
    final d = files[path];
    if (d == null) throw CloudFileNotFoundException(path);
    return d;
  }

  @override
  Future<Uint8List> downloadBinary(String path) async => Uint8List(0);
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
    return files.keys
        .where((k) => k.startsWith(path))
        .map(
          (k) =>
              CloudFileInfo(path: k, name: k.split('/').last, isFolder: false),
        )
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> getAccountInfo() async => {};
  @override
  Future<void> invalidateFolderCache() async {}
}

// ─── Manifest provider (in-memory, mirrors sync_lifecycle_test) ──────

class InMemoryManifestProvider implements SyncManifestProvider {
  final SyncManifestBuilder _builder;
  SyncManifest _cached = const SyncManifest(
    deviceId: 'test-device',
    createdAt: 0,
  );
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
    required SyncExtensionPresetStore extensionPresetRepo,
    required SyncExtensionsSettingsStore extensionsSettingsStore,
    required SyncInfoBlockStore infoBlockStore,
    required SyncTrackerSnapshotStore trackerSnapshotStore,
    required SyncTrackerValueStore trackerValueStore,
    required SyncStudioConfigStore studioConfigStore,
  }) : _builder = SyncManifestBuilder(
         characterRepo: characterRepo,
         chatRepo: chatRepo,
         personaRepo: personaRepo,
         presetRepo: presetRepo,
         apiRepo: apiRepo,
         memoryBookRepo: memoryBookRepo,
         lorebookRepo: lorebookRepo,
         themePresetRepo: themePresetRepo,
         extensionPresetRepo: extensionPresetRepo,
         extensionsSettingsStore: extensionsSettingsStore,
         infoBlockStore: infoBlockStore,
         trackerSnapshotStore: trackerSnapshotStore,
         trackerValueStore: trackerValueStore,
         studioConfigStore: studioConfigStore,
       );

  @override
  Future<SyncManifest> buildLocalManifest({SyncManifest? cloudManifest}) async {
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
    _cached = const SyncManifest(deviceId: 'test-device', createdAt: 0);
    _storage.remove('manifest');
  }

  @override
  Future<void> clearDeleted() async {}

  @override
  Future<bool> isDeleted(String type, String id) async => false;
  @override
  Future<String> getDeviceId() => _builder.getDeviceId();
}

// ─── SyncWorld: complete test environment ────────────────────────────

class SyncWorld {
  final FakeCharacterStore characters = FakeCharacterStore();
  final FakeChatStore chats = FakeChatStore();
  final FakePersonaStore personas = FakePersonaStore();
  final FakePresetStore presets = FakePresetStore();
  final FakeApiConfigStore apiConfigs = FakeApiConfigStore();
  final FakeMemoryBookStore memoryBooks = FakeMemoryBookStore();
  final FakeLorebookStore lorebooks = FakeLorebookStore();
  final FakeEmbeddingStore embeddings = FakeEmbeddingStore();
  final FakeImageStore images = FakeImageStore();
  final FakeCloudAdapter cloud = FakeCloudAdapter();
  final FakeThemePresetStore uiThemes = FakeThemePresetStore();
  final FakeExtensionPresetStore extensionPresets = FakeExtensionPresetStore();
  final FakeExtensionsSettingsStore extensionsSettings =
      FakeExtensionsSettingsStore();
  final FakeInfoBlockStore infoBlocks = FakeInfoBlockStore();
  final FakeTrackerSnapshotStore trackerSnapshots = FakeTrackerSnapshotStore();
  final FakeTrackerValueStore trackerValues = FakeTrackerValueStore();
  final FakeStudioConfigStore studioConfigs = FakeStudioConfigStore();
  late final FakeSessionDeletionStore sessionDeletions;
  late final FakeCharacterDeletionStore characterDeletions;
  late final InMemoryManifestProvider manifestProvider;

  SyncWorld() {
    sessionDeletions = FakeSessionDeletionStore(chats);
    characterDeletions = FakeCharacterDeletionStore(characters);
    manifestProvider = InMemoryManifestProvider(
      characterRepo: characters,
      chatRepo: chats,
      personaRepo: personas,
      presetRepo: presets,
      apiRepo: apiConfigs,
      memoryBookRepo: memoryBooks,
      lorebookRepo: lorebooks,
      themePresetRepo: uiThemes,
      extensionPresetRepo: extensionPresets,
      extensionsSettingsStore: extensionsSettings,
      infoBlockStore: infoBlocks,
      trackerSnapshotStore: trackerSnapshots,
      trackerValueStore: trackerValues,
      studioConfigStore: studioConfigs,
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
    extensionPresets,
    extensionsSettings,
    infoBlocks,
    trackerSnapshots,
    trackerValues,
    studioConfigs,
    null,
    null,
    null,
    null,
    null,
    sessionDeletions,
    characterDeletions,
    (_) async {},
  );
}

// ─── Fixtures ─────────────────────────────────────────────────────────

ExtensionPreset makeExtPreset(String id, {String name = 'Preset'}) =>
    ExtensionPreset(id: id, name: name, blocks: const []);

ExtensionPreset makeExtPresetWithBlock(String id) => ExtensionPreset(
  id: id,
  name: 'Rich Preset',
  blocks: [
    BlockConfig(
      id: 'block1',
      name: 'Infoblock',
      type: BlockType.infoblock,
      trigger: BlockTrigger.afterUser,
      prompt: 'Describe the scene',
      contextMessageCount: -1,
      contextPolicy: const ExtensionContextPolicy(
        useMainModelContext: true,
        includeLorebooks: true,
      ),
    ),
  ],
);

ExtensionsSettings makeSettings({
  bool enabled = true,
  String? activePresetId,
}) => ExtensionsSettings(enabled: enabled, activePresetId: activePresetId);

InfoBlock makeInfoBlock(
  String id,
  String sessionId, {
  String blockType = 'infoblock',
  String content = 'Some content',
  int order = 0,
}) => InfoBlock(
  id: id,
  sessionId: sessionId,
  messageId: 'msg1',
  swipeId: 0,
  blockId: 'block1',
  blockName: 'Test Block',
  blockType: blockType,
  content: content,
  createdAt: 1000,
  order: order,
  status: BlockRunStatus.done,
);

// ─── Tests ────────────────────────────────────────────────────────────

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ── Test 1: cloudPath routing ────────────────────────────────────────
  test(
    'cloudPath routes extension_preset, extensions_settings, info_block correctly',
    () {
      expect(
        cloudPath('extension_preset', 'ep-123'),
        equals('$cloudBase/extension_presets/ep-123.json'),
      );
      expect(
        cloudPath('extensions_settings', 'extensions_settings'),
        equals('$cloudBase/extensions_settings.json'),
      );
      expect(
        cloudPath('info_block', 'session-abc'),
        equals('$cloudBase/info_blocks/session-abc.json'),
      );
      expect(
        cloudPath('tracker_value', 'session-abc'),
        equals('$cloudBase/tracker_values/session-abc.json'),
      );
    },
  );

  test('Tracker Values push/pull round-trip preserves live rows', () async {
    final deviceA = SyncWorld();
    deviceA.trackerValues.data['session-1'] = [
      {
        'sessionId': 'session-1',
        'name': 'arc:street_alliance.summary',
        'value': 'Lucy and Danvi are coordinating against the threat.',
        'scope': 'chat',
        'provenance': 'studio_ledger',
        'updatedAt': 1234,
      },
    ];

    await deviceA.engine.pushEntities(onProgress: (_) {});

    expect(
      deviceA.cloud.files.containsKey(cloudPath('tracker_value', 'session-1')),
      isTrue,
    );

    final deviceB = SyncWorld();
    deviceB.cloud.files.addAll(deviceA.cloud.files);

    await deviceB.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    expect(deviceB.trackerValues.data['session-1'], hasLength(1));
    expect(
      deviceB.trackerValues.data['session-1']!.single['name'],
      equals('arc:street_alliance.summary'),
    );
  });

  // ── Test 2: ExtensionPreset push/pull round-trip ─────────────────────
  test('ExtensionPreset push/pull round-trip preserves data', () async {
    final deviceA = SyncWorld();
    final preset = makeExtPresetWithBlock('ep1');
    await deviceA.extensionPresets.put(preset);

    await deviceA.engine.pushEntities(onProgress: (_) {});

    expect(
      deviceA.cloud.files.containsKey(cloudPath('extension_preset', 'ep1')),
      isTrue,
      reason: 'ExtensionPreset should be uploaded to cloud',
    );

    final deviceB = SyncWorld();
    deviceB.cloud.files.addAll(deviceA.cloud.files);

    await deviceB.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    expect(
      deviceB.extensionPresets.data.containsKey('ep1'),
      isTrue,
      reason: 'ExtensionPreset should be pulled to device B',
    );
    expect(deviceB.extensionPresets.data['ep1']!.name, equals('Rich Preset'));
    expect(deviceB.extensionPresets.data['ep1']!.blocks.length, equals(1));
    expect(
      deviceB.extensionPresets.data['ep1']!.blocks.first.prompt,
      equals('Describe the scene'),
    );
    final contextPolicy =
        deviceB.extensionPresets.data['ep1']!.blocks.first.contextPolicy;
    expect(contextPolicy.useMainModelContext, isTrue);
    expect(contextPolicy.includeLorebooks, isTrue);
    expect(
      deviceB.extensionPresets.data['ep1']!.blocks.first.contextMessageCount,
      -1,
    );
  });

  // ── Test 3: ExtensionPreset deletion tracking ─────────────────────────
  test(
    'SyncDeletionTracker.record is called when ExtensionPreset is deleted',
    () async {
      SharedPreferences.setMockInitialValues({});
      const type = 'extension_preset';
      const id = 'ep-to-delete';

      await SyncDeletionTracker.record(type, id);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('gz_sync_deleted_entries');
      expect(raw, isNotNull);

      final list = (jsonDecode(raw!) as List).cast<Map<String, dynamic>>();
      expect(
        list.any((e) => e['type'] == type && e['id'] == id),
        isTrue,
        reason: 'Deleted entry should appear in gz_sync_deleted_entries',
      );
    },
  );

  // ── Test 4: ExtensionsSettings push/pull round-trip ──────────────────
  test('ExtensionsSettings push/pull round-trip preserves data', () async {
    final deviceA = SyncWorld();
    final settings = makeSettings(enabled: true, activePresetId: 'ep1');
    await deviceA.extensionsSettings.put(settings);

    await deviceA.engine.pushEntities(onProgress: (_) {});

    expect(
      deviceA.cloud.files.containsKey('$cloudBase/extensions_settings.json'),
      isTrue,
      reason: 'ExtensionsSettings should be uploaded to cloud',
    );

    final deviceB = SyncWorld();
    deviceB.cloud.files.addAll(deviceA.cloud.files);

    await deviceB.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    final pulledSettings = await deviceB.extensionsSettings.get();
    expect(pulledSettings.enabled, isTrue);
    expect(pulledSettings.activePresetId, equals('ep1'));
  });

  // ── Test 5: InfoBlock infoblock round-trip ────────────────────────────
  test(
    'InfoBlock (infoblock type) push/pull round-trip preserves content',
    () async {
      final deviceA = SyncWorld();
      final block = makeInfoBlock(
        'ib1',
        'session1',
        content: 'The moon rises over the horizon.',
      );
      await deviceA.infoBlocks.insert(block);

      await deviceA.engine.pushEntities(onProgress: (_) {});

      expect(
        deviceA.cloud.files.containsKey(cloudPath('info_block', 'session1')),
        isTrue,
        reason: 'InfoBlock session should be uploaded to cloud',
      );

      final deviceB = SyncWorld();
      deviceB.cloud.files.addAll(deviceA.cloud.files);

      await deviceB.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

      final pulledBlocks = await deviceB.infoBlocks.getBySessionId('session1');
      expect(pulledBlocks.length, equals(1));
      expect(
        pulledBlocks.first.content,
        equals('The moon rises over the horizon.'),
      );
      expect(pulledBlocks.first.blockType, equals('infoblock'));
    },
  );

  // ── Test 6: imageGen normalization on push ────────────────────────────
  test(
    'imageGen block: [IMG:RESULT:/path|json] is normalized to [IMG:GEN:json] on push',
    () async {
      final deviceA = SyncWorld();
      const originalContent =
          '<div>Scene</div>[IMG:RESULT:/Users/alice/app/extblock_12345.png|{"prompt":"a red dragon","style":"oil painting"}]';
      final block = makeInfoBlock(
        'ib1',
        'session1',
        blockType: 'imageGen',
        content: originalContent,
      );
      await deviceA.infoBlocks.insert(block);

      await deviceA.engine.pushEntities(onProgress: (_) {});

      final cloudJson =
          deviceA.cloud.files[cloudPath('info_block', 'session1')];
      expect(cloudJson, isNotNull);

      final cloudData = jsonDecode(cloudJson!) as Map<String, dynamic>;
      final items = (cloudData['items'] as List).cast<Map<String, dynamic>>();
      final uploadedContent = items.first['content'] as String;

      expect(
        uploadedContent.contains('[IMG:RESULT:'),
        isFalse,
        reason: 'Absolute path IMG:RESULT should be stripped before upload',
      );
      expect(
        uploadedContent.contains(
          '[IMG:GEN:{"prompt":"a red dragon","style":"oil painting"}]',
        ),
        isTrue,
        reason: 'IMG:GEN with instruction JSON should replace IMG:RESULT',
      );
    },
  );

  // ── Test 7: imageGen content pulled as-is ────────────────────────────
  test('imageGen block: [IMG:GEN:json] is written to DB as-is on pull', () async {
    final deviceA = SyncWorld();
    // Simulate a block that was already normalized (as it appears on cloud)
    const normalizedContent =
        '<div>Scene</div>[IMG:GEN:{"prompt":"a red dragon","style":"oil painting"}]';
    final block = makeInfoBlock(
      'ib1',
      'session1',
      blockType: 'imageGen',
      content: normalizedContent,
    );
    await deviceA.infoBlocks.insert(block);

    await deviceA.engine.pushEntities(onProgress: (_) {});

    final deviceB = SyncWorld();
    deviceB.cloud.files.addAll(deviceA.cloud.files);

    await deviceB.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

    final pulledBlocks = await deviceB.infoBlocks.getBySessionId('session1');
    expect(pulledBlocks.length, equals(1));
    expect(
      pulledBlocks.first.content,
      equals(normalizedContent),
      reason: 'IMG:GEN content should be stored verbatim in DB',
    );
  });

  // ── Test 8: jsRunner round-trip ───────────────────────────────────────
  test(
    'InfoBlock (jsRunner type) push/pull round-trip preserves HTML+JS content',
    () async {
      final deviceA = SyncWorld();
      const jsContent =
          '<details><summary>Script</summary><pre>const x = 42;</pre></details>'
          '<div class="ext-block-js-result">42</div>';
      final block = makeInfoBlock(
        'ib1',
        'session1',
        blockType: 'jsRunner',
        content: jsContent,
      );
      await deviceA.infoBlocks.insert(block);

      await deviceA.engine.pushEntities(onProgress: (_) {});

      final deviceB = SyncWorld();
      deviceB.cloud.files.addAll(deviceA.cloud.files);

      await deviceB.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});

      final pulledBlocks = await deviceB.infoBlocks.getBySessionId('session1');
      expect(pulledBlocks.length, equals(1));
      expect(pulledBlocks.first.content, equals(jsContent));
      expect(pulledBlocks.first.blockType, equals('jsRunner'));
    },
  );

  // ── Test 9: InfoBlock deletion tracking ──────────────────────────────
  test(
    'SyncDeletionTracker.record is called for info_block on session delete',
    () async {
      SharedPreferences.setMockInitialValues({});

      await SyncDeletionTracker.record('info_block', 'session-xyz');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('gz_sync_deleted_entries');
      expect(raw, isNotNull);

      final list = (jsonDecode(raw!) as List).cast<Map<String, dynamic>>();
      expect(
        list.any((e) => e['type'] == 'info_block' && e['id'] == 'session-xyz'),
        isTrue,
        reason: 'Deleted info_block session should appear in deletion tracker',
      );
    },
  );

  // ── Test 10: buildLocalManifest includes all 3 new entity types ───────
  test(
    'buildLocalManifest includes extension_preset, extensions_settings, info_block entries',
    () async {
      final world = SyncWorld();

      await world.extensionPresets.put(makeExtPreset('ep1', name: 'My Preset'));
      await world.extensionsSettings.put(
        makeSettings(enabled: true, activePresetId: 'ep1'),
      );
      await world.infoBlocks.insert(makeInfoBlock('ib1', 'session1'));

      final manifest = await world.manifestProvider.buildLocalManifest();

      expect(
        manifest.entries.containsKey(entryKey('extension_preset', 'ep1')),
        isTrue,
        reason: 'Manifest should contain extension_preset:ep1',
      );
      expect(
        manifest.entries.containsKey(
          entryKey('extensions_settings', 'extensions_settings'),
        ),
        isTrue,
        reason: 'Manifest should contain extensions_settings singleton',
      );
      expect(
        manifest.entries.containsKey(entryKey('info_block', 'session1')),
        isTrue,
        reason: 'Manifest should contain info_block:session1',
      );

      // Verify paths are correct
      expect(
        manifest.entries[entryKey('extension_preset', 'ep1')]!.path,
        equals('$cloudBase/extension_presets/ep1.json'),
      );
      expect(
        manifest
            .entries[entryKey('extensions_settings', 'extensions_settings')]!
            .path,
        equals('$cloudBase/extensions_settings.json'),
      );
      expect(
        manifest.entries[entryKey('info_block', 'session1')]!.path,
        equals('$cloudBase/info_blocks/session1.json'),
      );
    },
  );
}
