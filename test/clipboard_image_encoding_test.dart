import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/platform/clipboard_images.dart';

void main() {
  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  group('image MIME sniffing', () {
    test('reads the format out of the header, not the name', () {
      expect(
        sniffImageMimeType(bytes([0x89, 0x50, 0x4E, 0x47, 1])),
        'image/png',
      );
      expect(sniffImageMimeType(bytes([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
      expect(
        sniffImageMimeType(bytes([0x47, 0x49, 0x46, 0x38, 0x39])),
        'image/gif',
      );
      expect(sniffImageMimeType(bytes([0x42, 0x4D, 0, 0])), 'image/bmp');
      expect(
        sniffImageMimeType(
          bytes([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]),
        ),
        'image/webp',
      );
    });

    test('answers null for anything it does not recognise', () {
      expect(sniffImageMimeType(bytes([1, 2, 3, 4])), isNull);
      expect(sniffImageMimeType(bytes([])), isNull);
      // A RIFF container that is not WEBP (a WAV, say) is not an image.
      expect(
        sniffImageMimeType(
          bytes([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45]),
        ),
        isNull,
      );
    });
  });

  group('data URL encoding', () {
    test('a clipboard bitmap is typed from its own header', () {
      final jpeg = bytes([0xFF, 0xD8, 0xFF, 0xE0, 0x42]);

      expect(
        encodeImageDataUrl(jpeg),
        'data:image/jpeg;base64,${base64Encode(jpeg)}',
      );
    });

    test('the header wins over a misleading extension', () {
      final png = bytes([0x89, 0x50, 0x4E, 0x47, 7]);

      expect(
        encodeImageDataUrl(png, fallbackPath: '/tmp/screenshot.jpg'),
        startsWith('data:image/png;base64,'),
      );
    });

    test('an unrecognised header falls back to the extension', () {
      final unknown = bytes([1, 2, 3, 4]);

      expect(
        encodeImageDataUrl(unknown, fallbackPath: '/tmp/pic.webp'),
        startsWith('data:image/webp;base64,'),
      );
      // No path and no readable header: PNG is the safe default, since it is
      // what every desktop clipboard hands over.
      expect(encodeImageDataUrl(unknown), startsWith('data:image/png;base64,'));
    });
  });
}
