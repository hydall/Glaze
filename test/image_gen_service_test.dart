import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_service.dart';
import 'package:glaze_flutter/features/image_gen/services/image_prompt_builder.dart';
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

    test('ignores a tag inside a reasoning block', () {
      // INV-IG11: a model planning "then I'll put [IMG:GEN:…] here" is talking
      // to itself, not asking for a picture.
      expect(
        ImageTagMarkup.hasImageGenTags(
          '<think>next I add [IMG:GEN:{"prompt":"cat"}] here</think>She smiled.',
        ),
        isFalse,
      );
      expect(
        ImageTagMarkup.hasImageGenTags(
          "<thinking>plan: <img data-iig-instruction='{\"prompt\":\"x\"}' "
          'src="[IMG:GEN]"></thinking>Body.',
        ),
        isFalse,
      );
      expect(
        ImageTagMarkup.hasImageGenTags(
          '<THINK>maybe [IMG:GEN]</THINK> body',
        ),
        isFalse,
      );
    });

    test('a tag outside the reasoning block still generates', () {
      expect(
        ImageTagMarkup.hasImageGenTags(
          '<think>I will add one</think>Now: [IMG:GEN:{"prompt":"real"}]',
        ),
        isTrue,
      );
    });

    test('an unclosed reasoning tag is not a reasoning block', () {
      // The WebView formatter folds a block only once it closes, and the two
      // sides have to agree on what counts as reasoning.
      expect(
        ImageTagMarkup.hasImageGenTags('<think>drafting [IMG:GEN]'),
        isTrue,
      );
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

  group('disabled image generation', () {
    test('replaces pending tags with a retryable disabled error', () async {
      String? update;
      final result = await service.processMessageImages(
        text: '[IMG:GEN:{"prompt":"scene"}]',
        settings: const ImageGenSettings(enabled: false),
        llmEndpoint: '',
        llmApiKey: '',
        llmModel: '',
        onUpdate: (value) => update = value,
      );

      expect(result, contains('[IMG:ERROR:'));
      expect(result, contains('Image generation disabled'));
      expect(result, contains(r'{\"prompt\":\"scene\"}'));
      expect(update, result);
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
    test('replaces [IMG:GEN:json] with the stored <img> element', () {
      final result = ImageTagMarkup.replaceTagWithResult(
        'Hello [IMG:GEN:{"prompt":"test"}]',
        0,
        '/path/to/image.png',
      );
      expect(
        result,
        'Hello <img data-iig-instruction=\'{"prompt":"test"}\' '
            'src="/path/to/image.png">',
      );
      expect(result, isNot(contains('[IMG:GEN')));
      expect(result, isNot(contains('[IMG:RESULT')));
    });

    test('replaces HTML data-iig-instruction tag', () {
      const html =
          """<img data-iig-instruction='{"style":"manga","prompt":"test"}' src="[IMG:GEN]">""";
      final result = ImageTagMarkup.replaceTagWithResult(
        html,
        0,
        '/saved/img.png',
      );
      expect(result, contains('src="/saved/img.png"'));
      expect(result, contains(r'{"style":"manga","prompt":"test"}'));
      expect(result, isNot(contains('[IMG:GEN')));
    });

    test('replaces whole HTML img tag with src IMG:GEN', () {
      const html =
          """<div><img src='[IMG:GEN:{"prompt":"test"}]' alt="scene"><i>caption</i></div>""";
      final result = ImageTagMarkup.replaceTagWithResult(
        html,
        0,
        '/saved/img.png',
      );
      expect(result, contains('src="/saved/img.png"'));
      expect(result, isNot(contains('[IMG:GEN')));
      expect(result, contains('caption'));
    });

    test('only replaces the tag at given index', () {
      final result = ImageTagMarkup.replaceTagWithResult(
        '[IMG:GEN:{"prompt":"first"}] and [IMG:GEN:{"prompt":"second"}]',
        0,
        '/img1.png',
      );
      expect(result, contains('src="/img1.png"'));
      expect(result, contains('[IMG:GEN:{"prompt":"second"}]'));
    });

    test('resolving one HTML tag keeps the other pending blocks', () {
      const html =
          """<img data-iig-instruction='{"prompt":"first"}' src="[IMG:GEN]">"""
          """<i>caption</i>"""
          """<img data-iig-instruction='{"prompt":"second"}' src="[IMG:GEN]">""";

      final result = ImageTagMarkup.replaceTagWithResult(html, 0, '/img1.png');

      expect(result, contains('src="/img1.png"'));
      expect(result, contains('caption'));
      expect(result, contains(r'{"prompt":"second"}'));
      expect(ImageTagMarkup.pendingImageGenTagCount(result), 1);
    });

    test('a failing HTML tag stays a retryable block, not a deletion', () {
      const html =
          """<img data-iig-instruction='{"prompt":"first"}' src="[IMG:GEN]">"""
          """<img data-iig-instruction='{"prompt":"second"}' src="[IMG:GEN]">""";

      final failed = ImageTagMarkup.replaceTagWithError(html, 0, 'HTTP 502');
      expect(failed, contains('[IMG:ERROR:'));
      expect(failed, contains(r'{\"prompt\":\"first\"}'));
      expect(ImageTagMarkup.pendingImageGenTagCount(failed), 1);

      // The surviving block is still the second one, and it resolves next.
      final settled = ImageTagMarkup.replaceTagWithResult(
        failed,
        0,
        '/img2.png',
      );
      expect(settled, contains('src="/img2.png"'));
      expect(settled, contains(r'{"prompt":"second"}'));
      expect(ImageTagMarkup.pendingImageGenTagCount(settled), 0);
    });

    test('scans mixed HTML and bare tags in document order', () {
      const text =
          """[IMG:GEN:{"prompt":"one"}] """
          """<img data-iig-instruction='{"prompt":"two"}' src="[IMG:GEN]"> """
          """[IMG:GEN:{"prompt":"three"}]""";

      final instructions = ImageTagMarkup.extractImageGenInstructions(text);
      expect(instructions.map((i) => i['prompt']), [
        'one',
        'two',
        'three',
      ]);
      expect(ImageTagMarkup.pendingImageGenTagCount(text), 3);
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

    // The pending tag carries the image the block already produced, so the
    // regeneration adds a variant to the block instead of dropping the old one.
    test('converts [IMG:RESULT:] with instruction back to [IMG:GEN:]', () {
      final result = ImageTagMarkup.resetErrorTags(
        '[IMG:RESULT:/path/to/img.png|{"prompt":"scene"}]',
      );
      expect(result, contains('[IMG:GEN:@/path/to/img.png|{"prompt":"scene"}]'));
      expect(result, isNot(contains('[IMG:RESULT')));
    });

    test('converts [IMG:RESULT:] without instruction to [IMG:GEN]', () {
      final result = ImageTagMarkup.resetErrorTags(
        '[IMG:RESULT:/path/to/img.png]',
      );
      expect(result, contains('[IMG:GEN:@/path/to/img.png]'));
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
      expect(result, contains('[IMG:GEN:@/img.png|{"prompt":"second"}]'));
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

    test('images are generated one at a time by default', () {
      const settings = ImageGenSettings();
      expect(settings.concurrentGeneration, isFalse);
    });
  });

  group('per-image blocks', () {
    // Result, error and pending, in that document order. This is the numbering
    // the webview stamps onto each rendered block as data-img-index.
    const message =
        '[IMG:RESULT:/one.png|{"prompt":"one"}] text '
        '[IMG:ERROR:{"error":"boom","instruction":"{\\"prompt\\":\\"two\\"}"}] '
        '[IMG:GEN:{"prompt":"three"}]';

    test('scans every block once, in document order', () {
      final blocks = ImageTagMarkup.scanImageBlocks(message);

      expect(blocks.map((b) => b.kind), [
        ImageBlockKind.result,
        ImageBlockKind.error,
        ImageBlockKind.pending,
      ]);
      expect(blocks[0].imagePath, '/one.png');
      expect(blocks[1].asPendingTag, '[IMG:GEN:{"prompt":"two"}]');
      expect(blocks[2].asPendingTag, '[IMG:GEN:{"prompt":"three"}]');
    });

    test('resetting the failed block leaves the finished image alone', () {
      final result = ImageTagMarkup.resetImageBlockAt(message, 1);

      expect(result, contains('[IMG:RESULT:/one.png|{"prompt":"one"}]'));
      expect(result, contains('[IMG:GEN:{"prompt":"two"}]'));
      expect(result, isNot(contains('[IMG:ERROR:')));
      expect(result, contains('[IMG:GEN:{"prompt":"three"}]'));
    });

    test('rerolling a finished image only touches that image', () {
      final result = ImageTagMarkup.resetImageBlockAt(message, 0);

      expect(result, startsWith('[IMG:GEN:@/one.png|{"prompt":"one"}]'));
      expect(result, contains('[IMG:ERROR:'));
      expect(ImageTagMarkup.pendingImageGenTagCount(result), 2);
    });

    test('a block already waiting for its image is left as it is', () {
      expect(ImageTagMarkup.resetImageBlockAt(message, 2), message);
    });

    test('an index outside the message changes nothing', () {
      expect(ImageTagMarkup.resetImageBlockAt(message, 3), message);
      expect(ImageTagMarkup.resetImageBlockAt(message, -1), message);
    });

    test('a recovered file is attached to the addressed block', () {
      final result = ImageTagMarkup.replaceImageBlockWithResult(
        message,
        1,
        '/found.png',
      );

      expect(
        result,
        contains(
          '<img data-iig-instruction=\'{"prompt":"two"}\' src="/found.png">',
        ),
      );
      expect(result, contains('[IMG:RESULT:/one.png|{"prompt":"one"}]'));
      expect(result, contains('[IMG:GEN:{"prompt":"three"}]'));
    });

    test('a reasoning block is outside the numbering', () {
      // The WebView renders a tag inside `<think>` as the text the model wrote
      // and never allocates a data-img-index for it, so Dart must not count it
      // either — otherwise a tap on the body's only picture addresses nothing.
      const withReasoning =
          '<think>first I will do [IMG:GEN:{"prompt":"planned"}]</think>'
          'She smiled. [IMG:GEN:{"prompt":"real"}]';

      final blocks = ImageTagMarkup.scanImageBlocks(withReasoning);
      expect(blocks.map((b) => b.kind), [ImageBlockKind.pending]);
      expect(blocks.single.asPendingTag, '[IMG:GEN:{"prompt":"real"}]');
      expect(ImageTagMarkup.pendingImageGenTagCount(withReasoning), 1);
    });

    test('the reasoning block survives a generation untouched', () {
      const withReasoning =
          '<think>plan: [IMG:GEN:{"prompt":"planned"}]</think>'
          'Body. [IMG:GEN:{"prompt":"real"}]';

      final resolved = ImageTagMarkup.replaceImageBlockWithResult(
        withReasoning,
        0,
        '/real.png',
      );

      expect(
        resolved,
        contains('<think>plan: [IMG:GEN:{"prompt":"planned"}]</think>'),
      );
      expect(resolved, contains('src="/real.png"'));
    });

    test('block numbering survives HTML tags that have not resolved yet', () {
      const mixed =
          '[IMG:RESULT:/one.png|{"prompt":"one"}]'
          """<img data-iig-instruction='{"prompt":"two"}' src="[IMG:GEN]">""";

      final blocks = ImageTagMarkup.scanImageBlocks(mixed);
      expect(blocks.map((b) => b.kind), [
        ImageBlockKind.result,
        ImageBlockKind.pending,
      ]);
    });
  });

  group('generation order', () {
    // Answers 404 after a short delay and records how many requests were being
    // served at the same moment.
    Future<(HttpServer, int Function())> startProbeServer() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var inFlight = 0;
      var maxInFlight = 0;
      server.listen((request) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await request.drain<void>();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        inFlight--;
      });
      return (server, () => maxInFlight);
    }

    ImageGenSettings settingsFor(HttpServer server, {required bool parallel}) =>
        ImageGenSettings(
          enabled: true,
          concurrentGeneration: parallel,
          useSameEndpoint: false,
          customEndpoint: 'http://${server.address.address}:${server.port}',
          customApiKey: 'test-key',
        );

    const threeTags =
        '[IMG:GEN:{"prompt":"one"}] '
        '[IMG:GEN:{"prompt":"two"}] '
        '[IMG:GEN:{"prompt":"three"}]';

    test('off — each image is requested only after the previous one', () async {
      final (server, maxInFlight) = await startProbeServer();
      addTearDown(() => server.close(force: true));

      final result = await service.processMessageImages(
        text: threeTags,
        settings: settingsFor(server, parallel: false),
        llmEndpoint: '',
        llmApiKey: '',
        llmModel: '',
      );

      expect(maxInFlight(), 1);
      expect(ImageTagMarkup.hasImageGenTags(result), isFalse);
      expect('[IMG:ERROR:'.allMatches(result), hasLength(3));
    });

    test('on — the images of a message are requested together', () async {
      final (server, maxInFlight) = await startProbeServer();
      addTearDown(() => server.close(force: true));

      final result = await service.processMessageImages(
        text: threeTags,
        settings: settingsFor(server, parallel: true),
        llmEndpoint: '',
        llmApiKey: '',
        llmModel: '',
      );

      expect(maxInFlight(), greaterThan(1));
      expect(ImageTagMarkup.hasImageGenTags(result), isFalse);
      expect('[IMG:ERROR:'.allMatches(result), hasLength(3));
    });

    test('every failure keeps its own block and instruction', () async {
      final (server, _) = await startProbeServer();
      addTearDown(() => server.close(force: true));

      final result = await service.processMessageImages(
        text: threeTags,
        settings: settingsFor(server, parallel: false),
        llmEndpoint: '',
        llmApiKey: '',
        llmModel: '',
      );

      for (final prompt in ['one', 'two', 'three']) {
        expect(result, contains('\\"prompt\\":\\"$prompt\\"'));
      }
      expect(ImageTagMarkup.resetErrorTags(result), threeTags);
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

    test('replaceTagWithResult on HTML replaces the whole img tag', () {
      const html = """<div>
  <img data-iig-instruction='{"style":"manga","prompt":"test"}' src="[IMG:GEN]">
  <i>caption</i>
</div>""";
      final result = ImageTagMarkup.replaceTagWithResult(html, 0, '/img.png');
      expect(result, contains('src="/img.png"'));
      expect(result, isNot(contains('[IMG:GEN')));
      // The element that carried the instruction is gone, replaced whole by
      // the one that carries the image — the surrounding card is untouched.
      expect(result, isNot(contains('src="[IMG:GEN]"')));
      expect(ImageTagMarkup.pendingImageGenTagCount(result), 0);
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
      'enabled check: processMessageImages settles HTML tags when disabled',
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
        expect(result, contains('[IMG:ERROR:'));
        expect(result, contains('Image generation disabled'));
        expect(result, isNot(contains('data-iig-instruction')));
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
