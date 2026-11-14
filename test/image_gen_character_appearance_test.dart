import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_service.dart';
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

  group('appearance text on a model without references', () {
    const png1x1 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
    const character = Character(
      id: 'c',
      name: 'Alice',
      appearance: 'red hair, green eyes',
    );
    const persona = Persona(id: 'p', name: 'Bob');

    /// Runs one A1111 (txt2img only) generation against a local stub and
    /// returns the prompt it received.
    Future<String?> sentPrompt(
      ImageGenSettings Function(String url) build,
    ) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? prompt;
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        prompt = (body as Map)['prompt'] as String?;
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'images': [png1x1],
            }),
          );
        await request.response.close();
      });
      await ImageGenService(ImageStorageService(Directory.systemTemp.path))
          .generateImage(
            settings: build('http://127.0.0.1:${server.port}'),
            prompt: 'a walk in the rain',
            llmEndpoint: '',
            llmApiKey: '',
            llmModel: '',
            character: character,
            persona: persona,
          );
      return prompt;
    }

    test('sends the card appearance under the names, not macros', () async {
      final prompt = await sentPrompt(
        (url) => ImageGenSettings(
          enabled: true,
          apiType: ImageGenApiType.a1111,
          sendCharAvatar: true,
          a1111: A1111ImageSettings(endpoint: url),
          references: const [
            ReferenceImage(
              name: 'Bob',
              imageData: '',
              description: 'tall, grey coat',
            ),
          ],
        ),
      );
      expect(prompt, contains('- Alice: red hair, green eyes'));
      expect(prompt, contains('- Bob: tall, grey coat'));
      expect(prompt, isNot(contains('{{')));
    });

    test('sends nothing extra with the toggle off', () async {
      final prompt = await sentPrompt(
        (url) => ImageGenSettings(
          enabled: true,
          apiType: ImageGenApiType.a1111,
          a1111: A1111ImageSettings(endpoint: url),
        ),
      );
      expect(prompt, 'a walk in the rain');
    });
  });
}
