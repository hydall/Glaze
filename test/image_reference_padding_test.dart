import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/image_reference_collector.dart';
import 'package:glaze_flutter/features/image_gen/services/novelai_reference_image.dart';
import 'package:image/image.dart' as img;

/// A NovelAI-generated PNG: opaque except for the `stealth_pngcomp` marker
/// hidden in the lowest alpha bit, down the columns from the top-left.
img.Image _withHiddenData(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(255, 0, 0, 255));
  final marker = 'stealth_pngcomp'.codeUnits;
  for (var bit = 0; bit < marker.length * 8; bit++) {
    final on = marker[bit ~/ 8] >> (7 - bit % 8) & 1;
    image.getPixel(bit ~/ height, bit % height).a = on == 1 ? 255 : 254;
  }
  return image;
}

Uint8List _solidPng(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(255, 0, 0));
  return Uint8List.fromList(img.encodePng(image));
}

String _dataUrl(int width, int height) =>
    'data:image/png;base64,${base64Encode(_solidPng(width, height))}';

void main() {
  group('NovelAIConstants.referenceCanvas', () {
    test('picks the canvas closest in aspect ratio', () {
      expect(NovelAIConstants.referenceCanvas(200, 400), (1024, 1536));
      expect(NovelAIConstants.referenceCanvas(400, 200), (1536, 1024));
      expect(NovelAIConstants.referenceCanvas(300, 300), (1472, 1472));
      // Nearly square goes square, not by orientation.
      expect(NovelAIConstants.referenceCanvas(1100, 1000), (1472, 1472));
      expect(NovelAIConstants.referenceCanvas(1000, 1100), (1472, 1472));
    });
  });

  group('NovelAIConstants.referenceCutSizes', () {
    test('has 97 sizes of about a megapixel, sides in multiples of 64', () {
      final sizes = NovelAIConstants.referenceCutSizes;
      expect(sizes, hasLength(97));
      expect(sizes.first, (256, 4096));
      expect(sizes[48], (1024, 1024));
      expect(sizes.last, (4096, 256));
      for (final (w, h) in sizes) {
        expect(w % 64, 0);
        expect(h % 64, 0);
        expect(w * h, lessThanOrEqualTo(1024 * 1024));
      }
    });

    test('picks the size closest in shape', () {
      expect(NovelAIConstants.referenceCutSize(500, 500), (1024, 1024));
      expect(NovelAIConstants.referenceCutSize(832, 1216), (832, 1216));
      expect(NovelAIConstants.referenceCutSize(1216, 832), (1216, 832));
    });
  });

  group('cutNovelAiReference', () {
    test('covers the closest size and cuts the middle', () {
      // 200x400 → 704x1408 (ratio 0.5), scaled exactly, nothing cut.
      final cut = img.decodeImage(cutNovelAiReference(_solidPng(200, 400))!)!;
      expect((cut.width, cut.height), (704, 1408));
      expect(cut.getPixel(0, 0).r, 255);
    });

    test('keeps transparency', () {
      final image = img.Image(width: 300, height: 300, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(0, 255, 0, 0));
      final cut = img.decodeImage(
        cutNovelAiReference(Uint8List.fromList(img.encodePng(image)))!,
      )!;
      expect((cut.width, cut.height), (1024, 1024));
      expect(cut.numChannels, 4);
      expect(cut.getPixel(512, 512).a, 0);
    });

    test('sends a picture already at a V5 size untouched', () {
      final bytes = _solidPng(832, 1216);
      expect(cutNovelAiReference(bytes), same(bytes));
    });

    test('takes NovelAI hidden data out even at a V5 size', () {
      final bytes = Uint8List.fromList(
        img.encodePng(_withHiddenData(832, 1216)),
      );
      final cut = img.decodeImage(cutNovelAiReference(bytes)!)!;
      expect(cut.getPixel(0, 0).a, 255);
      expect(cut.getPixel(0, 1).a, 255);
    });

    test('returns null for bytes that are not an image', () {
      expect(
        cutNovelAiReference(Uint8List.fromList(const [1, 2, 3, 4])),
        isNull,
      );
    });
  });

  group('scrubNovelAiHiddenData', () {
    test('restores alpha 254 to 255 only when the marker is there', () {
      final hidden = _withHiddenData(64, 64);
      expect(hasNovelAiHiddenData(hidden), isTrue);
      expect(scrubNovelAiHiddenData(hidden), isTrue);
      expect(hidden.getPixel(0, 0).a, 255);

      final plain = img.Image(width: 64, height: 64, numChannels: 4);
      img.fill(plain, color: img.ColorRgba8(0, 0, 0, 254));
      expect(scrubNovelAiHiddenData(plain), isFalse);
      expect(plain.getPixel(0, 0).a, 254);
    });
  });

  group('padNovelAiReference', () {
    test('fits portrait, landscape and square onto the accepted canvases', () {
      final portrait = img.decodeImage(
        padNovelAiReference(_solidPng(200, 400))!,
      )!;
      expect((portrait.width, portrait.height), (1024, 1536));

      final landscape = img.decodeImage(
        padNovelAiReference(_solidPng(400, 200))!,
      )!;
      expect((landscape.width, landscape.height), (1536, 1024));

      final square = img.decodeImage(
        padNovelAiReference(_solidPng(300, 300))!,
      )!;
      expect((square.width, square.height), (1472, 1472));
    });

    test('keeps the whole image and pads the rest black', () {
      // 200x400 on a 1024x1536 canvas scales to 768x1536, centred: the side
      // bands are black and the middle is still the source.
      final padded = img.decodeImage(
        padNovelAiReference(_solidPng(200, 400))!,
      )!;
      expect(padded.getPixel(0, 0).r, 0);
      expect(padded.getPixel(0, 0).g, 0);
      expect(padded.getPixel(0, 0).b, 0);
      expect(padded.getPixel(512, 768).r, 255);
    });

    test('returns null for bytes that are not an image', () {
      expect(
        padNovelAiReference(Uint8List.fromList(const [1, 2, 3, 4])),
        isNull,
      );
    });
  });

  group('ImageReferenceCollector reference policy', () {
    Future<List<Map<String, String>>> collect(ImageGenSettings settings) =>
        const ImageReferenceCollector().collect(
          settings: settings,
          prompt: 'zoe waves',
        );

    test('pads a library reference on NovelAI V4.5', () async {
      final refs = await collect(
        ImageGenSettings(
          apiType: ImageGenApiType.novelai,
          novelai: const NovelAIImageSettings(model: 'nai-diffusion-4-5-full'),
          references: [
            ReferenceImage(name: 'zoe', imageData: _dataUrl(200, 400)),
          ],
        ),
      );

      expect(refs, hasLength(1));
      expect(refs.single['mime'], 'image/png');
      final decoded = img.decodeImage(base64Decode(refs.single['image']!))!;
      expect((decoded.width, decoded.height), (1024, 1536));
    });

    test('cuts a library reference on NovelAI V5', () async {
      final refs = await collect(
        ImageGenSettings(
          apiType: ImageGenApiType.novelai,
          novelai: const NovelAIImageSettings(model: 'nai-diffusion-5-full'),
          references: [
            ReferenceImage(name: 'zoe', imageData: _dataUrl(200, 400)),
          ],
        ),
      );

      expect(refs, hasLength(1));
      final decoded = img.decodeImage(base64Decode(refs.single['image']!))!;
      expect((decoded.width, decoded.height), (704, 1408));
    });

    test('sends a reference as-is when the model needs no padding', () async {
      final original = _dataUrl(40, 20);
      final refs = await collect(
        ImageGenSettings(
          apiType: ImageGenApiType.openai,
          customModel: 'gpt-image-1',
          references: [ReferenceImage(name: 'zoe', imageData: original)],
        ),
      );

      expect(refs, hasLength(1));
      expect(refs.single['image'], original.split(',').last);
    });

    test(
      'drops references on a NovelAI model without Director Tools',
      () async {
        final refs = await collect(
          ImageGenSettings(
            apiType: ImageGenApiType.novelai,
            novelai: const NovelAIImageSettings(model: 'nai-diffusion-4-full'),
            references: [
              ReferenceImage(name: 'zoe', imageData: _dataUrl(40, 20)),
            ],
          ),
        );

        expect(refs, isEmpty);
      },
    );
  });
}
