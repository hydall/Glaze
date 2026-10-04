import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/bridge/chat_webview_environment.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_webview_settings.dart';

void main() {
  group('chat WebView local media policy', () {
    late Directory root;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      root = await Directory.systemTemp.createTemp('glaze-media-policy-');
      setChatWebViewAndroidFileRoot(root.path);
      for (final directory in [
        'avatars',
        'thumbnails',
        'generated',
        'gallery/character',
      ]) {
        await Directory(
          '${root.path}${Platform.pathSeparator}$directory',
        ).create(recursive: true);
      }
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      setChatWebViewAndroidFileRoot('');
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('allows regular raster files in every approved media root', () async {
      for (final entry in <String, String>{
        'avatars/avatar.png': 'png',
        'thumbnails/thumb.JPG': 'jpg',
        'generated/result.webp': 'webp',
        'gallery/character/frame.avif': 'avif',
      }.entries) {
        final file = File(
          '${root.path}${Platform.pathSeparator}'
          '${entry.key.replaceAll('/', Platform.pathSeparator)}',
        );
        await file.writeAsString(entry.value);
        expect(
          await isAllowedGlazeMediaFile(file.path),
          isTrue,
          reason: entry.key,
        );
      }
    });

    test(
      'denies databases, journals, SVG, non-media roots, and directories',
      () async {
        final denied = [
          File('${root.path}${Platform.pathSeparator}glaze.db'),
          File('${root.path}${Platform.pathSeparator}glaze.db-wal'),
          File('${root.path}${Platform.pathSeparator}glaze.db-shm'),
          File(
            '${root.path}${Platform.pathSeparator}avatars'
            '${Platform.pathSeparator}active.svg',
          ),
          File(
            '${root.path}${Platform.pathSeparator}settings'
            '${Platform.pathSeparator}secret.png',
          ),
        ];
        await denied.last.parent.create(recursive: true);
        for (final file in denied) {
          await file.writeAsString('denied');
          expect(await isAllowedGlazeMediaFile(file.path), isFalse);
        }
        expect(
          await isAllowedGlazeMediaFile(
            '${root.path}${Platform.pathSeparator}avatars',
          ),
          isFalse,
        );
      },
    );

    test('denies traversal and sibling-prefix paths', () async {
      final outside = File(
        '${root.parent.path}${Platform.pathSeparator}outside.png',
      );
      await outside.writeAsString('outside');
      addTearDown(() async {
        if (await outside.exists()) await outside.delete();
      });

      expect(
        await isAllowedGlazeMediaFile(
          '${root.path}${Platform.pathSeparator}avatars'
          '${Platform.pathSeparator}..${Platform.pathSeparator}..'
          '${Platform.pathSeparator}${outside.uri.pathSegments.last}',
        ),
        isFalse,
      );
      expect(await isAllowedGlazeMediaFile(outside.path), isFalse);
    });

    test('denies a file symlink that escapes an approved media root', () async {
      final outside = File(
        '${root.parent.path}${Platform.pathSeparator}outside-link-target.png',
      );
      await outside.writeAsString('outside');
      final link = Link(
        '${root.path}${Platform.pathSeparator}avatars'
        '${Platform.pathSeparator}linked.png',
      );
      addTearDown(() async {
        if (await outside.exists()) await outside.delete();
      });
      try {
        await link.create(outside.path);
      } on FileSystemException {
        return;
      }

      expect(await isAllowedGlazeMediaFile(link.path), isFalse);
    });

    test('uses case-insensitive path semantics on Windows', () async {
      if (!Platform.isWindows) return;
      final file = File(
        '${root.path}${Platform.pathSeparator}avatars'
        '${Platform.pathSeparator}case.png',
      );
      await file.writeAsString('png');

      expect(await isAllowedGlazeMediaFile(file.path.toUpperCase()), isTrue);
    });
  });

  group('chat WebView server origin separation', () {
    final source = File(
      'lib/features/chat/bridge/chat_webview_environment.dart',
    ).readAsStringSync();

    test('iOS and Windows start a dedicated local-file server', () {
      expect(
        RegExp(
          r'TargetPlatform\.iOS[\s\S]*?'
          r'_startChatWebViewLocalFileServer\(\)[\s\S]*?'
          r'_startChatWebViewBundleServer\(\)',
        ).hasMatch(source),
        isTrue,
      );
      expect(
        RegExp(
          r'WebViewEnvironment\.create\(\)[\s\S]*?'
          r'_startChatWebViewLocalFileServer\(\)[\s\S]*?'
          r'_startChatWebViewAssetServer\(\)',
        ).hasMatch(source),
        isTrue,
      );
    });

    test('only the local-file server dispatches the file endpoint', () {
      expect(
        RegExp("request\\.uri\\.path == '/__glaze_file__'").allMatches(source),
        isEmpty,
      );
      expect(
        RegExp(
          "request\\.uri\\.path != '/__glaze_file__'",
        ).allMatches(source).length,
        1,
      );
    });

    // INV-IG9: the port in a `/__glaze_file__` URL only exists for the launch
    // that produced it, so a message that stored one is unwrapped on the way
    // in rather than migrated — and the relative path a block is stored with
    // has to resolve at all.
    test('a stale local-file URL resolves as the file it used to serve', () {
      expect(
        source,
        contains('final stored = glazeFilePathFromLoopbackUrl(source);'),
      );
      expect(
        RegExp(
          r'final stored = glazeFilePathFromLoopbackUrl\(source\);\s*'
          r'if \(stored != null\) return chatWebViewResolveLocalFileUrl\(stored\);'
          r"[\s\S]*?source\.startsWith\('http://'\)",
        ).hasMatch(source),
        isTrue,
        reason: 'the unwrap must run before the remote-URL passthrough',
      );
    });

    test('a path relative to the data root is a local-file candidate', () {
      expect(
        source,
        contains('_allowedGlazeMediaDirectories.contains(segments.first)'),
      );
    });

    test('file responses allow only GET and HEAD', () {
      expect(source, contains("request.method != 'GET'"));
      expect(source, contains("request.method != 'HEAD'"));
      expect(source, contains("HttpHeaders.allowHeader, 'GET, HEAD'"));
    });

    test('every server dispatches its requests concurrently and guarded', () {
      // Awaiting a handler inside the accept loop served the page one file at
      // a time, and a failure after the headers were sent used to escape the
      // loop and kill the server for the rest of the session.
      expect(
        RegExp(
          r'await for \(final request in server\) \{\s*'
          r'unawaited\(_handleServerRequest\(',
        ).allMatches(source).length,
        3,
      );
      expect(source, contains('Future<void> _handleServerRequest('));
    });
  });
}
