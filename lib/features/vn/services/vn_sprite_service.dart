import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/db_provider.dart';
import '../../image_gen/image_gen_capabilities.dart';
import '../../image_gen/image_gen_models.dart';
import '../../image_gen/image_gen_provider.dart';
import '../../image_gen/services/image_gen_dispatcher.dart';
import '../../image_gen/services/image_prompt_builder.dart';
import '../../settings/api_list_provider.dart';
import '../models/vn_document.dart';
import 'vn_sprite_image.dart';

/// How a character is drawn with the configured image provider.
sealed class VnSpritePlan {
  const VnSpritePlan();
}

/// Every emotion side by side in one wide picture: one request, and the
/// character cannot drift between emotions. For models that draw wide
/// pictures at 2K or more (Nano Banana 2 and Pro).
class VnSheetPlan extends VnSpritePlan {
  const VnSheetPlan({required this.size, required this.guide});

  final String size;

  /// Whether the provider takes a layout guide as a reference image.
  final bool guide;
}

/// A tall picture of the character, then each emotion as an edit of it
/// when the provider takes reference images. For models limited to 1K
/// (Nano Banana) a sheet would leave each figure a few hundred pixels wide.
class VnSinglesPlan extends VnSpritePlan {
  const VnSinglesPlan({required this.edits});

  /// False: only the neutral sprite is drawn; the other emotions use it.
  final bool edits;
}

const String _sheetAspect = '21:9';

/// The plan for [settings], asking for sheets of [size] (`2K`, `4K`) where
/// the model can draw one.
VnSpritePlan vnSpritePlan(ImageGenSettings settings, String size) {
  final refs = providerMaxReferences(settings) > 0;
  final ImageModelCaps? caps = switch (settings.apiType) {
    ImageGenApiType.gemini => geminiCapabilities(settings.customModel),
    ImageGenApiType.openrouter => openRouterCapabilities(
      settings.openrouter.model,
    ),
    // rout.my lists the Gemini models under a vendor prefix.
    ImageGenApiType.routmy
        when classifyGeminiImageModel(
          settings.routmyModel.split('/').last,
        ).startsWith('gemini-3') =>
      const ImageModelCaps(
        maxReferences: 0,
        imageSizes: RoutMyConstants.imageSizes,
        aspectRatios: RoutMyConstants.aspectRatios,
      ),
    _ => null,
  };
  final sizes = caps?.imageSizes;
  if (caps != null &&
      sizes != null &&
      caps.aspectRatios.contains(_sheetAspect)) {
    final pick = sizes.contains(size)
        ? size
        : (sizes.contains('2K') ? '2K' : null);
    if (pick != null) return VnSheetPlan(size: pick, guide: refs);
  }
  return VnSinglesPlan(edits: refs);
}

// Spelled out feature by feature: "sad" alone comes back as the calm face.
const Map<String, String> _emotionWords = {
  'normal': 'calm, neutral expression, relaxed brows, mouth closed',
  'smile':
      'happy: a wide open smile showing teeth, cheeks raised, eyes '
      'narrowed with joy',
  'angry':
      'angry: brows pulled down hard into a V, glaring eyes, teeth '
      'clenched or mouth open shouting',
  'sad':
      'sad: inner brows raised and drawn together, eyes looking down and '
      'glistening, corners of the mouth turned down',
  'surprised':
      'shocked: brows raised high, eyes opened very wide, mouth '
      'open in an O',
};

String _who(VnCastMember who, String setting, String? note) {
  final b = StringBuffer('Character: ${who.name}.');
  if (who.about.isNotEmpty) b.write(' ${who.about}');
  if (who.color != null) b.write(' Hair color ${who.color}.');
  if (setting.isNotEmpty) b.write('\nStory setting: $setting');
  if (note != null && note.trim().isNotEmpty) {
    b.write(
      '\nThe reader asked for this; it overrides the above: ${note.trim()}',
    );
  }
  return b.toString();
}

String _background(VnChroma chroma) =>
    'Background: one flat, solid, pure ${chroma.name} (${chroma.hex}) '
    'everywhere around the figures. No floor, no shadow, no gradient, no '
    'scenery, no text, no labels, no frames. Nothing in the character is '
    'that ${chroma.name}.';

/// The request for a sheet of every emotion, left to right in
/// [kVnEmotions] order.
String vnSheetPrompt(
  VnCastMember who,
  String setting,
  VnChroma chroma, {
  required bool guide,
  String? note,
}) {
  final order = [
    for (var i = 0; i < kVnEmotions.length; i++)
      '${i + 1}) ${_emotionWords[kVnEmotions[i]]}',
  ].join(', ');
  return [
    'A character sprite sheet for a visual novel: the same character drawn '
        '${kVnEmotions.length} times in one row, evenly spaced.',
    if (guide)
      'IMAGE_1 is the layout: draw one figure over each grey mannequin, in '
          'its place and at its size. Do not draw the mannequins.',
    _who(who, setting, note),
    'Every figure: the same person, the same outfit, the same full-body '
        'standing pose facing the viewer, head to feet in view with space '
        'around, nothing cropped. Figures do not touch or overlap. Only the '
        'face changes, left to right: $order.',
    _background(chroma),
  ].join('\n\n');
}

/// The request for the neutral sprite on its own.
String vnBasePrompt(
  VnCastMember who,
  String setting,
  VnChroma chroma, {
  String? note,
}) => [
  'A full-body character sprite for a visual novel.',
  _who(who, setting, note),
  'One figure, standing, facing the viewer, head to feet in view with space '
      'around, nothing cropped. ${_emotionWords['normal']}.',
  _background(chroma),
].join('\n\n');

/// The request to redraw the neutral sprite with [emotion].
String vnEmotionPrompt(String emotion, VnChroma chroma) =>
    'Redraw IMAGE_1 with a different facial expression: '
    '${_emotionWords[emotion]}. Make the expression strong and obvious, '
    'readable when the picture is small. Keep everything else exactly as in '
    'IMAGE_1: the same character, outfit, pose, framing, size and flat '
    '${chroma.name} background.';

/// The setting in a few sentences, for the picture's mood: the scenario
/// without its title line, cut short.
String vnSpriteSetting(VnDocument doc) {
  final scenario = doc.setup[VnPass.scenario] ?? '';
  final text = const LineSplitter()
      .convert(scenario)
      .where((l) => !l.trim().toLowerCase().startsWith('title:'))
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return text.length <= 400 ? text : '${text.substring(0, 400)}…';
}

// Top level, so the closure sent to the isolate captures only the pictures:
// one made inside [VnSpriteService.draw] would carry its whole scope, cancel
// token included, and that cannot cross isolates.
Future<List<Uint8List>> _cutSheet(Uint8List sheet) =>
    Isolate.run(() => spritesFromSheet(sheet, kVnEmotions.length));

Future<List<Uint8List?>> _cutSingles(List<Uint8List> pictures) =>
    Isolate.run(() => spritesFromSingles(pictures));

Future<List<Uint8List?>> _cutWithRedrawn(
  List<Uint8List?> kept,
  int index,
  Uint8List picture,
) => Isolate.run(() => spritesWithRedrawn(kept, index, picture));

Future<Uint8List> _onChroma(Uint8List png, VnChroma chroma) =>
    Isolate.run(() => spriteOnChroma(png, chroma));

typedef _Generate =
    Future<Uint8List> Function(
      String prompt,
      List<Map<String, String>> references,
      String aspect, {
      String? size,
    });

/// Whether a failed request is worth repeating: a rate limit, an overloaded
/// or failing server, a dropped connection.
bool _transient(Object e) =>
    e is DioException &&
    !CancelToken.isCancel(e) &&
    switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.badResponse => const {
        408,
        429,
        500,
        502,
        503,
        504,
      }.contains(e.response?.statusCode),
      _ => false,
    };

/// Why a picture is missing, short enough for a sprite's slot.
String vnArtReason(Object e) => switch (e) {
  DioException(:final response?) =>
    'HTTP ${response.statusCode}'
        '${response.statusMessage == null ? '' : ' ${response.statusMessage}'}',
  DioException(:final message?) => message,
  FormatException(:final message) => message,
  _ => '$e'.replaceFirst('Exception: ', ''),
};

/// What drawing a character gave: the saved sprites by emotion, and why
/// each emotion that is not there failed.
class VnDrawn {
  const VnDrawn(this.paths, [this.missing = const {}]);

  final Map<String, String> paths;
  final Map<String, String> missing;
}

/// Whether [settings] can redraw one emotion: that is an edit of the calm
/// sprite, so the provider has to take a reference image.
bool vnCanRedrawEmotion(ImageGenSettings settings) =>
    providerMaxReferences(settings) > 0;

String _dataUrl(Uint8List bytes) =>
    'data:image/png;base64,${base64Encode(bytes)}';

/// Draws the cast of a novel with the image provider set up in the image
/// generation settings.
class VnSpriteService {
  VnSpriteService(this._ref, [this._dispatcher = const ImageGenDispatcher()]);

  final Ref _ref;
  final ImageGenDispatcher _dispatcher;

  /// Draws [who] and saves the sprites under `vn_sprites/<sessionId>/`.
  /// Returns the saved paths by emotion, relative to the data folder;
  /// emotions the provider could not draw are missing, with the reason, and
  /// fall back to `normal` in the engine.
  Future<VnDrawn> draw({
    required String sessionId,
    required VnCastMember who,
    required String setting,
    required String size,
    String? note,
    CancelToken? cancelToken,
  }) async {
    final settings = await _ref.read(imageGenSettingsProvider.future);
    final generate = await _generator(settings, cancelToken);
    final chroma = VnChroma.against(who.color);

    final sprites = <String, Uint8List>{};
    final missing = <String, String>{};
    switch (vnSpritePlan(settings, size)) {
      case VnSheetPlan(:final size, :final guide):
        final layout = guide
            ? buildVnLayoutGuide(
                width: 1680,
                height: 720,
                count: kVnEmotions.length,
                chroma: chroma,
              )
            : null;
        final sheet = await generate(
          vnSheetPrompt(who, setting, chroma, guide: guide, note: note),
          [
            if (layout != null)
              {
                'image': _dataUrl(layout),
                'mime': 'image/png',
                'description': 'layout guide, mannequins to draw over',
              },
          ],
          _sheetAspect,
          size: size,
        );
        final pngs = await _cutSheet(sheet);
        for (var i = 0; i < kVnEmotions.length; i++) {
          sprites[kVnEmotions[i]] = pngs[i];
        }
      case VnSinglesPlan(:final edits):
        final base = await generate(
          vnBasePrompt(who, setting, chroma, note: note),
          const [],
          '9:16',
        );
        final pictures = [base];
        final emotions = ['normal'];
        if (edits) {
          final reference = {'image': _dataUrl(base), 'description': who.name};
          for (final emotion in kVnEmotions.skip(1)) {
            try {
              pictures.add(
                await generate(vnEmotionPrompt(emotion, chroma), [
                  reference,
                ], '9:16'),
              );
              emotions.add(emotion);
            } catch (e) {
              if (e is DioException && CancelToken.isCancel(e)) rethrow;
              // One refused edit keeps the rest of the set.
              debugPrint('[VN3D] ${who.id} $emotion not drawn: $e');
              missing[emotion] = vnArtReason(e);
            }
          }
        }
        final pngs = await _cutSingles(pictures);
        for (var i = 0; i < emotions.length; i++) {
          final png = pngs[i];
          if (png != null) {
            sprites[emotions[i]] = png;
          } else {
            missing[emotions[i]] = 'No figure in the picture';
          }
        }
        if (!sprites.containsKey('normal')) {
          throw const FormatException('No figure in the picture');
        }
    }

    return VnDrawn(await _save(sessionId, who.id, sprites), missing);
  }

  /// Draws [emotion] of [who] again as an edit of their calm sprite, and
  /// puts the whole set, [current] paths by emotion, on one canvas again.
  /// Returns the new paths of every emotion.
  Future<Map<String, String>> drawEmotion({
    required String sessionId,
    required VnCastMember who,
    required String emotion,
    required Map<String, String> current,
    CancelToken? cancelToken,
  }) async {
    final settings = await _ref.read(imageGenSettingsProvider.future);
    if (!vnCanRedrawEmotion(settings)) {
      throw const FormatException('The image model cannot edit a picture');
    }
    final storage = await _ref.read(imageStorageProvider.future);
    final kept = <Uint8List?>[
      for (final e in kVnEmotions)
        await () async {
          final path = current[e];
          if (path == null) return null;
          final file = File(storage.absolutePath(path) ?? path);
          return await file.exists() ? await file.readAsBytes() : null;
        }(),
    ];
    final calm = kept.first;
    if (calm == null) throw const FormatException('No calm sprite to edit');
    final chroma = VnChroma.against(who.color);
    final generate = await _generator(settings, cancelToken);
    final picture = await generate(vnEmotionPrompt(emotion, chroma), [
      {
        'image': _dataUrl(await _onChroma(calm, chroma)),
        'mime': 'image/png',
        'description': who.name,
      },
    ], '9:16');
    final pngs = await _cutWithRedrawn(
      kept,
      kVnEmotions.indexOf(emotion),
      picture,
    );
    return _save(sessionId, who.id, {
      for (var i = 0; i < kVnEmotions.length; i++)
        if (pngs[i] != null) kVnEmotions[i]: pngs[i]!,
    });
  }

  /// One request to the image provider, repeated after a pause on a rate
  /// limit or a server or network failure, and once more at once when the
  /// model answered without a picture.
  Future<_Generate> _generator(
    ImageGenSettings settings,
    CancelToken? cancelToken,
  ) async {
    await _ref.read(apiListProvider.future);
    final api = _ref.read(activeApiConfigProvider);
    final wrapStyle = settings.apiType != ImageGenApiType.novelai;
    Future<Uint8List> generate(
      String prompt,
      List<Map<String, String>> references,
      String aspect, {
      String? size,
    }) async {
      for (var attempt = 0; ; attempt++) {
        try {
          return await _dispatcher.generate(
            settings: settings,
            prompt: buildFinalGenerationPrompt(
              prompt: prompt,
              tagStyle: null,
              settings: settings,
              wrapStyle: wrapStyle,
            ),
            references: references,
            llmEndpoint: api?.endpoint ?? '',
            llmApiKey: api?.apiKey ?? '',
            instructionAspectRatio: aspect,
            instructionImageSize: size,
            cancelToken: cancelToken,
          );
        } catch (e) {
          if (cancelToken?.isCancelled ?? false) rethrow;
          final Duration wait;
          if (_transient(e) && attempt < retryDelays.length) {
            final after = int.tryParse(
              (e as DioException).response?.headers.value('retry-after') ?? '',
            );
            wait = after != null && after <= 60
                ? Duration(seconds: after)
                : retryDelays[attempt];
          } else if (e is! DioException && attempt == 0) {
            wait = Duration.zero;
          } else {
            rethrow;
          }
          debugPrint('[VN3D] image request failed, again in $wait: $e');
          await Future<void>.delayed(wait);
        }
      }
    }

    return generate;
  }

  /// Pauses before each repeat of a failed request.
  @visibleForTesting
  List<Duration> retryDelays = const [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  Future<Map<String, String>> _save(
    String sessionId,
    String castId,
    Map<String, Uint8List> sprites,
  ) async {
    final storage = await _ref.read(imageStorageProvider.future);
    final folder = vnSpriteFolder(sessionId);
    // A new name per drawing, so a redraw never shows a cached old picture.
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return {
      for (final e in sprites.entries)
        e.key: await () async {
          final name = '${castId}_${e.key}_$stamp';
          await storage.saveBytes(e.value, folder, name, 'png');
          return '$folder/$name.png';
        }(),
    };
  }

  /// Deletes sprites replaced by a redraw.
  Future<void> remove(Iterable<String> paths) async {
    final storage = await _ref.read(imageStorageProvider.future);
    for (final path in paths) {
      try {
        final file = File(storage.absolutePath(path) ?? path);
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('[VN3D] removing $path failed: $e');
      }
    }
  }
}

/// Where a novel's sprites live, relative to the data folder.
String vnSpriteFolder(String sessionId) => 'vn_sprites/$sessionId';

/// Removes a deleted novel's sprites from disk.
Future<void> deleteVnSprites(Ref ref, String sessionId) async {
  try {
    final storage = await ref.read(imageStorageProvider.future);
    final dir = Directory(
      storage.absolutePath(vnSpriteFolder(sessionId)) ?? '',
    );
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (e) {
    debugPrint('[VN3D] removing the sprites of $sessionId failed: $e');
  }
}

final vnSpriteServiceProvider = Provider<VnSpriteService>(VnSpriteService.new);
