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

const Map<String, String> _emotionWords = {
  'normal': 'calm, neutral expression',
  'smile': 'warm, happy smile',
  'angry': 'angry, frowning',
  'sad': 'sad, downcast',
  'surprised': 'surprised, eyes wide, mouth open',
};

String _who(VnCastMember who, String setting) {
  final b = StringBuffer('Character: ${who.name}.');
  if (who.about.isNotEmpty) b.write(' ${who.about}');
  if (who.color != null) b.write(' Hair color ${who.color}.');
  if (setting.isNotEmpty) b.write('\nStory setting: $setting');
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
    _who(who, setting),
    'Every figure: the same person, the same outfit, the same full-body '
        'standing pose facing the viewer, head to feet in view with space '
        'around, nothing cropped. Figures do not touch or overlap. Only the '
        'face changes, left to right: $order.',
    _background(chroma),
  ].join('\n\n');
}

/// The request for the neutral sprite on its own.
String vnBasePrompt(VnCastMember who, String setting, VnChroma chroma) => [
  'A full-body character sprite for a visual novel.',
  _who(who, setting),
  'One figure, standing, facing the viewer, head to feet in view with space '
      'around, nothing cropped. ${_emotionWords['normal']}.',
  _background(chroma),
].join('\n\n');

/// The request to redraw the neutral sprite with [emotion].
String vnEmotionPrompt(String emotion, VnChroma chroma) =>
    'Redraw IMAGE_1 exactly: the same character, outfit, pose, framing, size '
    'and flat ${chroma.name} background. Change only the facial expression '
    'to: ${_emotionWords[emotion]}.';

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

String _dataUrl(Uint8List bytes) =>
    'data:image/png;base64,${base64Encode(bytes)}';

/// Draws the cast of a novel with the image provider set up in the image
/// generation settings.
class VnSpriteService {
  VnSpriteService(this._ref);

  final Ref _ref;
  final ImageGenDispatcher _dispatcher = const ImageGenDispatcher();

  /// Draws [who] and saves the sprites under `vn_sprites/<sessionId>/`.
  /// Returns the saved paths by emotion, relative to the data folder;
  /// emotions the provider could not draw are missing and fall back to
  /// `normal` in the engine.
  Future<Map<String, String>> draw({
    required String sessionId,
    required VnCastMember who,
    required String setting,
    required String size,
    CancelToken? cancelToken,
  }) async {
    final settings = await _ref.read(imageGenSettingsProvider.future);
    await _ref.read(apiListProvider.future);
    final api = _ref.read(activeApiConfigProvider);
    final chroma = VnChroma.against(who.color);
    final wrapStyle = settings.apiType != ImageGenApiType.novelai;

    Future<Uint8List> generate(
      String prompt,
      List<Map<String, String>> references,
      String aspect, {
      String? size,
    }) => _dispatcher.generate(
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

    final sprites = <String, Uint8List>{};
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
          vnSheetPrompt(who, setting, chroma, guide: guide),
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
        final pngs = await Isolate.run(
          () => spritesFromSheet(sheet, kVnEmotions.length),
        );
        for (var i = 0; i < kVnEmotions.length; i++) {
          sprites[kVnEmotions[i]] = pngs[i];
        }
      case VnSinglesPlan(:final edits):
        final base = await generate(
          vnBasePrompt(who, setting, chroma),
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
            } on DioException catch (e) {
              if (CancelToken.isCancel(e)) rethrow;
              // One refused edit keeps the rest of the set.
            }
          }
        }
        final pngs = await Isolate.run(() => spritesFromSingles(pictures));
        for (var i = 0; i < emotions.length; i++) {
          final png = pngs[i];
          if (png != null) sprites[emotions[i]] = png;
        }
        if (!sprites.containsKey('normal')) {
          throw const FormatException('No figure in the picture');
        }
    }

    final storage = await _ref.read(imageStorageProvider.future);
    final folder = vnSpriteFolder(sessionId);
    return {
      for (final e in sprites.entries)
        e.key: await () async {
          final name = '${who.id}_${e.key}';
          await storage.saveBytes(e.value, folder, name, 'png');
          return '$folder/$name.png';
        }(),
    };
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
