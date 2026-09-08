import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_draft_planner.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

ChatMessage _message(int n) => ChatMessage(
  id: 'm$n',
  role: n.isOdd ? 'user' : 'assistant',
  content: 'Message $n',
);

void main() {
  test('keeps newest messages outside draft chunks', () {
    final plan = MemoryDraftPlanner.plan(
      book: const MemoryBook(id: 'book', sessionId: 's'),
      messages: List.generate(10, (i) => _message(i + 1)),
      interval: 3,
      lagMessages: 2,
      source: 'test',
      nowMillis: 1000,
    );

    expect(plan.eligibleMessageCount, 8);
    expect(plan.uncoveredMessageCount, 8);
    expect(plan.drafts, hasLength(2));
    expect(plan.drafts[0].messageIds, ['m1', 'm2', 'm3']);
    expect(plan.drafts[1].messageIds, ['m4', 'm5', 'm6']);
  });

  test('does not include already covered messages', () {
    final plan = MemoryDraftPlanner.plan(
      book: const MemoryBook(
        id: 'book',
        sessionId: 's',
        entries: [
          MemoryEntry(id: 'e1', messageIds: ['m1', 'm2']),
        ],
      ),
      messages: List.generate(6, (i) => _message(i + 1)),
      interval: 2,
      lagMessages: 0,
      source: 'test',
      nowMillis: 1000,
    );

    expect(plan.uncoveredMessageCount, 4);
    expect(plan.drafts, hasLength(2));
    expect(plan.drafts[0].messageIds, ['m3', 'm4']);
    expect(plan.drafts[1].messageIds, ['m5', 'm6']);
  });

  test('scan_chat (manual) entries still block coverage', () {
    // Manual entries (source:'scan_chat' or empty) continue to block —
    // they are the user-promoted curated facts that should not be re-scanned.
    final plan = MemoryDraftPlanner.plan(
      book: const MemoryBook(
        id: 'book',
        sessionId: 's',
        entries: [
          MemoryEntry(
            id: 'manual1',
            messageIds: ['m1', 'm2'],
            source: 'scan_chat',
            kind: 'curated',
          ),
        ],
      ),
      messages: List.generate(6, (i) => _message(i + 1)),
      interval: 2,
      lagMessages: 0,
      source: 'test',
      nowMillis: 1000,
    );

    expect(plan.uncoveredMessageCount, 4);
    expect(plan.drafts, hasLength(2));
    expect(plan.drafts[0].messageIds, ['m3', 'm4']);
  });

  test('studio_ledger entries do not block manual scan coverage', () {
    // Studio Ledger entries (source:'studio_ledger') are per-turn durable
    // facts — a different memory layer. They must NOT suppress manual scan.
    final plan = MemoryDraftPlanner.plan(
      book: const MemoryBook(
        id: 'book',
        sessionId: 's',
        entries: [
          MemoryEntry(
            id: 'sl1',
            messageIds: ['m1'],
            source: 'studio_ledger',
            kind: 'studio_ledger',
          ),
          MemoryEntry(
            id: 'sl2',
            messageIds: ['m3'],
            source: 'studio_ledger',
            kind: 'studio_ledger',
          ),
        ],
      ),
      messages: List.generate(6, (i) => _message(i + 1)),
      interval: 2,
      lagMessages: 0,
      source: 'test',
      nowMillis: 1000,
    );

    // Studio Ledger entries don't block → all 6 messages uncovered.
    expect(plan.uncoveredMessageCount, 6);
    expect(plan.drafts, hasLength(3));
    // Segments built by stable index: 1-2, 3-4, 5-6
    expect(plan.drafts[0].title, '1-2');
    expect(plan.drafts[0].messageIds, ['m1', 'm2']);
    expect(plan.drafts[1].title, '3-4');
    expect(plan.drafts[1].messageIds, ['m3', 'm4']);
    expect(plan.drafts[2].title, '5-6');
    expect(plan.drafts[2].messageIds, ['m5', 'm6']);
  });

  test('fixed blocks: covered messages do not stretch segment range', () {
    // With fixed blocks of 4, messages m2 and m6 are covered but
    // stay in their block. Block 1 (m1-m4) → uncovered: m1,m3,m4.
    // Block 2 (m5-m8) → uncovered: m5,m7,m8.
    final plan = MemoryDraftPlanner.plan(
      book: const MemoryBook(
        id: 'book',
        sessionId: 's',
        entries: [
          MemoryEntry(
            id: 'manual1',
            messageIds: ['m2'],
            source: 'scan_chat',
            kind: 'curated',
          ),
          MemoryEntry(
            id: 'manual2',
            messageIds: ['m6'],
            source: 'scan_chat',
            kind: 'curated',
          ),
        ],
      ),
      messages: List.generate(8, (i) => _message(i + 1)),
      interval: 4,
      lagMessages: 0,
      source: 'test',
      nowMillis: 1000,
    );

    expect(plan.uncoveredMessageCount, 6);
    expect(plan.drafts, hasLength(2));
    // Block 1: m1-m4, uncovered m1,m3,m4
    expect(plan.drafts[0].title, '1-4');
    expect(plan.drafts[0].messageIds, ['m1', 'm3', 'm4']);
    // Block 2: m5-m8, uncovered m5,m7,m8
    expect(plan.drafts[1].title, '5-8');
    expect(plan.drafts[1].messageIds, ['m5', 'm7', 'm8']);
  });
}
