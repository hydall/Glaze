import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/image_recovery_service.dart';
import 'package:glaze_flutter/features/chat/services/saved_message_writer.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';

/// A finished image block is Glaze's own bookkeeping: it names files on this
/// device and lists every image the block has produced. It used to reach the
/// model in the history and come back written into the reply, which left a
/// message pointing at pictures nobody ever generated — a broken image with a
/// switcher counting one more of them every turn (INV-IG12).
void main() {
  const instruction = '{"prompt":"a red dragon"}';

  String finishedBlock({
    List<String> paths = const ['generated/a.png', 'generated/b.png'],
    int activeIndex = 1,
  }) => ImageTagMarkup.encodeResultElement(
    ImageBlockPayload(
      paths: paths,
      activeIndex: activeIndex,
      instruction: instruction,
    ),
  );

  group('reduceBlocksToInstructions', () {
    test('a finished block keeps its prompt and loses its images', () {
      final reduced = ImageTagMarkup.reduceBlocksToInstructions(
        'Scene: ${finishedBlock()} — and on.',
      );

      expect(reduced, 'Scene: [IMG:GEN:$instruction] — and on.');
      expect(reduced, isNot(contains('generated/')));
      expect(reduced, isNot(contains('data-iig-variants')));
      expect(reduced, isNot(contains('data-iig-index')));
    });

    test('the older tag spellings reduce to the same thing', () {
      expect(
        ImageTagMarkup.reduceBlocksToInstructions(
          '[IMG:RESULT:generated/a.png;;*generated/b.png|$instruction]',
        ),
        '[IMG:GEN:$instruction]',
      );
      expect(
        ImageTagMarkup.reduceBlocksToInstructions(
          '[IMG:GEN:@generated/a.png;;generated/b.png|$instruction]',
        ),
        '[IMG:GEN:$instruction]',
      );
      expect(
        ImageTagMarkup.reduceBlocksToInstructions(
          '[IMG:ERROR:{"error":"boom","instruction":"{}"}]',
        ),
        '[IMG:GEN:{}]',
      );
    });

    test('a block that never had a prompt reduces to the bare tag', () {
      expect(
        ImageTagMarkup.reduceBlocksToInstructions(
          '[IMG:RESULT:generated/a.png]',
        ),
        '[IMG:GEN]',
      );
    });

    test('each block of a message is reduced on its own', () {
      final reduced = ImageTagMarkup.reduceBlocksToInstructions(
        '${finishedBlock()} middle [IMG:GEN:{"prompt":"second"}]',
      );

      expect(
        reduced,
        '[IMG:GEN:$instruction] middle [IMG:GEN:{"prompt":"second"}]',
      );
    });

    test('a tag inside a reasoning block stays the text it is', () {
      const text = '<think>then [IMG:GEN:{"prompt":"idea"}] here</think>done';

      expect(ImageTagMarkup.reduceBlocksToInstructions(text), text);
    });

    test('text with no image block comes back unchanged', () {
      const text = 'She looks up. <b>Really</b>.';

      expect(ImageTagMarkup.reduceBlocksToInstructions(text), same(text));
    });
  });

  group('the model never reads a finished block', () {
    test('history carries the instruction, not the file paths', () {
      const macroCtx = MacroContext(
        charName: 'Alison',
        charId: 'character',
        sessionId: 'session',
      );

      final history = HistoryAssembler(macroCtx).assemble([
        const ChatMessage(id: 'u1', role: 'user', content: 'Draw her'),
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'Here. ${finishedBlock()}',
        ),
      ]);

      expect(history[1].content, 'Here. [IMG:GEN:$instruction]');
      expect(history[1].content, isNot(contains('generated/')));
    });
  });

  group('the model never writes a finished block', () {
    const writer = SavedMessageWriter();
    final session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        const ChatMessage(id: 'u1', role: 'user', content: 'Draw her'),
      ],
    );

    test('a reply asking for a picture is stored as a pending block', () {
      final invented = finishedBlock(
        paths: const ['generated/made-up.png'],
        activeIndex: 0,
      );
      final state = writer.writeAssistant(
        text: 'Here. $invented',
        reasoning: null,
        currentSession: session,
        isAborted: () => false,
      );

      final stored = state.session!.messages.last;
      expect(stored.content, 'Here. [IMG:GEN:$instruction]');
      expect(stored.content, isNot(contains('made-up.png')));
      expect(stored.swipes.single, stored.content);
      expect(stored.agentSwipes.single.content, stored.content);
      expect(ImageTagMarkup.hasImageGenTags(stored.content), isTrue);
    });

    test('a reply with no image markup is stored verbatim', () {
      final state = writer.writeAssistant(
        text: 'She looks up.',
        reasoning: null,
        currentSession: session,
        isAborted: () => false,
      );

      expect(state.session!.messages.last.content, 'She looks up.');
    });
  });

  group('a regeneration carries forward only what is on disk', () {
    late Directory dir;
    late String present;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('glaze_img_test');
      present = '${dir.path}/present.png';
      File(present).writeAsBytesSync([0]);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('a missing image is dropped from the pending block', () {
      final pending = '[IMG:GEN:@$present;;*${dir.path}/gone.png|$instruction]';

      expect(
        ImageRecoveryService.dropMissingImages(pending),
        '[IMG:GEN:@$present|$instruction]',
      );
    });

    test('a block whose images all exist is left alone', () {
      final pending = '[IMG:GEN:@$present|$instruction]';

      expect(ImageRecoveryService.dropMissingImages(pending), pending);
    });

    test('a remote picture is taken at its word', () {
      expect(
        ImageRecoveryService.imageFileExists('https://example.com/a.png'),
        isTrue,
      );
      expect(
        ImageRecoveryService.imageFileExists('data:image/png;base64,x'),
        isTrue,
      );
      expect(
        ImageRecoveryService.imageFileExists('${dir.path}/gone.png'),
        isFalse,
      );
    });
  });
}
