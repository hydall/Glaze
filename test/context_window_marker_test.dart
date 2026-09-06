import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/history_trim.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/state/cached_token_breakdown.dart';
import 'package:glaze_flutter/features/chat/state/context_window_marker.dart';

/// History of [count] messages, each roughly the same size, ids `m0..mN`.
List<PromptMessage> _history(int count) => [
  for (var i = 0; i < count; i++)
    PromptMessage(
      role: i.isEven ? 'user' : 'assistant',
      content: 'message $i ${'filler ' * 20}',
      sourceMessageId: 'm$i',
      isHistory: true,
    ),
];

TokenBreakdown _run(
  List<PromptMessage> history, {
  required String mode,
  String? anchorId,
  int contextSize = 4000,
}) => ContextCalculator(
  contextSize: contextSize,
  maxTokens: 1000,
  historyTrimMode: mode,
  historyAnchorId: anchorId,
).calculate(staticBlocks: const [], historyMessages: history);

/// A chat of [count] messages with the same ids the history above carries, so
/// a breakdown taken over that history points at messages this session has.
Future<ProviderContainer> _openChat(int count) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [appDbProvider.overrideWithValue(db)],
  );
  addTearDown(() async {
    container.dispose();
    ChatSessionService.clearCache();
    await db.close();
  });
  await container
      .read(characterRepoProvider)
      .put(const Character(id: 'c1', name: 'Test', currentSessionIndex: 0));
  await container
      .read(chatRepoProvider)
      .put(
        ChatSession(
          id: 'c1_0',
          characterId: 'c1',
          sessionIndex: 0,
          messages: [
            for (var i = 0; i < count; i++)
              ChatMessage(
                id: 'm$i',
                role: i.isEven ? 'user' : 'assistant',
                content: 'message $i',
                timestamp: i,
              ),
          ],
        ),
      );
  await container.read(chatProvider('c1').future);
  return container;
}

/// What the chat would draw the rule at, given [breakdown] as the last
/// calculated prompt.
String? _marker(ProviderContainer container, TokenBreakdown breakdown) {
  container.read(cachedTokenBreakdownProvider('c1').notifier).state = breakdown;
  return container.read(contextWindowStartProvider('c1'));
}

/// The boundary the chat draws its CONTEXT LIMIT rule at: the oldest message
/// the prompt still carries. It is read off the breakdown rather than
/// re-derived, so it has to be right under either trim mode.
void main() {
  group('windowStartMessageId', () {
    test('sliding marks the oldest message that survived the cut', () {
      final result = _run(_history(80), mode: HistoryTrimMode.sliding);

      expect(result.cutoffIndex, greaterThan(0));
      expect(result.windowStartMessageId, 'm${result.cutoffIndex}');
      expect(
        result.windowStartMessageId,
        result.trimmedHistory.first.sourceMessageId,
      );
    });

    test('stepped marks the anchor it holds the window open on', () {
      final result = _run(_history(80), mode: HistoryTrimMode.stepped);

      expect(result.cutoffIndex, greaterThan(0));
      expect(result.windowStartMessageId, result.historyAnchorId);
    });

    test('stepped holds the boundary still while the anchor does', () {
      final first = _run(_history(80), mode: HistoryTrimMode.stepped);
      final anchor = first.windowStartMessageId!;

      final later = _run(
        _history(84),
        mode: HistoryTrimMode.stepped,
        anchorId: anchor,
      );

      expect(
        later.windowStartMessageId,
        anchor,
        reason: 'the rule may not creep down the chat between steps',
      );
    });

    test('sliding moves the boundary as the chat grows', () {
      final first = _run(_history(80), mode: HistoryTrimMode.sliding);
      final later = _run(_history(90), mode: HistoryTrimMode.sliding);

      expect(later.cutoffIndex, greaterThan(first.cutoffIndex));
      expect(
        later.windowStartMessageId,
        isNot(first.windowStartMessageId),
        reason: 'a sliding cut starts at a different message every turn',
      );
    });

    test('a chat that fits whole reports a boundary but no cut', () {
      final result = _run(
        _history(5),
        mode: HistoryTrimMode.sliding,
        contextSize: 40000,
      );

      expect(result.cutoffIndex, 0);
      expect(
        result.windowStartMessageId,
        'm0',
        reason:
            'the window starts at the first message; it is the zero cutoff, '
            'not a null id, that tells the chat there is no rule to draw',
      );
    });

    test('an empty window has no boundary', () {
      final result = _run(
        _history(40),
        mode: HistoryTrimMode.sliding,
        // maxTokens (1000) eats the whole window, so nothing fits.
        contextSize: 1000,
      );

      expect(result.trimmedHistory, isEmpty);
      expect(result.windowStartMessageId, isNull);
    });
  });

  // The rule has to appear under either trim mode — the modes cut differently,
  // and the marker is the only place in the chat that says where the prompt
  // begins.
  group('contextWindowStartProvider', () {
    test('draws the rule at the sliding cut', () async {
      final container = await _openChat(80);
      final breakdown = _run(_history(80), mode: HistoryTrimMode.sliding);

      expect(breakdown.cutoffIndex, greaterThan(0));
      expect(_marker(container, breakdown), 'm${breakdown.cutoffIndex}');
    });

    test('draws the rule at the stepped anchor', () async {
      final container = await _openChat(80);
      final breakdown = _run(_history(80), mode: HistoryTrimMode.stepped);

      expect(breakdown.cutoffIndex, greaterThan(0));
      expect(breakdown.historyAnchorId, isNotNull);
      expect(_marker(container, breakdown), breakdown.historyAnchorId);
    });

    test('a chat that fits whole gets no rule', () async {
      final container = await _openChat(5);
      final breakdown = _run(
        _history(5),
        mode: HistoryTrimMode.stepped,
        contextSize: 40000,
      );

      expect(breakdown.cutoffIndex, 0);
      expect(_marker(container, breakdown), isNull);
    });

    test('a boundary this chat has no message for is dropped', () async {
      // What a session switch leaves behind: the character's cached breakdown
      // still describes the chat that was open when it was built.
      final container = await _openChat(20);
      final breakdown = _run(_history(80), mode: HistoryTrimMode.stepped);

      expect(breakdown.windowStartMessageId, isNotNull);
      expect(_marker(container, breakdown), isNull);
    });

    test('no calculated prompt yet means no rule', () async {
      final container = await _openChat(80);

      expect(container.read(contextWindowStartProvider('c1')), isNull);
    });
  });
}
