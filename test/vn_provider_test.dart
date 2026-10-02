import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/vn/models/vn_document.dart';
import 'package:glaze_flutter/features/vn/services/vn_generator_service.dart';
import 'package:glaze_flutter/features/vn/services/vn_sprite_service.dart';
import 'package:glaze_flutter/features/vn/vn_provider.dart';

/// Writes canned passes and records what it was asked for.
class _FakeGenerator extends VnGeneratorService {
  _FakeGenerator(super.ref);

  final List<VnPass> calls = [];
  final List<VnPlayState?> states = [];
  final List<VnPersona?> personas = [];

  /// When set, the next chapter waits on it.
  Completer<String>? hold;

  @override
  Future<String> writePass({
    required VnDocument doc,
    required VnPass pass,
    required String language,
    VnPlayState? state,
    VnPersona? persona,
    CancelToken? cancelToken,
  }) async {
    calls.add(pass);
    states.add(state);
    personas.add(persona);
    final n = doc.nextChapterNumber;
    return switch (pass) {
      VnPass.scenario => 'title: Тест\nA story.',
      VnPass.characters => 'cast mia "Мия"',
      VnPass.locations => 'location hall\nroom 8 8',
      VnPass.textures => 'texture oak planks #886644',
      VnPass.chapter =>
        hold != null
            ? await hold!.future
            : 'summary: part $n (${calls.length})\n# s$n < hall\nnext',
    };
  }
}

/// Draws nothing: returns made-up paths and records what it was asked.
class _FakeSprites extends VnSpriteService {
  _FakeSprites(super.ref, this.gen);

  final _FakeGenerator gen;

  /// Per draw: the cast id, the note, and how many passes were written.
  final List<(String, String?, int)> draws = [];
  final List<String> removed = [];

  @override
  Future<VnDrawn> draw({
    required String sessionId,
    required VnCastMember who,
    required String setting,
    required String size,
    String? note,
    CancelToken? cancelToken,
  }) async {
    draws.add((who.id, note, gen.calls.length));
    return VnDrawn(
      {'normal': 'vn_sprites/$sessionId/${who.id}_${draws.length}.png'},
      {'sad': 'HTTP 429'},
    );
  }

  @override
  Future<Map<String, String>> drawEmotion({
    required String sessionId,
    required VnCastMember who,
    required String emotion,
    required Map<String, String> current,
    CancelToken? cancelToken,
  }) async {
    draws.add((who.id, emotion, gen.calls.length));
    return {
      ...current,
      emotion: 'vn_sprites/$sessionId/${who.id}_$emotion.png',
    };
  }

  @override
  Future<void> remove(Iterable<String> paths) async => removed.addAll(paths);
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late _FakeGenerator gen;
  late _FakeSprites sprites;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        vnGeneratorServiceProvider.overrideWith((ref) {
          return gen = _FakeGenerator(ref);
        }),
        vnSpriteServiceProvider.overrideWith((ref) {
          return sprites = _FakeSprites(ref, gen);
        }),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<VnNotifier> playable({String? artSize}) async {
    final id = await createVnSession(
      container.read(chatRepoProvider),
      'idea',
      persona: const VnPersona(name: 'Лис'),
      artSize: artSize,
    );
    await container.read(vnProvider(id).future);
    final notifier = container.read(vnProvider(id).notifier);
    await notifier.writeSetup(language: 'Russian');
    return notifier;
  }

  VnState stateOf(VnNotifier n) =>
      container.read(vnProvider(n.sessionId)).value!;

  Map<String, dynamic> snapshot(List<String> choices) => {
    'scene': 's1',
    'flags': <String>[],
    'log': [
      for (final c in choices) {'scene': 's1', 'choice': c},
    ],
  };

  test(
    'the setup runs in order with the persona and names the novel',
    () async {
      final n = await playable();
      expect(gen.calls, [
        VnPass.scenario,
        VnPass.characters,
        VnPass.locations,
        VnPass.textures,
        VnPass.chapter,
      ]);
      expect(gen.personas.every((p) => p?.name == 'Лис'), isTrue);
      final s = stateOf(n);
      expect(s.doc.playable, isTrue);
      expect(s.session.sessionVars['sessionName'], 'Тест');
    },
  );

  test('a chapter written ahead is used when nothing changed', () async {
    final n = await playable();
    await n.writeAhead(language: 'Russian', snapshot: snapshot(['a']));
    expect(gen.calls.where((p) => p == VnPass.chapter), hasLength(2));

    final ok = await n.continueStory(
      language: 'Russian',
      snapshot: {
        ...snapshot(['a']),
        'next': {'scene': 's1', 'hint': '', 'part': 1},
      },
    );
    expect(ok, isTrue);
    // No third request: the banked chapter became chapter 2.
    expect(gen.calls.where((p) => p == VnPass.chapter), hasLength(2));
    final s = stateOf(n);
    expect(s.doc.chapters, hasLength(2));
    expect(s.doc.chapters.last.summary, 'part 2 (6)');
    expect(s.session.sessionVars.containsKey(kVnPrefetchVarKey), isFalse);
  });

  test('a choice made after writing ahead gets a fresh chapter', () async {
    final n = await playable();
    await n.writeAhead(language: 'Russian', snapshot: snapshot(['a']));
    await n.continueStory(language: 'Russian', snapshot: snapshot(['a', 'b']));
    expect(gen.calls.where((p) => p == VnPass.chapter), hasLength(3));
    expect(gen.states.last?.choices, ['s1: a', 's1: b']);
    expect(stateOf(n).doc.chapters.last.summary, 'part 2 (7)');
  });

  test(
    'reaching next while the chapter is still being written waits on it',
    () async {
      final n = await playable();
      gen.hold = Completer<String>();
      final ahead = n.writeAhead(language: 'Russian', snapshot: snapshot([]));
      final cont = n.continueStory(language: 'Russian', snapshot: snapshot([]));
      await Future<void>.delayed(Duration.zero);
      expect(stateOf(n).writing, VnPass.chapter);
      gen.hold!.complete('summary: ahead\n# s2 < hall\nnext');
      expect(await cont, isTrue);
      await ahead;
      expect(gen.calls.where((p) => p == VnPass.chapter), hasLength(2));
      expect(stateOf(n).doc.chapters.last.summary, 'ahead');
    },
  );

  group('drawing the cast', () {
    test('starts right after the characters and holds the game', () async {
      final n = await playable(artSize: '2K');
      await pumpEventQueue();
      // Drawn once the scenario and the characters were written.
      expect(sprites.draws, [('mia', null, 2)]);
      var s = stateOf(n);
      expect(s.doc.playable, isTrue);
      expect(s.ready, isFalse, reason: 'the cast waits for the player');
      expect(vnSpritesOf(s.session.sessionVars).keys, ['mia']);

      await n.approveCast();
      s = stateOf(n);
      expect(s.ready, isTrue);
    });

    test('a redraw keeps the note and replaces the old sprites', () async {
      final n = await playable(artSize: '2K');
      await pumpEventQueue();
      final old = vnSpritesOf(stateOf(n).session.sessionVars)['mia']!;
      await n.redraw('mia', 'short hair');
      expect(sprites.draws.last.$2, 'short hair');
      final s = stateOf(n);
      expect(vnArtNotesOf(s.session.sessionVars), {'mia': 'short hair'});
      expect(vnSpritesOf(s.session.sessionVars)['mia'], isNot(old));
      expect(sprites.removed, old.values);
    });

    test('going on without pictures opens the game', () async {
      final n = await playable(artSize: '2K');
      await pumpEventQueue();
      await n.skipArt();
      final s = stateOf(n);
      expect(s.drawsCast, isFalse);
      expect(s.ready, isTrue);
    });

    test('a novel without drawing never waits', () async {
      final fake = container.read(vnSpriteServiceProvider) as _FakeSprites;
      final n = await playable();
      await pumpEventQueue();
      expect(fake.draws, isEmpty);
      expect(stateOf(n).ready, isTrue);
    });

    test('one emotion is drawn again and its failure forgotten', () async {
      final n = await playable(artSize: '2K');
      await pumpEventQueue();
      expect(stateOf(n).artMissing['mia'], {'sad': 'HTTP 429'});
      await n.redrawEmotion('mia', 'sad');
      final s = stateOf(n);
      expect(sprites.draws.last.$2, 'sad');
      expect(vnSpritesOf(s.session.sessionVars)['mia']!.keys, [
        'normal',
        'sad',
      ]);
      expect(s.artMissing['mia'], isEmpty);
      expect(s.drawing, isNull);
    });
  });
}
