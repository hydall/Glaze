import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_service.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

void main() {
  late ImageGenService service;

  setUp(() {
    service = ImageGenService(ImageStorageService('/tmp/fake_test'));
  });

  group('hasImageGenTags', () {
    test('detects [IMG:GEN] tag', () {
      expect(ImageTagMarkup.hasImageGenTags('Hello [IMG:GEN:]'), isTrue);
    });

    test('detects [IMG:GEN:json] tag', () {
      expect(
        ImageTagMarkup.hasImageGenTags('Hello [IMG:GEN:{"prompt":"test"}]'),
        isTrue,
      );
    });

    test('detects data-iig-instruction with single quotes', () {
      const html =
          """<img data-iig-instruction='{"style":"manga","prompt":"test"}' src="[IMG:GEN]">""";
      expect(ImageTagMarkup.hasImageGenTags(html), isTrue);
    });

    test('detects data-iig-instruction with double quotes', () {
      const html =
          '''<img data-iig-instruction="{"style":"manga","prompt":"test"}" src="[IMG:GEN]">''';
      expect(ImageTagMarkup.hasImageGenTags(html), isTrue);
    });

    test('returns false for plain text', () {
      expect(ImageTagMarkup.hasImageGenTags('Just a normal message'), isFalse);
    });

    test('returns false for empty string', () {
      expect(ImageTagMarkup.hasImageGenTags(''), isFalse);
    });

    test('detects tag inside full HTML card', () {
      const html = """<div style="max-width:680px; padding:18px;">
  <img data-iig-instruction='{"style":"cinematic manga","prompt":"SCENE_PROMPT: test","aspect_ratio":"9:16","image_size":"1K"}' src="[IMG:GEN]" style="display:block; width:100%; border-radius:15px;">
  <div style="margin-top:15px; text-align:center;">
    <i>Caption text</i>
  </div>
</div>""";
      expect(ImageTagMarkup.hasImageGenTags(html), isTrue);
    });
  });

  group('extractImageGenInstructions', () {
    test('extracts from [IMG:GEN:json]', () {
      final instructions = ImageTagMarkup.extractImageGenInstructions(
        'Hello [IMG:GEN:{"prompt":"a sunset","style":"anime"}]',
      );
      expect(instructions.length, 1);
      expect(instructions[0]['prompt'], 'a sunset');
      expect(instructions[0]['style'], 'anime');
    });

    test('extracts from HTML single-quoted data-iig-instruction', () {
      const html =
          """<img data-iig-instruction='{"style":"cinematic manga","prompt":"SCENE_PROMPT: test scene","aspect_ratio":"9:16","image_size":"1K"}' src="[IMG:GEN]">""";
      final instructions = ImageTagMarkup.extractImageGenInstructions(html);
      expect(instructions.length, 1);
      expect(instructions[0]['style'], 'cinematic manga');
      expect(instructions[0]['prompt'], 'SCENE_PROMPT: test scene');
      expect(instructions[0]['aspect_ratio'], '9:16');
      expect(instructions[0]['image_size'], '1K');
    });

    test('extracts multiple tags', () {
      final instructions = ImageTagMarkup.extractImageGenInstructions(
        '[IMG:GEN:{"prompt":"first"}] and [IMG:GEN:{"prompt":"second"}]',
      );
      expect(instructions.length, 2);
      expect(instructions[0]['prompt'], 'first');
      expect(instructions[1]['prompt'], 'second');
    });

    test('handles empty [IMG:GEN]', () {
      final instructions = ImageTagMarkup.extractImageGenInstructions(
        '[IMG:GEN:]',
      );
      expect(instructions.length, 1);
      expect(instructions[0]['prompt'], '');
    });

    test('handles real-world HTML card from LLM', () {
      const html = """Some roleplay text here.

<div style="max-width:680px; margin:28px auto; padding:18px; background:rgba(15,15,28,0.94); border:1px solid rgba(130,90,220,0.25); border-radius:20px; box-shadow:0 12px 40px rgba(0,0,0,0.75), 0 0 30px rgba(120,80,210,0.18); backdrop-filter:blur(14px);">
  <img
    data-iig-instruction='{"style":"cinematic manga and manhwa illustration","prompt":"SCENE_PROMPT: A group entering a bright living room","aspect_ratio":"9:16","image_size":"1K"}'
    src="[IMG:GEN]"
    style="display:block; width:100%; border-radius:15px;"
  >
  <div style="margin-top:15px; text-align:center; font-family:system-ui; color:rgb(200,200,200); font-size:0.9em; line-height:1.45;">
    <i>Caption text</i>
  </div>
</div>""";
      final instructions = ImageTagMarkup.extractImageGenInstructions(html);
      expect(instructions.length, 1);
      expect(
        instructions[0]['prompt'],
        contains('entering a bright living room'),
      );
      expect(instructions[0]['style'], contains('manga'));
      expect(instructions[0]['aspect_ratio'], '9:16');
    });

    test('JSON with CSS containerStyle is still parsed', () {
      const html =
          """<img data-iig-instruction='{"style":"manga","prompt":"test","containerStyle":"max-width:680px; background:rgba(15,15,28,0.94);"}' src="[IMG:GEN]">""";
      final instructions = ImageTagMarkup.extractImageGenInstructions(html);
      expect(instructions.length, 1);
      expect(instructions[0]['containerStyle'], isNotNull);
    });
  });

  group('replaceTagWithResult', () {
    test('replaces [IMG:GEN:json] with [IMG:RESULT:path|instruction]', () {
      final result = ImageTagMarkup.replaceTagWithResult(
        'Hello [IMG:GEN:{"prompt":"test"}]',
        0,
        '/path/to/image.png',
      );
      expect(result, contains('[IMG:RESULT:/path/to/image.png|'));
      expect(result, isNot(contains('[IMG:GEN')));
    });

    test('replaces HTML data-iig-instruction tag', () {
      const html =
          """<img data-iig-instruction='{"style":"manga","prompt":"test"}' src="[IMG:GEN]">""";
      final result = ImageTagMarkup.replaceTagWithResult(
        html,
        0,
        '/saved/img.png',
      );
      expect(result, contains('[IMG:RESULT:/saved/img.png|'));
      expect(result, isNot(contains('data-iig-instruction')));
    });

    test('replaces whole HTML img tag with src IMG:GEN', () {
      const html =
          """<div><img src='[IMG:GEN:{"prompt":"test"}]' alt="scene"><i>caption</i></div>""";
      final result = ImageTagMarkup.replaceTagWithResult(
        html,
        0,
        '/saved/img.png',
      );
      expect(result, contains('[IMG:RESULT:/saved/img.png|'));
      expect(result, isNot(contains('<img')));
      expect(result, contains('caption'));
    });

    test('only replaces the tag at given index', () {
      final result = ImageTagMarkup.replaceTagWithResult(
        '[IMG:GEN:{"prompt":"first"}] and [IMG:GEN:{"prompt":"second"}]',
        0,
        '/img1.png',
      );
      expect(result, contains('[IMG:RESULT:/img1.png|'));
      expect(result, contains('[IMG:GEN:{"prompt":"second"}]'));
    });
  });

  group('replaceTagWithError', () {
    test('replaces tag with error JSON', () {
      final result = ImageTagMarkup.replaceTagWithError(
        '[IMG:GEN:{"prompt":"test"}]',
        0,
        'API timeout',
      );
      expect(result, contains('[IMG:ERROR:'));
      final errorJson = result.substring(
        result.indexOf('[IMG:ERROR:') + '[IMG:ERROR:'.length,
        result.indexOf(']', result.indexOf('[IMG:ERROR:')),
      );
      final decoded = jsonDecode(errorJson) as Map<String, dynamic>;
      expect(decoded['error'], 'API timeout');
    });
  });

  group('HTTP errors', () {
    test(
      'reports status instead of Dio internals for an empty response',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        });

        String? reportedError;
        await service.processMessageImages(
          text: '[IMG:GEN:{"prompt":"test"}]',
          settings: ImageGenSettings(
            enabled: true,
            useSameEndpoint: false,
            customEndpoint: 'http://${server.address.address}:${server.port}',
            customApiKey: 'test-key',
          ),
          llmEndpoint: '',
          llmApiKey: '',
          llmModel: '',
          onError: (error) => reportedError = error,
        );

        expect(reportedError, startsWith('HTTP 404'));
        expect(reportedError, isNot(contains('RequestOptions.validateStatus')));
      },
    );
  });

  group('resetErrorTags', () {
    test('converts [IMG:ERROR:] back to [IMG:GEN:] with instruction', () {
      final errorJson = jsonEncode({
        'error': '502',
        'instruction': '{"prompt":"test"}',
      });
      final result = ImageTagMarkup.resetErrorTags('[IMG:ERROR:$errorJson]');
      expect(result, contains('[IMG:GEN:{"prompt":"test"}]'));
      expect(result, isNot(contains('[IMG:ERROR')));
    });

    test('converts [IMG:ERROR:] without instruction to bare [IMG:GEN]', () {
      final errorJson = jsonEncode({'error': 'timeout'});
      final result = ImageTagMarkup.resetErrorTags('[IMG:ERROR:$errorJson]');
      expect(result, contains('[IMG:GEN]'));
      expect(result, isNot(contains('[IMG:ERROR')));
    });

    test('converts [IMG:RESULT:] with instruction back to [IMG:GEN:]', () {
      final result = ImageTagMarkup.resetErrorTags(
        '[IMG:RESULT:/path/to/img.png|{"prompt":"scene"}]',
      );
      expect(result, contains('[IMG:GEN:{"prompt":"scene"}]'));
      expect(result, isNot(contains('[IMG:RESULT')));
    });

    test('converts [IMG:RESULT:] without instruction to bare [IMG:GEN]', () {
      final result = ImageTagMarkup.resetErrorTags(
        '[IMG:RESULT:/path/to/img.png]',
      );
      expect(result, contains('[IMG:GEN]'));
      expect(result, isNot(contains('[IMG:RESULT')));
    });

    test('converts both ERROR and RESULT in same text', () {
      final errorJson = jsonEncode({
        'error': '502',
        'instruction': '{"prompt":"first"}',
      });
      final text =
          '[IMG:ERROR:$errorJson] and [IMG:RESULT:/img.png|{"prompt":"second"}]';
      final result = ImageTagMarkup.resetErrorTags(text);
      expect(result, contains('[IMG:GEN:{"prompt":"first"}]'));
      expect(result, contains('[IMG:GEN:{"prompt":"second"}]'));
      expect(result, isNot(contains('[IMG:ERROR')));
      expect(result, isNot(contains('[IMG:RESULT')));
    });
  });

  group('prompt construction', () {
    test('SCENE_PROMPT prefix is stripped and style is prepended', () {
      const json =
          '{"style":"cinematic manga","prompt":"SCENE_PROMPT: A group walks","aspect_ratio":"9:16"}';
      final instructions = ImageTagMarkup.extractImageGenInstructions(
        '[IMG:GEN:$json]',
      );
      final rawPrompt = instructions[0]['prompt'] as String;
      final style = instructions[0]['style'] as String;
      final cleanPrompt = rawPrompt.replaceFirst(
        RegExp(r'^SCENE_PROMPT:\s*'),
        '',
      );
      final prompt = style.isNotEmpty ? '$style, $cleanPrompt' : cleanPrompt;
      expect(prompt, 'cinematic manga, A group walks');
    });

    test('labels rout.my references by their transmitted order', () {
      final prompt = imagePromptWithReferenceLabels('Danvi drives.', [
        {'name': 'Lucy', 'image': 'first'},
        {'name': 'Danvi', 'image': 'second'},
        {'name': 'context', 'image': 'third'},
      ]);

      expect(prompt, contains('Reference image 1 shows "Lucy".'));
      expect(prompt, contains('Reference image 2 shows "Danvi".'));
      expect(prompt, isNot(contains('shows "context"')));
      expect(prompt, endsWith('Danvi drives.'));
    });
  });

  group('generated image format', () {
    test('detects formats used for persisted file extensions', () {
      expect(
        imageExtensionForBytes(Uint8List.fromList([0xff, 0xd8, 0xff])),
        'jpg',
      );
      expect(
        imageExtensionForBytes(
          Uint8List.fromList([
            0x52,
            0x49,
            0x46,
            0x46,
            0,
            0,
            0,
            0,
            0x57,
            0x45,
            0x42,
            0x50,
          ]),
        ),
        'webp',
      );
      expect(imageExtensionForBytes(Uint8List.fromList([1, 2, 3])), 'png');
    });
  });

  group('ImageGenSettings defaults', () {
    test('disabled by default', () {
      const settings = ImageGenSettings();
      expect(settings.enabled, isFalse);
    });
  });

  group('processImageTags flow simulation', () {
    test('extracts prompt from HTML, strips SCENE_PROMPT, prepends style', () {
      const html = """<div style="max-width:680px;">
  <img data-iig-instruction='{"style":"cinematic manga","prompt":"SCENE_PROMPT: A group enters","aspect_ratio":"9:16","image_size":"1K"}' src="[IMG:GEN]">
</div>""";

      expect(ImageTagMarkup.hasImageGenTags(html), isTrue);

      final instructions = ImageTagMarkup.extractImageGenInstructions(html);
      expect(instructions.length, 1);

      final rawPrompt = instructions[0]['prompt'] as String;
      final style = instructions[0]['style'] as String;
      expect(rawPrompt, startsWith('SCENE_PROMPT:'));
      expect(style, 'cinematic manga');

      final cleanPrompt = rawPrompt.replaceFirst(
        RegExp(r'^SCENE_PROMPT:\s*'),
        '',
      );
      final prompt = style.isNotEmpty ? '$style, $cleanPrompt' : cleanPrompt;
      expect(prompt, 'cinematic manga, A group enters');
    });

    test('replaceTagWithResult on HTML removes entire img tag', () {
      const html = """<div>
  <img data-iig-instruction='{"style":"manga","prompt":"test"}' src="[IMG:GEN]">
  <i>caption</i>
</div>""";
      final result = ImageTagMarkup.replaceTagWithResult(html, 0, '/img.png');
      expect(result, contains('[IMG:RESULT:/img.png|'));
      expect(result, isNot(contains('data-iig-instruction')));
      expect(result, contains('caption'));
    });

    test('replaceTagWithError on HTML removes entire img tag', () {
      const html =
          """<img data-iig-instruction='{"prompt":"test"}' src="[IMG:GEN]">""";
      final result = ImageTagMarkup.replaceTagWithError(html, 0, 'timeout');
      expect(result, contains('[IMG:ERROR:'));
      expect(result, isNot(contains('data-iig-instruction')));
    });

    test('replaceTagWithError removes whole img tag with src IMG:GEN', () {
      const html = """<img src="[IMG:GEN:{"prompt":"test"}]" alt="scene">""";
      final result = ImageTagMarkup.replaceTagWithError(html, 0, 'timeout');
      expect(result, contains('[IMG:ERROR:'));
      expect(result, isNot(contains('<img')));
    });

    test('no duplicate extraction from src=[IMG:GEN] inside HTML img tag', () {
      const html =
          """<img data-iig-instruction='{"prompt":"test"}' src="[IMG:GEN]">""";
      final instructions = ImageTagMarkup.extractImageGenInstructions(html);
      expect(instructions.length, 1);
    });

    test(
      'enabled check: processMessageImages returns text unchanged when disabled',
      () async {
        const html =
            """<img data-iig-instruction='{"prompt":"test"}' src="[IMG:GEN]">""";
        final result = await service.processMessageImages(
          text: html,
          settings: const ImageGenSettings(enabled: false),
          llmEndpoint: '',
          llmApiKey: '',
          llmModel: '',
        );
        expect(result, html);
      },
    );

    test(
      'enabled check: processMessageImages processes when enabled (will fail API but test flow)',
      () async {
        const html =
            """<img data-iig-instruction='{"prompt":"test"}' src="[IMG:GEN]">""";
        final result = await service.processMessageImages(
          text: html,
          settings: const ImageGenSettings(
            enabled: true,
            apiType: ImageGenApiType.routmy,
            routmyApiKey: 'fake-key',
          ),
          llmEndpoint: '',
          llmApiKey: '',
          llmModel: '',
        );
        // Should have attempted generation and replaced with error
        expect(result, isNot(equals(html)));
        expect(result, contains('[IMG:ERROR:'));
      },
    );

    test('multiple failed image tags all settle without leaving GEN', () async {
      const text = '[IMG:GEN:{"prompt":"first"}] [IMG:GEN:{"prompt":"second"}]';
      final result = await service.processMessageImages(
        text: text,
        settings: const ImageGenSettings(
          enabled: true,
          apiType: ImageGenApiType.routmy,
          routmyApiKey: 'fake-key',
        ),
        llmEndpoint: '',
        llmApiKey: '',
        llmModel: '',
      );

      expect(ImageTagMarkup.hasImageGenTags(result), isFalse);
      expect('[IMG:ERROR:'.allMatches(result), hasLength(2));
    });
  });
}
