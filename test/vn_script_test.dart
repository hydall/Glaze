import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/vn/models/vn_document.dart';
import 'package:glaze_flutter/features/vn/services/vn_prompts.dart';
import 'package:glaze_flutter/features/vn/services/vn_script.dart';

ChatMessage _user(String text) =>
    ChatMessage(id: 'u', role: 'user', content: text);

ChatMessage _pass(VnPass pass, String body, {int chapter = 0}) => ChatMessage(
  id: '${pass.name}$chapter',
  role: 'assistant',
  content: formatVnPass(pass, body, chapter: chapter),
);

List<ChatMessage> _setup() => [
  _user('a haunted library'),
  _pass(VnPass.scenario, 'title: Пыльные страницы\nA mystery.'),
  _pass(VnPass.characters, 'cast mia "Мия" #ff8fb8\nabout mia: librarian'),
  _pass(
    VnPass.locations,
    'location hall\nroom 10 8 floor oak wall none\nlight night\n'
    'location stacks\nroom 6 12 floor #776655 wall cream',
  ),
  _pass(
    VnPass.textures,
    'texture oak planks #8a6448\ntexture cream plain #eee',
  ),
];

void main() {
  group('cleanVnReply', () {
    test('takes the fenced block and drops reasoning', () {
      const reply =
          '<think>plan the rooms</think>Here it is:\n'
          '```vn\n# hall\nroom 8 8\n> Hello\n```\nEnjoy!';
      expect(cleanVnReply(reply), '# hall\nroom 8 8\n> Hello');
    });
  });

  group('extractVnPass', () {
    test('rejects a pass without its defining lines', () {
      expect(extractVnPass(VnPass.characters, 'Sure! Here you go.'), isNull);
      expect(extractVnPass(VnPass.locations, 'cast a "A"'), isNull);
      expect(extractVnPass(VnPass.chapter, '> only narration'), isNull);
    });

    test('a chapter never ends the story', () {
      expect(
        extractVnPass(VnPass.chapter, '# a < hall\n> hi\n  end'),
        '# a < hall\n> hi\n  next',
      );
      expect(
        extractVnPass(VnPass.chapter, '# a < hall\n> hi'),
        '# a < hall\n> hi\nnext',
      );
    });
  });

  group('VnDocument', () {
    test('runs the setup passes in order, then the first chapter', () {
      expect(
        VnDocument.fromMessages([_user('x')]).pendingPass,
        VnPass.scenario,
      );
      final setup = _setup();
      expect(
        VnDocument.fromMessages(setup.sublist(0, 3)).pendingPass,
        VnPass.locations,
      );
      final doc = VnDocument.fromMessages(setup);
      expect(doc.pendingPass, VnPass.chapter);
      expect(doc.playable, isFalse);
      expect(doc.title, 'Пыльные страницы');
      expect(doc.premise, 'a haunted library');
      expect(doc.referencedTextures, ['oak', 'cream']);
    });

    test('assembles the script without summaries, parts split by ---', () {
      final doc = VnDocument.fromMessages([
        ..._setup(),
        _pass(
          VnPass.chapter,
          'summary: Мия находит письмо.\n# reading < hall\n> Тихо.\nnext',
          chapter: 1,
        ),
        _pass(
          VnPass.chapter,
          'summary: Ночь.\ncast ken "Кен"\n# night < stacks\nnext',
          chapter: 2,
        ),
      ]);
      expect(doc.playable, isTrue);
      expect(doc.nextChapterNumber, 3);
      expect(doc.chapters.first.summary, 'Мия находит письмо.');
      expect(doc.chapters.last.opensOn, 'night');
      expect(doc.script, isNot(contains('summary')));
      expect('\n---\n'.allMatches(doc.script).length, 4);
      expect(doc.sceneIds, ['reading', 'night']);
      // Definitions written in a chapter reach later prompts.
      expect(doc.definitions, contains('cast ken "Кен"'));
      expect(doc.definitions, contains('  room 6 12 floor #776655 wall cream'));
    });
  });

  group('resumeSnapshot', () {
    final doc = VnDocument.fromMessages([
      ..._setup(),
      _pass(VnPass.chapter, '# one < hall\nnext', chapter: 1),
      _pass(VnPass.chapter, '# two < stacks\nnext', chapter: 2),
    ]);

    test('keeps an unanswered next', () {
      final play = VnPlayState({
        'scene': 'two',
        'pos': {'x': 1, 'z': 2, 'yaw': 0},
        'next': {'scene': 'two', 'hint': 'утро', 'part': 2},
      });
      final snap = resumeSnapshot(doc, play)!;
      expect(snap['scene'], 'two');
      expect(snap['next'], isNotNull);
      expect(snap['pos'], isNotNull);
    });

    test('moves a next answered while closed into the new chapter', () {
      final play = VnPlayState({
        'scene': 'one',
        'pos': {'x': 1, 'z': 2, 'yaw': 0},
        'next': {'scene': 'one', 'hint': '', 'part': 1},
      });
      final snap = resumeSnapshot(doc, play)!;
      expect(snap['scene'], 'two');
      expect(snap.containsKey('next'), isFalse);
      expect(snap.containsKey('pos'), isFalse);
    });
  });

  test('a continuation carries the choices, flags and last part', () {
    final doc = VnDocument.fromMessages([
      ..._setup(),
      _pass(
        VnPass.chapter,
        'summary: Письмо.\n# one < hall\n? Открыть -> two\nnext дверь',
        chapter: 1,
      ),
    ]);
    final messages = buildVnPassMessages(
      spec: 'SPEC',
      doc: doc,
      pass: VnPass.chapter,
      language: 'Russian',
      state: const VnPlayState({
        'flags': ['letter'],
        'log': [
          {'scene': 'one', 'choice': 'Открыть'},
        ],
        'next': {'scene': 'one', 'hint': 'дверь', 'part': 1},
      }),
    );
    expect(messages.first, {'role': 'system', 'content': 'SPEC'});
    final user = messages.last['content']!;
    expect(user, contains('PART 2'));
    expect(user, contains('Part 1: Письмо.'));
    expect(user, contains('- one: Открыть'));
    expect(user, contains('Flags set: letter'));
    expect(user, contains('The last part ended with: дверь'));
    // The task comes last, after everything it reads.
    expect(user.indexOf('TASK'), greaterThan(user.indexOf('WHERE THE PLAYER')));
  });

  group('buildVnPage', () {
    test('inlines both scripts and escapes a closing script tag', () {
      final page = buildVnPage(
        shell: '<body><!--VN3D_THREE--><!--VN3D_ENGINE--></body>',
        three: 'var a = "</script>";',
        engine: 'run();',
      );
      expect(
        page,
        '<body><script>var a = "<\\/script>";</script>'
        '<script>run();</script></body>',
      );
    });

    test('the bundled shell has both slots', () {
      final shell = File(kVnPageAsset).readAsStringSync();
      expect(
        () => buildVnPage(shell: shell, three: '', engine: ''),
        returnsNormally,
      );
    });
  });

  test('novel ids are recognised and never look like character ids', () {
    final ids = newVnIds();
    expect(isVnCharacterId(ids.characterId), isTrue);
    expect(ids.sessionId, '${ids.characterId}_0');
    expect(isVnCharacterId('m1abc0001'), isFalse);
  });
}
