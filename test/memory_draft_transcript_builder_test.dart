import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_draft_transcript_builder.dart';
import 'package:glaze_flutter/core/llm/regex_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';

void main() {
  test('applies opted-in draft regexes without mutating source messages', () {
    const source = ChatMessage(
      id: 'user',
      role: 'user',
      content: 'hello\u2800world',
    );
    const script = PresetRegex(
      id: 'spaces',
      name: 'Restore spaces',
      regex: r'/\u2800/g',
      replacement: ' ',
      placement: [1],
      ephemerality: [1],
      memoryBookRetrieval: true,
    );

    final transcript = MemoryDraftTranscriptBuilder.build(
      messages: const [source],
      scripts: const [script],
      context: const RegexApplyContext(),
    );

    expect(transcript, 'user: hello world');
    expect(source.content, 'hello\u2800world');
  });

  test('applies preset, global, and Studio scripts in supplied order', () {
    const messages = [ChatMessage(id: 'user', role: 'user', content: 'A')];
    PresetRegex append(String id, String from, String to) => PresetRegex(
      id: id,
      name: id,
      regex: '/$from/g',
      replacement: to,
      placement: const [1],
      memoryBookRetrieval: true,
    );

    final transcript = MemoryDraftTranscriptBuilder.build(
      messages: messages,
      scripts: [
        append('preset', 'A', 'B'),
        append('global', 'B', 'C'),
        append('studio', 'C', 'D'),
      ],
      context: const RegexApplyContext(),
    );

    expect(transcript, 'user: D');
  });

  test('ignores scripts without draft-generation opt-in', () {
    final transcript = MemoryDraftTranscriptBuilder.build(
      messages: const [
        ChatMessage(id: 'user', role: 'user', content: 'original'),
      ],
      scripts: const [
        PresetRegex(
          id: 'normal',
          name: 'Normal prompt regex',
          regex: '/original/g',
          replacement: 'changed',
          placement: [1],
        ),
      ],
      context: const RegexApplyContext(),
    );

    expect(transcript, 'user: original');
  });

  test('exposes the exact first-to-last Ledger range as metadata', () {
    const messages = [
      ChatMessage(id: 'u1', role: 'user', content: 'Start'),
      ChatMessage(
        id: 'empty',
        role: 'assistant',
        content: ' ',
        time: '15.09.2026 · RP_Day 0 · 20:55',
      ),
      ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'Middle',
        time: '15.09.2026 · RP_Day 0 · 21:00',
      ),
      ChatMessage(
        id: 'a2',
        role: 'assistant',
        content: 'End',
        time: '15.09.2026 · RP_Day 0 · 21:30',
      ),
    ];

    expect(
      MemoryDraftTranscriptBuilder.ledgerRange(messages),
      '15.09.2026 · RP_Day 0 · 21:00 -> '
      '15.09.2026 · RP_Day 0 · 21:30',
    );
    final transcript = MemoryDraftTranscriptBuilder.build(
      messages: messages,
      scripts: const [],
      context: const RegexApplyContext(),
    );
    expect(
      transcript,
      startsWith(
        'AUTHORITATIVE_LEDGER_RANGE: '
        '15.09.2026 · RP_Day 0 · 21:00 -> '
        '15.09.2026 · RP_Day 0 · 21:30',
      ),
    );
  });
}
