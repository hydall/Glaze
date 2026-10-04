import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_binary_asset_syncer.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_repo_interfaces.dart';

// ─── In-memory fakes ─────────────────────────────────────────────────────────

class FakeAdapter implements CloudAdapter {
  final Map<String, Uint8List> binaries = {};
  final List<String> ensuredFolders = [];
  final List<String> downloadAttempts = [];

  @override
  Future<void> ensureFolder(String path) async => ensuredFolders.add(path);

  @override
  Future<void> uploadBinary(String path, Uint8List data) async {
    binaries[path] = data;
  }

  @override
  Future<Uint8List> downloadBinary(String path) async {
    downloadAttempts.add(path);
    final bytes = binaries[path];
    if (bytes == null) throw CloudFileNotFoundException(path);
    return bytes;
  }

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<void> invalidateFolderCache() async {}

  @override
  Future<void> upload(String path, String data) =>
      throw UnimplementedError('upload');

  @override
  Future<String> download(String path) => throw UnimplementedError('download');

  @override
  Future<void> deleteFile(String path) => throw UnimplementedError('deleteFile');

  @override
  Future<void> deleteFolder(String path) =>
      throw UnimplementedError('deleteFolder');

  @override
  Future<List<CloudFileInfo>> listFolder(String path) =>
      throw UnimplementedError('listFolder');

  @override
  Future<Map<String, dynamic>?> getAccountInfo() =>
      throw UnimplementedError('getAccountInfo');
}

class FakePresetStore implements SyncPresetStore {
  final Map<String, Preset> data = {};

  @override
  Future<List<Preset>> getAll() async => data.values.toList();

  @override
  Future<Preset?> getById(String id) async => data[id];

  @override
  Future<void> put(Preset p) async => data[p.id] = p;

  @override
  Future<void> delete(String id) async => data.remove(id);
}

class UnusedCharacterStore implements SyncCharacterStore {
  @override
  Future<List<Character>> getAll() => throw UnimplementedError();

  @override
  Future<Character?> getById(String id) => throw UnimplementedError();

  @override
  Future<void> put(Character c) => throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();
}

class UnusedPersonaStore implements SyncPersonaStore {
  @override
  Future<List<Persona>> getAll() => throw UnimplementedError();

  @override
  Future<Persona?> getById(String id) => throw UnimplementedError();

  @override
  Future<void> put(Persona p) => throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();
}

/// Mirrors ImageStorageService's path semantics: relative paths hang off the
/// data dir, `saveBytes` writes `<base>/<subfolder>/<name>.<ext>`.
class FakeImageStore implements SyncImageStore {
  final String baseDir;
  FakeImageStore(this.baseDir);

  @override
  String? absolutePath(String? relativePath) {
    if (relativePath == null || relativePath.isEmpty) return relativePath;
    if (p.isAbsolute(relativePath)) return relativePath;
    return p.join(baseDir, relativePath);
  }

  @override
  Future<String> saveBytes(
    Uint8List bytes,
    String subfolder,
    String filename,
    String ext,
  ) async {
    final dir = Directory(p.join(baseDir, subfolder));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = p.join(dir.path, '$filename.$ext');
    await File(path).writeAsBytes(bytes);
    return path;
  }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  late Directory tempDir;
  late FakeAdapter adapter;
  late FakePresetStore presets;
  late FakeImageStore images;
  late SyncBinaryAssetSyncer syncer;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('glaze_preset_sync');
    adapter = FakeAdapter();
    presets = FakePresetStore();
    images = FakeImageStore(tempDir.path);
    syncer = SyncBinaryAssetSyncer(
      adapter,
      UnusedCharacterStore(),
      UnusedPersonaStore(),
      presets,
      images,
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Writes a cover file at the relative path a preset would store.
  void writeCover(String relativePath, List<int> bytes) {
    final file = File(p.join(tempDir.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  group('pushPresetImages', () {
    test('uploads the cover of a preset that has one on disk', () async {
      writeCover('avatars/preset_p1_10.png', [1, 2, 3]);
      presets.data['p1'] = const Preset(
        id: 'p1',
        name: 'P1',
        imagePath: 'avatars/preset_p1_10.png',
      );

      await syncer.pushPresetImages();

      expect(
        adapter.binaries[presetImageCloudPath('p1', 'png')],
        Uint8List.fromList([1, 2, 3]),
      );
      expect(adapter.ensuredFolders, contains('$cloudBase/preset_images/p1'));
    });

    test('skips bundled asset covers and presets without one', () async {
      presets.data['featured_clone'] = const Preset(
        id: 'featured_clone',
        name: 'Clone',
        imagePath: 'assets/presets/renri.jpg',
      );
      presets.data['plain'] = const Preset(id: 'plain', name: 'Plain');

      await syncer.pushPresetImages();

      expect(adapter.binaries, isEmpty);
    });

    test('skips a cover whose file is missing locally', () async {
      presets.data['p1'] = const Preset(
        id: 'p1',
        name: 'P1',
        imagePath: 'avatars/preset_p1_10.png',
      );

      await syncer.pushPresetImages();

      expect(adapter.binaries, isEmpty);
    });
  });

  group('pullPresetImages', () {
    test('downloads a cover this device does not have yet', () async {
      adapter.binaries[presetImageCloudPath('p1', 'png')] = Uint8List.fromList(
        [4, 5, 6],
      );
      presets.data['p1'] = const Preset(
        id: 'p1',
        name: 'P1',
        imagePath: 'avatars/preset_p1_10.png',
      );

      await syncer.pullPresetImages();

      final saved = File(p.join(tempDir.path, 'avatars/preset_p1_10.png'));
      expect(saved.existsSync(), isTrue);
      expect(saved.readAsBytesSync(), [4, 5, 6]);
      // The stored path is device-independent, so it must survive the pull.
      expect(presets.data['p1']!.imagePath, 'avatars/preset_p1_10.png');
    });

    test('does not re-download a cover that is already on disk', () async {
      writeCover('avatars/preset_p1_10.png', [1, 2, 3]);
      presets.data['p1'] = const Preset(
        id: 'p1',
        name: 'P1',
        imagePath: 'avatars/preset_p1_10.png',
      );

      await syncer.pullPresetImages();

      expect(adapter.downloadAttempts, isEmpty);
    });

    test('a new version of a cover is fetched on its own path', () async {
      // Another device replaced the image: the version suffix changed, so the
      // old local file no longer satisfies the preset.
      writeCover('avatars/preset_p1_10.png', [1, 2, 3]);
      adapter.binaries[presetImageCloudPath('p1', 'png')] = Uint8List.fromList(
        [9, 9, 9],
      );
      presets.data['p1'] = const Preset(
        id: 'p1',
        name: 'P1',
        imagePath: 'avatars/preset_p1_20.png',
      );

      await syncer.pullPresetImages();

      final saved = File(p.join(tempDir.path, 'avatars/preset_p1_20.png'));
      expect(saved.readAsBytesSync(), [9, 9, 9]);
    });

    test('keeps the stored path when the cloud has no cover', () async {
      presets.data['p1'] = const Preset(
        id: 'p1',
        name: 'P1',
        imagePath: 'avatars/preset_p1_10.png',
      );

      await syncer.pullPresetImages();

      // Nulling it here would tell the device that owns the file to drop it.
      expect(presets.data['p1']!.imagePath, 'avatars/preset_p1_10.png');
    });

    test('ignores bundled asset covers', () async {
      presets.data['clone'] = const Preset(
        id: 'clone',
        name: 'Clone',
        imagePath: 'assets/presets/renri.jpg',
      );

      await syncer.pullPresetImages();

      expect(adapter.downloadAttempts, isEmpty);
      expect(presets.data['clone']!.imagePath, 'assets/presets/renri.jpg');
    });
  });
}
