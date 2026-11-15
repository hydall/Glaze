import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/notifications/message_notification_presenter.dart';
import 'package:glaze_flutter/core/utils/platform_paths.dart';
import 'package:path/path.dart' as p;

/// What a message notification shows for a character, and what it must never
/// show for one: the reported symptom was the same character arriving
/// sometimes with its card image, sometimes as a first-letter circle, and the
/// app's own retry arrow in place of the envelope.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('glaze_notif_avatar');
    Directory(p.join(root.path, 'avatars')).createSync();
    Directory(p.join(root.path, 'thumbnails')).createSync();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String avatar(String id) => p.join(root.path, 'avatars', '$id.png');
  String thumbnail(String id) => p.join(root.path, 'thumbnails', '$id.jpg');

  void write(String path) => File(path).writeAsBytesSync(const [0]);

  group('notificationAvatarPath', () {
    test('prefers the thumbnail over the full-resolution card', () {
      // The platform decodes this file into a bitmap before it will draw the
      // notification, and a character card is a multi-megabyte PNG.
      write(avatar('aria'));
      write(thumbnail('aria'));

      expect(notificationAvatarPath(avatar('aria')), thumbnail('aria'));
    });

    test('falls back to the card when no thumbnail was written', () {
      write(avatar('aria'));

      expect(notificationAvatarPath(avatar('aria')), avatar('aria'));
    });

    test('a thumbnail alone is still shown', () {
      write(thumbnail('aria'));

      expect(notificationAvatarPath(avatar('aria')), thumbnail('aria'));
    });

    test('nothing on disk means no avatar rather than a broken one', () {
      expect(notificationAvatarPath(avatar('aria')), isNull);
      expect(notificationAvatarPath(null), isNull);
      expect(notificationAvatarPath(''), isNull);
    });

    test('a URL avatar resolves to nothing instead of throwing', () {
      expect(notificationAvatarPath('https://example.test/a.png'), isNull);
      expect(notificationAvatarPath('data:image/png;base64,AA'), isNull);
    });
  });

  group('copyNotificationAttachment', () {
    // iOS and macOS move an attached file into the system's own store. The
    // stored avatar was attached directly, so every notification took a
    // character's picture out of the library.
    test('hands out a copy and leaves the stored avatar in place', () async {
      final source = thumbnail('aria');
      File(source).writeAsBytesSync(const [1, 2, 3]);

      final copy = await copyNotificationAttachment(source, tempRoot: root);

      expect(copy, isNotNull);
      expect(copy, isNot(source));
      expect(p.extension(copy!), '.jpg');
      expect(File(copy).readAsBytesSync(), const [1, 2, 3]);
      // What the system does with an attachment.
      File(copy).deleteSync();
      expect(File(source).readAsBytesSync(), const [1, 2, 3]);
    });

    test('sweeps copies an earlier failed post left behind', () async {
      final source = avatar('aria');
      write(source);
      final dir = Directory(p.join(root.path, kNotificationAttachmentDirName))
        ..createSync();
      final stale = File(p.join(dir.path, '1000.png'))..writeAsBytesSync([0]);
      final fresh = File(
        p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch - 1}.png'),
      )..writeAsBytesSync([0]);

      final copy = await copyNotificationAttachment(source, tempRoot: root);

      expect(copy, isNotNull);
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(File(source).existsSync(), isTrue);
    });

    test('a source that cannot be copied yields no attachment', () async {
      expect(
        await copyNotificationAttachment(avatar('missing'), tempRoot: root),
        isNull,
      );
    });
  });

  group('androidIconCandidates', () {
    test('the envelope is what a new message wears', () {
      expect(
        MessageNotificationPresenter.androidIconCandidates.first,
        'new_message',
      );
    });

    test('the retry arrow is not a fallback', () {
      // One failed resource lookup used to put a circular refresh arrow on
      // every message notification for the rest of the process.
      expect(
        MessageNotificationPresenter.androidIconCandidates,
        isNot(contains('ic_stat_icon_config_sample')),
      );
    });
  });

  group('resolveGlazeFilePath', () {
    test('leaves a URL alone instead of joining it onto the data root',
        () async {
      // The base has to be cached for this to mean anything — without one the
      // function returns its input whatever it is.
      await getAppDataDir();
      expect(cachedAppDataDir, isNotNull);

      expect(
        resolveGlazeFilePath('https://example.test/a.png'),
        'https://example.test/a.png',
      );
      expect(
        resolveGlazeFilePath('data:image/png;base64,AA'),
        'data:image/png;base64,AA',
      );
      // A genuine relative path still gets the base.
      expect(
        resolveGlazeFilePath('avatars/a.png'),
        p.join(cachedAppDataDir!, 'avatars', 'a.png'),
      );
    });
  });
}
