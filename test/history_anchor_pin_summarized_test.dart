import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/summary_block.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/state/cached_token_breakdown.dart';

/// After a summary run the oldest raw message is the first the history can
/// start at; the one before it is in a block and not in the prompt. Pinning
/// the cache anchor on it used to be refused as "too far back", which no
/// window size fixes: the pin is refused up front, and the prompt is not
/// recounted for it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const messages = [
    ChatMessage(id: 'm1', role: 'user', content: 'One'),
    ChatMessage(id: 'm2', role: 'assistant', content: 'Two'),
    ChatMessage(id: 'm3', role: 'user', content: 'Three'),
    ChatMessage(id: 'm4', role: 'assistant', content: 'Four'),
  ];

  test(
    'a message the summary stands in for cannot anchor the history',
    () async {
      SharedPreferences.setMockInitialValues({});
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
            const ChatSession(
              id: 'c1_0',
              characterId: 'c1',
              sessionIndex: 0,
              messages: messages,
            ),
          );
      const covered = ['m1', 'm2'];
      await container
          .read(summaryServiceProvider)
          .saveBlocks(
            sessionId: 'c1_0',
            messages: messages,
            blocks: [
              SummaryBlock(
                id: 'b1',
                level: 1,
                content: 'One and two, retold.',
                messageIds: covered,
                sourceHash: SummaryChain.fingerprint(
                  covered,
                  SummaryChain.index(messages),
                ),
              ),
            ],
          );
      await container.read(chatProvider('c1').future);
      // The breakdown of the last prompt: a refused pin leaves it alone, where
      // a pin that is tried drops it and counts the prompt again.
      const breakdown = TokenBreakdown(
        sourceTokens: {},
        staticTotal: 100,
        fixedTotal: 100,
        historyBudget: 900,
        historyTokens: 10,
        totalTokens: 110,
        cutoffIndex: 0,
        trimmedHistory: [],
      );
      container.read(cachedTokenBreakdownProvider('c1').notifier).state =
          breakdown;

      await container.read(chatProvider('c1').notifier).pinHistoryAnchor(1);

      final stored = (await container.read(chatRepoProvider).getById('c1_0'))!;
      expect(stored.historyAnchorId, isNull);
      expect(stored.historyAnchorPinned, isFalse);
      expect(
        container.read(cachedTokenBreakdownProvider('c1')),
        same(breakdown),
      );
    },
  );
}
