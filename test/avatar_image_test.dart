import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:glaze_flutter/shared/utils/avatar_image.dart';

void main() {
  test('falls back when a memoized thumbnail is deleted', () async {
    final root = await Directory.systemTemp.createTemp('glaze_avatar_cache_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final avatar = File(p.join(root.path, 'avatars', 'character.png'));
    final thumbnail = File(p.join(root.path, 'thumbnails', 'character.jpg'));
    await avatar.parent.create(recursive: true);
    await thumbnail.parent.create(recursive: true);
    await avatar.writeAsBytes([1]);
    await thumbnail.writeAsBytes([2]);

    final first = glazeAvatarImage(avatar.path) as FileImage;
    expect(first.file.path, thumbnail.path);

    await thumbnail.delete();

    final second = glazeAvatarImage(avatar.path) as FileImage;
    expect(second.file.path, avatar.path);
  });
}
