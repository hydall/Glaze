import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/image_reference_collector.dart';
import 'package:image/image.dart' as img;

Uint8List _solidPng(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(255, 0, 0));
  return Uint8List.fromList(img.encodePng(image));
}

String _dataUrl(int width, int height) =>
    'data:image/png;base64,${base64Encode(_solidPng(width, height))}';

void main() {
  group('NovelAIConstants.referenceCanvas', () {
    test('picks the canvas from the source orientation', () {
      expect(NovelAIConstants.referenceCanvas(200, 400), (1024, 1536));
      expect(NovelAIConstants.referenceCanvas(400, 200), (1536, 1024));
      expect(NovelAIConstants.referenceCanvas(300, 300), (1472, 1472));
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
