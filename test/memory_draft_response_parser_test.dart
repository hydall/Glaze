import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_draft_response_parser.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

void main() {
  const draft = MemoryDraft(id: 'draft');

  test('parses roleplay-language paragraph keys and preserves casing', () {
    final result = MemoryDraftResponseParser.parse(
      draft,
      '''{"paragraphs":[{"text":"Алиса спрятала Серебряный Ключ.","keys":["Серебряный Ключ","часовня"]},{"text":"Борис запер хранилище.","keys":["хранилище","Часовня"]}]}''',
      nowMillis: 10,
    );

    expect(result.content, contains('\n\n'));
    expect(result.keys, ['Серебряный Ключ', 'часовня', 'хранилище']);
    expect(result.keyParagraphs['часовня'], [0, 1]);
    expect(result.generatedAt, 10);
  });

  test('supports fenced JSON and legacy Memory/Keys responses', () {
    final structured = MemoryDraftResponseParser.parse(
      draft,
      '```json\n{"paragraphs":[{"text":"記憶。","keys":["鍵"]}]}\n```',
    );
    final legacy = MemoryDraftResponseParser.parse(
      draft,
      'Memory: Старый формат.\nKeys: Ключ, Место',
    );

    expect(structured.keyParagraphs, {
      '鍵': [0],
    });
    expect(legacy.content, 'Старый формат.');
    expect(legacy.keys, ['Ключ', 'Место']);
    expect(legacy.keyParagraphs, isEmpty);
  });

  test('maps keys across blank-line paragraphs inside one JSON item', () {
    final result = MemoryDraftResponseParser.parse(
      draft,
      '{"paragraphs":['
      '{"text":"First.\\n\\nSecond.","keys":["pair"]},'
      '{"text":"Third.","keys":["third"]}'
      ']}',
      nowMillis: 1,
    );

    expect(result.content, 'First.\n\nSecond.\n\nThird.');
    expect(result.keyParagraphs, {
      'pair': [0, 1],
      'third': [2],
    });
  });

  test('stores the authoritative Ledger range without shifting key scopes', () {
    final result = MemoryDraftResponseParser.parse(
      draft,
      '{"paragraphs":[{"text":"Scene beat.","keys":["place"]}]}',
      ledgerRange:
          '15.09.2026 · RP_Day 0 · 21:00 -> '
          '15.09.2026 · RP_Day 0 · 21:30',
      nowMillis: 1,
    );

    expect(result.content, 'Scene beat.');
    expect(
      result.ledgerRange,
      '15.09.2026 · RP_Day 0 · 21:00 -> '
      '15.09.2026 · RP_Day 0 · 21:30',
    );
    expect(result.keyParagraphs, {
      'place': [0],
    });
  });
}
