import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/vn/models/vn_document.dart';
import 'package:glaze_flutter/features/vn/services/vn_generator_service.dart';
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

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late _FakeGenerator gen;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        vnGeneratorServiceProvider.overrideWith((ref) {
          return gen = _FakeGenerator(ref);
        }),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<VnNotifier> playable() async {
    final id = await createVnSession(
      container.read(chatRepoProvider),
      'idea',
      persona: const VnPersona(name: 'Лис'),
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
}
