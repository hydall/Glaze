import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/image_reference_collector.dart';

/// The character can travel either as the avatar reference image or as the
/// appearance text of its card. Only the image source is collected as a
/// reference; the text is appended to the prompt by the service.
void main() {
  group('character appearance source', () {
    test(
      'the image source collects the avatar, the text source does not',
      () async {
        final dir = await Directory.systemTemp.createTemp('glaze_appearance');
        addTearDown(() => dir.delete(recursive: true));
        final avatar = File('${dir.path}/avatar.png');
        await avatar.writeAsBytes(const [1, 2, 3, 4]);

        const character = Character(id: '1', name: 'Ann');
        final withAvatar = character.copyWith(avatarPath: avatar.path);
        const collector = ImageReferenceCollector();

        ImageGenSettings settings(CharacterAppearanceSource source) =>
            ImageGenSettings(
              apiType: ImageGenApiType.openai,
              customModel: 'gpt-image-1.5',
              sendCharAvatar: true,
              charAppearanceSource: source,
            );

        final imageRefs = await collector.collect(
          settings: settings(CharacterAppearanceSource.image),
          prompt: 'a cat',
          character: withAvatar,
        );
        expect(imageRefs, hasLength(1));
        expect(imageRefs.single['source'], 'char');

        final textRefs = await collector.collect(
          settings: settings(CharacterAppearanceSource.description),
          prompt: 'a cat',
          character: withAvatar,
        );
        expect(textRefs, isEmpty);
      },
    );

    test('the source getters follow the toggle', () {
      const off = ImageGenSettings(sendCharAvatar: false);
      expect(off.sendsCharAvatarImage, isFalse);
      expect(off.sendsCharAppearanceText, isFalse);

      const image = ImageGenSettings(
        sendCharAvatar: true,
        charAppearanceSource: CharacterAppearanceSource.image,
      );
      expect(image.sendsCharAvatarImage, isTrue);
      expect(image.sendsCharAppearanceText, isFalse);

      const text = ImageGenSettings(
        sendCharAvatar: true,
        charAppearanceSource: CharacterAppearanceSource.description,
      );
      expect(text.sendsCharAvatarImage, isFalse);
      expect(text.sendsCharAppearanceText, isTrue);
    });
  });
}
