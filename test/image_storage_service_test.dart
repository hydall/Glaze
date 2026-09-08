import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/services/image_storage_service.dart';

Uint8List makePng(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (final p in image) {
    p.r = 255;
    p.g = 100;
    p.b = 50;
    p.a = 255;
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  late Directory tmpDir;
  late ImageStorageService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('glaze_image_test_');
    service = ImageStorageService(tmpDir.path);
  });

  tearDown(() async {
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
  });

  test('saveAvatar creates avatar PNG and thumbnail JPG', () async {
    final png = makePng(400, 400);
    final path = await service.saveAvatar('char1', png);

    expect(path, endsWith('char1.png'));
    expect(await File(path).exists(), isTrue);

    final thumbPath = p.join(tmpDir.path, 'thumbnails', 'char1.jpg');
    expect(await File(thumbPath).exists(), isTrue);
  });

  test('thumbnailPath returns thumbnail when it exists', () async {
    final png = makePng(200, 200);
    final avatarPath = await service.saveAvatar('c1', png);

    final result = service.thumbnailPath(avatarPath);
    expect(result, isNotNull);
    expect(result, endsWith('c1.jpg'));
  });

  test('thumbnailPath returns null when avatarPath is null', () {
    expect(service.thumbnailPath(null), isNull);
  });

  test('thumbnailPath returns null when avatarPath is empty', () {
    expect(service.thumbnailPath(''), isNull);
  });

  test('thumbnailPath returns null when thumbnail does not exist', () async {
    final avatarPath = p.join(tmpDir.path, 'avatars', 'missing.png');
    expect(service.thumbnailPath(avatarPath), isNull);
  });

  test('deleteAvatar removes avatar and thumbnail', () async {
    final png = makePng(100, 100);
    final avatarPath = await service.saveAvatar('del1', png);
    expect(await File(avatarPath).exists(), isTrue);

    await service.deleteAvatar('del1');

    expect(await File(avatarPath).exists(), isFalse);
    final thumbPath = p.join(tmpDir.path, 'thumbnails', 'del1.jpg');
    expect(await File(thumbPath).exists(), isFalse);
  });

  test('deleteAvatar does not throw when files do not exist', () async {
    await service.deleteAvatar('nonexistent');
  });

  test('saveAvatarFromDataUrl decodes base64 and saves', () async {
    final simplePng = makePng(50, 50);
    final b64 = base64Encode(simplePng);
    final dataUrl2 = 'data:image/png;base64,$b64';

    final result = await service.saveAvatarFromDataUrl('data1', dataUrl2);
    expect(result, isNotNull);
    expect(await File(result!).exists(), isTrue);
  });

  test('saveAvatarFromDataUrl returns null for invalid data URL', () async {
    final result = await service.saveAvatarFromDataUrl('bad', 'not-a-data-url');
    expect(result, isNull);
  });

  test('saveBytes creates file in subfolder', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final path = await service.saveBytes(bytes, 'gallery', 'img1', 'jpg');

    expect(path, contains('gallery'));
    expect(path, endsWith('img1.jpg'));
    expect(await File(path).exists(), isTrue);
    expect(await File(path).readAsBytes(), equals(bytes));
  });

  test('absolutePath returns absolute path unchanged', () async {
    final abs = p.join(tmpDir.path, 'avatars', 'x.png');
    expect(service.absolutePath(abs), equals(abs));
  });

  test('absolutePath returns null for null input', () {
    expect(service.absolutePath(null), isNull);
  });

  test('absolutePath joins with baseDir for relative path', () {
    final result = service.absolutePath('avatars/char1.png');
    expect(
      p.canonicalize(result!),
      equals(p.canonicalize(p.join(tmpDir.path, 'avatars', 'char1.png'))),
    );
  });

  test('thumbnail has reduced dimensions for large images', () async {
    final png = makePng(800, 800);
    final avatarPath = await service.saveAvatar('big1', png);
    final thumbPath = service.thumbnailPath(avatarPath);

    expect(thumbPath, isNotNull);
    final thumbBytes = await File(thumbPath!).readAsBytes();
    final thumbImage = img.decodeImage(thumbBytes);
    expect(thumbImage!.width, lessThan(800));
    expect(thumbImage.height, lessThan(800));
  });

  test('thumbnail for small image is still created', () async {
    final png = makePng(50, 50);
    final avatarPath = await service.saveAvatar('small1', png);
    final thumbPath = service.thumbnailPath(avatarPath);
    expect(thumbPath, isNotNull);
    expect(await File(thumbPath!).exists(), isTrue);
  });

  test('thumbnail bounds both axes while preserving extreme aspect ratio', () {
    final portrait = img.decodeJpg(
      resizeAvatarBytes(makePng(500, 5000), 768)!,
    )!;
    final landscape = img.decodeJpg(
      resizeAvatarBytes(makePng(5000, 500), 768)!,
    )!;

    expect(portrait.width, 410);
    expect(portrait.height, kThumbnailLongSide);
    expect(landscape.width, kThumbnailLongSide);
    expect(landscape.height, 410);
  });

  test('incomplete backfill retries skipped avatars', () async {
    final avatarDir = Directory(p.join(tmpDir.path, 'avatars'));
    await avatarDir.create(recursive: true);
    final valid = File(p.join(avatarDir.path, 'valid.png'));
    final retry = File(p.join(avatarDir.path, 'retry.png'));
    await valid.writeAsBytes(makePng(100, 100));
    await retry.writeAsBytes([1, 2, 3]);

    expect(
      await service.backfillMissingThumbnails([valid.path, retry.path]),
      1,
    );
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('gz_thumb_v6_backfilled'), isNot(true));

    await retry.writeAsBytes(makePng(100, 100));
    expect(
      await service.backfillMissingThumbnails([valid.path, retry.path]),
      1,
    );
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('gz_thumb_v6_backfilled'), isTrue);
  });

  test(
    'thumbnail migration preserves existing files when prefs move',
    () async {
      final thumbDir = Directory(p.join(tmpDir.path, 'thumbnails'));
      await thumbDir.create(recursive: true);
      final thumbnail = File(p.join(thumbDir.path, 'existing.jpg'));
      await thumbnail.writeAsBytes([1, 2, 3]);
      final prefs = await SharedPreferences.getInstance();

      await service.migrateOldThumbnails(prefs);

      expect(await thumbnail.exists(), isTrue);
      expect(prefs.getBool('gz_thumb_v6_migrated'), isTrue);
      expect(
        await File(p.join(tmpDir.path, '.thumbnails-v6-migrated')).exists(),
        isTrue,
      );
      expect(
        await File(
          p.join(tmpDir.path, '.thumbnails-v6-refresh-required'),
        ).exists(),
        isTrue,
      );
    },
  );

  test(
    'adopting an existing v6 library only backfills missing files',
    () async {
      SharedPreferences.setMockInitialValues({
        'gz_thumb_v6_migrated': true,
        'gz_thumb_v6_backfilled': true,
      });
      final prefs = await SharedPreferences.getInstance();

      await service.migrateOldThumbnails(prefs);

      expect(prefs.getBool('gz_thumb_v6_backfilled'), isFalse);
      expect(
        await File(
          p.join(tmpDir.path, '.thumbnails-v6-refresh-required'),
        ).exists(),
        isFalse,
      );
    },
  );

  group('absolutePath rebasing (iOS sandbox UUID change)', () {
    test('relative path is joined onto baseDir', () {
      // Compare path-equivalently (separator-agnostic).
      expect(
        p.equals(
          service.absolutePath('avatars/x.png')!,
          p.join(tmpDir.path, 'avatars', 'x.png'),
        ),
        isTrue,
      );
    });

    test(
      'existing absolute path is returned unchanged (Android/Windows)',
      () async {
        // Save a real avatar so the absolute path exists, then confirm
        // absolutePath returns it verbatim — no rebasing when the file is valid.
        final png = makePng(80, 80);
        final abs = await service.saveAvatar('valid', png);
        expect(File(abs).isAbsolute, isTrue);
        expect(File(abs).existsSync(), isTrue);
        expect(service.absolutePath(abs), equals(abs));
      },
    );

    test(
      'stale absolute path under /Glaze/ is rebased onto current baseDir',
      () async {
        // Simulate an iOS path persisted under an OLD container UUID. The file
        // does not exist at that absolute location, but the same sub-path
        // exists under the current baseDir → should rebase.
        //
        // The rebasing only triggers when the input is recognised as absolute.
        // On the Windows test host a unix path like /var/... is NOT absolute,
        // so gate this assertion to POSIX hosts (where iOS-style paths apply).
        final png = makePng(80, 80);
        await service.saveAvatar('moved', png); // creates avatars/moved.png

        const stale =
            '/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Glaze/avatars/moved.png';
        final resolved = service.absolutePath(stale)!;
        if (File(stale).isAbsolute) {
          expect(
            p.equals(resolved, p.join(tmpDir.path, 'avatars', 'moved.png')),
            isTrue,
            reason: 'stale /Glaze/ path should rebase onto current baseDir',
          );
          expect(File(resolved).existsSync(), isTrue);
        } else {
          // Non-absolute on this host → treated as relative, joined onto base.
          expect(resolved, contains('moved.png'));
        }
      },
    );

    test(
      'prefers current channel copy over an existing sibling file',
      () async {
        final parent = await Directory.systemTemp.createTemp('glaze_channels_');
        addTearDown(() => parent.delete(recursive: true));
        final nightly = Directory(p.join(parent.path, 'Glaze-nightly'));
        final stable = Directory(p.join(parent.path, 'Glaze'));
        await nightly.create(recursive: true);
        await stable.create(recursive: true);
        final current = File(p.join(nightly.path, 'avatars', 'shared.png'));
        final sibling = File(p.join(stable.path, 'avatars', 'shared.png'));
        await current.parent.create(recursive: true);
        await sibling.parent.create(recursive: true);
        await current.writeAsBytes([1]);
        await sibling.writeAsBytes([2]);

        final channelService = ImageStorageService(nightly.path);

        expect(
          p.equals(channelService.absolutePath(sibling.path)!, current.path),
          isTrue,
        );
      },
    );

    test('recognizes staging and nightly sibling roots', () async {
      final parent = await Directory.systemTemp.createTemp('glaze_channels_');
      addTearDown(() => parent.delete(recursive: true));
      final stable = Directory(p.join(parent.path, 'Glaze'));
      final target = File(p.join(stable.path, 'gallery', 'char', 'image.png'));
      await target.parent.create(recursive: true);
      await target.writeAsBytes([1]);
      final stableService = ImageStorageService(stable.path);

      for (final root in ['Glaze-staging', 'Glaze-nightly']) {
        final sibling = p.join(
          parent.path,
          root,
          'gallery',
          'char',
          'image.png',
        );
        expect(
          p.equals(stableService.absolutePath(sibling)!, target.path),
          isTrue,
        );
      }
    });

    test('empty and null are passed through', () {
      expect(service.absolutePath(''), equals(''));
      expect(service.absolutePath(null), isNull);
    });
  });
}

String base64Encode(Uint8List bytes) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final buf = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final b0 = bytes[i];
    final b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    final b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    buf.write(chars[(b0 >> 2) & 0x3F]);
    buf.write(chars[((b0 << 4) | (b1 >> 4)) & 0x3F]);
    buf.write(
      i + 1 < bytes.length ? chars[((b1 << 2) | (b2 >> 6)) & 0x3F] : '=',
    );
    buf.write(i + 2 < bytes.length ? chars[b2 & 0x3F] : '=');
  }
  return buf.toString();
}
