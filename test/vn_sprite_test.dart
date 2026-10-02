import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_dispatcher.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/vn/models/vn_document.dart';
import 'package:glaze_flutter/features/vn/services/vn_sprite_image.dart';
import 'package:glaze_flutter/features/vn/services/vn_sprite_service.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

/// A sheet the way an image model returns one: [count] figures on a slightly
/// noisy flat background, each with a gap of background enclosed between
/// its arm and body, saved as JPEG.
Uint8List _sheet({
  int count = 5,
  (int, int, int) bg = (6, 251, 4),
  bool jpeg = true,
}) {
  const w = 1000, h = 420;
  final image = img.Image(width: w, height: h);
  final rnd = Random(1);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int n(int c) => (c + rnd.nextInt(13) - 6).clamp(0, 255);
      image.setPixelRgb(x, y, n(bg.$1), n(bg.$2), n(bg.$3));
    }
  }
  final hair = img.ColorRgb8(224, 122, 154);
  final coat = img.ColorRgb8(60, 70, 95);
  final skin = img.ColorRgb8(250, 222, 200);
  for (var i = 0; i < count; i++) {
    final cx = (w / count * (i + 0.5)).round();
    img.fillCircle(image, x: cx, y: 60, radius: 30, color: hair);
    img.fillCircle(image, x: cx, y: 66, radius: 20, color: skin);
    // Body, and an arm that meets it only at the shoulder and the hand.
    img.fillRect(image, x1: cx - 28, y1: 95, x2: cx + 28, y2: 260, color: coat);
    img.fillRect(
      image,
      x1: cx + 40,
      y1: 100,
      x2: cx + 50,
      y2: 230,
      color: coat,
    );
    img.fillRect(image, x1: cx + 28, y1: 95, x2: cx + 50, y2: 105, color: coat);
    img.fillRect(
      image,
      x1: cx + 28,
      y1: 222,
      x2: cx + 50,
      y2: 232,
      color: skin,
    );
    img.fillRect(image, x1: cx - 20, y1: 260, x2: cx - 6, y2: 390, color: skin);
    img.fillRect(image, x1: cx + 6, y1: 260, x2: cx + 20, y2: 390, color: skin);
  }
  return jpeg ? img.encodeJpg(image, quality: 80) : img.encodePng(image);
}

img.Image _png(Uint8List bytes) => img.decodePng(bytes)!;

/// Hands back [picture] for every request.
class _FakeDispatcher extends ImageGenDispatcher {
  const _FakeDispatcher(this.picture);

  final Uint8List picture;

  @override
  Future<Uint8List> generate({
    required ImageGenSettings settings,
    required String prompt,
    required List<Map<String, String>> references,
    required String llmEndpoint,
    required String llmApiKey,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
  }) async => picture;
}

class _Settings extends ImageGenSettingsNotifier {
  _Settings(this.settings);

  final ImageGenSettings settings;

  @override
  Future<ImageGenSettings> build() async => settings;
}

void main() {
  group('cutting sprites out of a sheet', () {
    test('splits a green JPEG sheet into five aligned figures', () {
      final sprites = spritesFromSheet(_sheet(), 5);
      expect(sprites, hasLength(5));
      final first = _png(sprites.first);
      for (final s in sprites.map(_png)) {
        expect(s.width, first.width);
        expect(s.height, first.height);
      }
      // Trimmed to the figure: about its height and width, not the slot's.
      expect(first.height, inInclusiveRange(355, 365));
      expect(first.width, inInclusiveRange(75, 90));

      for (final s in sprites.map(_png)) {
        expect(s.getPixel(0, 0).a, 0, reason: 'corner is background');
        expect(
          s.getPixel(s.width ~/ 2 - 10, s.height ~/ 2).a,
          255,
          reason: 'the body stays',
        );
        var greenLeft = 0;
        for (final p in s) {
          if (p.a > 0 && p.g - max(p.r, p.b) > 30) greenLeft++;
        }
        expect(greenLeft, 0, reason: 'no green fringe or pocket');
      }
    });

    test('clears background enclosed by the figure', () {
      final sprite = _png(spritesFromSheet(_sheet(), 5).first);
      // The gap between the arm and the body, half way down the arm.
      final gapX = sprite.width - 16, gapY = 100;
      expect(sprite.getPixel(gapX, gapY).a, 0);
    });

    test('keys a magenta background', () {
      final sprites = spritesFromSheet(_sheet(bg: (250, 4, 250)), 5);
      final s = _png(sprites[2]);
      expect(s.getPixel(0, 0).a, 0);
      expect(s.getPixel(s.width ~/ 2 - 10, s.height ~/ 2).a, 255);
    });

    test('floods a white background in from the border', () {
      final sprites = spritesFromSheet(
        _sheet(bg: (250, 250, 250), jpeg: false),
        5,
      );
      final s = _png(sprites.first);
      expect(s.getPixel(0, 0).a, 0);
      expect(s.getPixel(s.width ~/ 2 - 10, s.height ~/ 2).a, 255);
    });

    test('rejects a sheet with figures missing', () {
      // Two figures where five were asked for: cut in equal parts, three of
      // the parts are empty.
      expect(
        () => spritesFromSheet(_sheet(count: 2), 5),
        throwsA(isA<FormatException>()),
      );
    });

    test('a layout guide is a PNG of the asked size', () {
      final guide = img.decodePng(
        buildVnLayoutGuide(
          width: 420,
          height: 180,
          count: 5,
          chroma: VnChroma.green,
        ),
      )!;
      expect((guide.width, guide.height), (420, 180));
      expect(guide.getPixel(0, 0).g, 255);
    });
  });

  test('a green-haired character gets a magenta background', () {
    expect(VnChroma.against('#E07A9A'), VnChroma.green);
    expect(VnChroma.against('#3c4'), VnChroma.magenta);
    expect(VnChroma.against(null), VnChroma.green);
  });

  test('the plan follows what the model can draw', () {
    expect(
      vnSpritePlan(
        const ImageGenSettings(
          apiType: ImageGenApiType.gemini,
          customModel: 'gemini-3.1-flash-image-preview',
        ),
        '4K',
      ),
      isA<VnSheetPlan>()
          .having((p) => p.size, 'size', '4K')
          .having((p) => p.guide, 'guide', true),
    );
    expect(
      vnSpritePlan(
        const ImageGenSettings(
          apiType: ImageGenApiType.gemini,
          customModel: 'gemini-2.5-flash-image',
        ),
        '2K',
      ),
      isA<VnSinglesPlan>().having((p) => p.edits, 'edits', true),
    );
    expect(
      vnSpritePlan(
        const ImageGenSettings(apiType: ImageGenApiType.a1111),
        '2K',
      ),
      isA<VnSinglesPlan>().having((p) => p.edits, 'edits', false),
    );
  });

  test('the cast is read from every part with its about line', () {
    final doc = VnDocument.fromMessages([
      const ChatMessage(id: '1', role: 'user', content: 'idea', timestamp: 0),
      const ChatMessage(
        id: '2',
        role: 'assistant',
        content:
            '@vn characters\ncast mia "Мия" #E07A9A\nabout mia: club head, glasses',
        timestamp: 0,
      ),
      const ChatMessage(
        id: '3',
        role: 'assistant',
        content: '@vn chapter 1\nsummary: s\ncast ken "Кен"\n# a < hall\nnext',
        timestamp: 0,
      ),
    ]);
    final cast = doc.cast;
    expect(cast.keys, ['mia', 'ken']);
    expect(cast['mia']!.about, 'club head, glasses');
    expect(cast['mia']!.color, '#E07A9A');
    expect(cast['ken']!.color, isNull);
  });

  test('sprites read back from the session', () {
    expect(vnSpritesOf({}), isEmpty);
    expect(vnSpritesOf({kVnSpritesVarKey: 'not json'}), isEmpty);
    expect(
      vnSpritesOf({
        kVnSpritesVarKey: '{"mia":{"normal":"vn_sprites/s/mia_normal.png"}}',
      }),
      {
        'mia': {'normal': 'vn_sprites/s/mia_normal.png'},
      },
    );
  });

  group('drawing through the service', () {
    late Directory dir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('vn_sprites');
    });
    tearDown(() => dir.delete(recursive: true));

    Future<Map<String, String>> draw(
      ImageGenSettings settings,
      Uint8List picture,
    ) async {
      final container = ProviderContainer(
        overrides: [
          imageGenSettingsProvider.overrideWith(() => _Settings(settings)),
          imageStorageProvider.overrideWith(
            (ref) async => ImageStorageService(dir.path),
          ),
          vnSpriteServiceProvider.overrideWith(
            (ref) => VnSpriteService(ref, _FakeDispatcher(picture)),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container
          .read(vnSpriteServiceProvider)
          .draw(
            sessionId: 's',
            who: const VnCastMember(id: 'mia', name: 'Мия'),
            setting: '',
            size: '2K',
            // Unsendable to an isolate: the cut-out must not capture it.
            cancelToken: CancelToken(),
          );
    }

    test('a sheet is cut in an isolate and saved', () async {
      final paths = await draw(
        const ImageGenSettings(
          apiType: ImageGenApiType.gemini,
          customModel: 'gemini-3.1-flash-image-preview',
        ),
        _sheet(),
      );
      expect(paths.keys, kVnEmotions);
      for (final path in paths.values) {
        expect(File('${dir.path}/$path').existsSync(), isTrue);
      }
    });

    test('a single picture is cut in an isolate and saved', () async {
      final single = img.encodePng(
        img.copyCrop(
          img.decodeJpg(_sheet(count: 1))!,
          x: 300,
          y: 0,
          width: 400,
          height: 420,
        ),
      );
      final paths = await draw(
        const ImageGenSettings(apiType: ImageGenApiType.a1111),
        single,
      );
      expect(paths.keys, ['normal']);
    });
  });
}
