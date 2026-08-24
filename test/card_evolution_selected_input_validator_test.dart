import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_proposal_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_selected_input_validator.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

void main() {
  String canonicalJson(Object? value) {
    Object? canonical(Object? item) {
      if (item is Map) {
        final keys = item.keys.map((key) => key.toString()).toList()..sort();
        return {for (final key in keys) key: canonical(item[key])};
      }
      if (item is Iterable) return item.map(canonical).toList();
      return item;
    }

    return jsonEncode(canonical(value));
  }

  String selectedInput({
    String content = 'accepted',
    int swipeId = 0,
    int agentSwipeId = 0,
  }) {
    final history = [
      {
        'messageId': 'm1',
        'role': 'assistant',
        'swipeId': swipeId,
        'agentSwipeId': agentSwipeId,
        'content': content,
        'contentHash': computeHash(content),
      },
    ];
    return canonicalJson({
      'contractVersion': 8,
      'chatHistoryHash': computeHash(canonicalJson(history)),
      'effectiveCanonIdentity': 'canon',
      'chatHistory': history,
    });
  }

  test('strict evidence matches only the active ordered variation', () {
    final evidence = CardEvolutionSelectedChatEvidence.tryParse(
      selectedInput(content: 'blue', swipeId: 1, agentSwipeId: 1),
    );
    expect(evidence, isNotNull);
    final current = jsonEncode([
      const ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'blue',
        swipes: ['green zero', 'green one'],
        swipeId: 1,
        agentSwipes: [
          AgentSwipe(content: 'other'),
          AgentSwipe(content: 'blue'),
        ],
        agentSwipeId: 1,
      ).toJson(),
    ]);
    expect(evidence!.matchesMessagesJson(current), isTrue);

    final switched = jsonEncode([
      const ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'other',
        swipes: ['green zero', 'green one'],
        swipeId: 1,
        agentSwipes: [
          AgentSwipe(content: 'other'),
          AgentSwipe(content: 'blue'),
        ],
      ).toJson(),
    ]);
    expect(evidence.matchesMessagesJson(switched), isFalse);
  });

  test('strict evidence rejects content and envelope hash tampering', () {
    final contentTampered = jsonDecode(selectedInput()) as Map<String, dynamic>;
    (contentTampered['chatHistory'] as List).single['content'] = 'changed';
    expect(
      CardEvolutionSelectedChatEvidence.tryParse(jsonEncode(contentTampered)),
      isNull,
    );

    final envelopeTampered = jsonDecode(selectedInput()) as Map<String, dynamic>
      ..['chatHistoryHash'] = 'wrong';
    expect(
      CardEvolutionSelectedChatEvidence.tryParse(jsonEncode(envelopeTampered)),
      isNull,
    );
  });

  test('message mutation cancels only linked pending automatic job', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final selected = selectedInput();
    await db.batch((batch) {
      batch.insertAll(db.rewriteJobs, [
        RewriteJobsCompanion.insert(
          id: 'target',
          chatSessionId: 's',
          characterId: 'c',
          version: const Value(3),
        ),
        RewriteJobsCompanion.insert(
          id: 'manual',
          chatSessionId: 's',
          characterId: 'manual-character',
        ),
      ]);
      batch.insert(
        db.cardEvolutionProposalRuns,
        CardEvolutionProposalRunsCompanion.insert(
          id: 'proposal',
          claimId: 'claim',
          sessionId: 's',
          characterId: 'c',
          rewriteJobId: 'target',
          chatHistoryHash: computeHash(
            canonicalJson((jsonDecode(selected) as Map)['chatHistory']),
          ),
          effectiveCanonIdentity: 'canon',
          selectedInputJson: selected,
          inputHash: computeHash(selected),
          modelOutput: '{}',
          modelOutputHash: computeHash('{}'),
          operationSnapshotJson: '[]',
          createdAt: 1,
        ),
      );
    });

    final cancelled = await CardEvolutionProposalRunRepo(db)
        .cancelPendingForMessageMutationInTransaction(
          sessionId: 's',
          messageIds: {'m1'},
          now: 10,
        );

    expect(cancelled, ['target']);
    final jobs = {
      for (final row in await db.select(db.rewriteJobs).get()) row.id: row,
    };
    expect(jobs['target']!.status, 'cancelled');
    expect(jobs['target']!.statusReason, 'chatEvidenceChanged');
    expect(jobs['target']!.version, 4);
    expect(jobs['manual']!.status, 'pending');
    expect(await db.select(db.cardEvolutionProposalRuns).get(), hasLength(1));
  });
}
