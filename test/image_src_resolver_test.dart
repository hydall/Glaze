import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/utils/image_src.dart';

void main() {
  group('imageProviderForSrc', () {
    test('returns null for empty / blank sources', () {
      expect(imageProviderForSrc(''), isNull);
      expect(imageProviderForSrc('   '), isNull);
    });

    test('decodes base64 data URIs', () {
      final provider = imageProviderForSrc('data:image/png;base64,AQID');
      expect(provider, isA<MemoryImage>());
      expect((provider as MemoryImage).bytes, [1, 2, 3]);
    });

    test('decodes percent-encoded data URIs', () {
      final provider = imageProviderForSrc('data:image/svg+xml,%3Csvg%3E');
      expect(provider, isA<MemoryImage>());
      expect(
        String.fromCharCodes((provider as MemoryImage).bytes),
        '<svg>',
      );
    });

    test('returns null for a malformed data URI instead of throwing', () {
      expect(imageProviderForSrc('data:image/png;base64,!!!not-base64!!!'),
          isNull);
    });

    test('remote URLs go through the shared network image cache', () {
      final provider = imageProviderForSrc('https://example.com/a.png');
      expect(provider, isA<CachedNetworkImageProvider>());
      expect((provider as CachedNetworkImageProvider).url,
          'https://example.com/a.png');
      expect(provider.headers?['User-Agent'], isNotNull);
    });

    test('remote URLs send a same-origin Referer', () {
      // Some CDNs 403 a referer-less request from the bare Dart client while
      // happily serving the WebView, which always fetches as a sub-resource
      // of a real page and so always sends one.
      final provider = imageProviderForSrc('https://cdn.example.com/a.webp');
      expect((provider as CachedNetworkImageProvider).headers?['Referer'],
          'https://cdn.example.com/');
    });

    test('surrounding whitespace does not turn a URL into a file path', () {
      // The WebView trims this when loading <img src>, so the picture shows in
      // the message; the viewer has to trim it too or it looks for a file.
      final provider = imageProviderForSrc('  https://example.com/a.png  ');
      expect(provider, isA<CachedNetworkImageProvider>());
    });

    test('loopback __glaze_file__ URLs read the file directly', () {
      final path = Platform.isWindows ? r'C:\Glaze\avatars\a.png' : '/tmp/a.png';
      final url = Uri.parse('http://127.0.0.1:51234/').replace(
        path: '/__glaze_file__',
        queryParameters: {'path': path},
      ).toString();

      final provider = imageProviderForSrc(url);
      expect(provider, isA<FileImage>());
      expect((provider as FileImage).file.path, endsWith('a.png'));
    });

    test('file:// URLs resolve to a FileImage', () {
      final provider = imageProviderForSrc(
        Uri.file(Platform.isWindows ? r'C:\tmp\a.png' : '/tmp/a.png').toString(),
      );
      expect(provider, isA<FileImage>());
      expect((provider as FileImage).file.path, endsWith('a.png'));
    });
  });

  group('glazeFilePathFromLoopbackUrl', () {
    test('extracts the path query parameter', () {
      expect(
        glazeFilePathFromLoopbackUrl(
          'http://127.0.0.1:9/__glaze_file__?path=%2Ftmp%2Fa.png',
        ),
        '/tmp/a.png',
      );
    });

    test('ignores ordinary remote URLs', () {
      expect(glazeFilePathFromLoopbackUrl('https://example.com/a.png'), isNull);
      expect(
        glazeFilePathFromLoopbackUrl('http://127.0.0.1:9/index.html'),
        isNull,
      );
      expect(
        glazeFilePathFromLoopbackUrl('http://evil.test/__glaze_file__?path=/x'),
        isNull,
      );
    });
  });
}
