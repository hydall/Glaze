import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/lorebook_scanner.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/prompt/lorebook_context_resolver.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

void main() {
  const character = Character(id: 'char', name: 'Mira');
  const macroContext = MacroContext(
    charName: 'Mira',
    charId: 'char',
    sessionId: '',
  );
  const resolver = LorebookContextResolver();

  test('merges and classifies keyword and normalized vector entries', () {
    const canonicalVectorContent = 'Canonical vector fact about {{char}}';
    final result = resolver.resolve(
      history: const [],
      character: character,
      sessionId: 'session',
      lorebooks: const [
        Lorebook(
          id: 'book',
          name: 'World',
          entries: [
            LorebookEntry(
              id: 'vector',
              comment: 'Vector fact',
              content: canonicalVectorContent,
              position: 'worldInfoAfter',
            ),
          ],
        ),
      ],
      settings: const LorebookGlobalSettings(maxInjectedEntries: 4),
      activations: const LorebookActivations(),
      vectorEntries: const [
        LorebookEntry(
          id: 'vector',
          comment: 'Vector fact',
          content: 'stale indexed content',
          position: 'worldInfoAfter',
          lorebookId: 'book',
          lorebookName: 'World',
        ),
      ],
      macroContext: macroContext,
      preScannedEntries: const [
        ScannedEntry(
          id: 'keyword',
          comment: 'Keyword fact',
          content: 'Keyword fact about {{char}}',
          position: 'lorebooksMacro',
          order: 0,
          lorebookName: 'World',
          lorebookId: 'book',
          constant: false,
        ),
      ],
    );

    expect(result.mergedEntries.map((entry) => entry.id), [
      'keyword',
      'vector',
    ]);
    expect(result.loreMacroBuffer, ['Keyword fact about Mira']);
    expect(result.loreAfter.single.content, 'Canonical vector fact about Mira');
    expect(result.triggeredEntries.map((entry) => entry.source), [
      'keyword',
      'vector',
    ]);
    expect(result.triggeredEntries.last.lorebookId, 'book');
    expect(result.vectorLoreTokens, estimateTokens(canonicalVectorContent));
    expect(
      result.vectorEntries['book_vector']?.content,
      canonicalVectorContent,
    );
  });

  test('triggered list reflects caps, book limits and entry state', () {
    final result = resolver.resolve(
      history: const [
        ChatMessage(
          id: 'user',
          role: 'user',
          content: 'alpha bravo charlie delta echo',
        ),
      ],
      character: character,
      sessionId: 'session',
      lorebooks: const [
        Lorebook(
          id: 'bookA',
          name: 'Book A',
          settings: LorebookSettings(maxInjectedEntries: 1),
          entries: [
            LorebookEntry(
              id: 'AC',
              comment: 'Constant',
              content: 'FACT_AC',
              position: 'lorebooksMacro',
              constant: true,
              order: 0,
            ),
            LorebookEntry(
              id: 'A1',
              comment: 'First',
              keys: ['alpha'],
              content: 'FACT_A1',
              position: 'lorebooksMacro',
              order: 1,
            ),
            LorebookEntry(
              id: 'A2',
              comment: 'Second',
              keys: ['bravo'],
              content: 'FACT_A2',
              position: 'lorebooksMacro',
              order: 2,
            ),
          ],
        ),
        Lorebook(
          id: 'bookB',
          name: 'Book B',
          entries: [
            LorebookEntry(
              id: 'B1',
              comment: 'Third',
              keys: ['charlie'],
              content: 'FACT_B1',
              position: 'lorebooksMacro',
              order: 3,
            ),
            LorebookEntry(
              id: 'B2',
              comment: 'Disabled',
              keys: ['charlie'],
              content: 'FACT_B2',
              position: 'lorebooksMacro',
              order: 4,
              enabled: false,
            ),
          ],
        ),
        Lorebook(
          id: 'bookC',
          name: 'Book C',
          entries: [
            LorebookEntry(
              id: 'C1',
              comment: 'Cooling',
              keys: ['delta'],
              content: 'FACT_C1',
              position: 'lorebooksMacro',
              order: 5,
              cooldown: 1,
            ),
            LorebookEntry(
              id: 'C2',
              comment: 'Sticky',
              keys: ['echo'],
              content: 'FACT_C2',
              position: 'lorebooksMacro',
              order: 6,
              sticky: 1,
            ),
          ],
        ),
      ],
      settings: const LorebookGlobalSettings(maxInjectedEntries: 3),
      activations: const LorebookActivations(),
      vectorEntries: const [],
      macroContext: macroContext,
    );

    final ids = result.triggeredEntries.map((entry) => entry.id).toList();
    // AC: constant bypasses every cap. A1 survives book A's per-book limit of
    // 1, B1 survives the global keyword budget; A2 (book limit), C2 (global
    // budget) fired but did not fit. B2 is disabled, C1 is on cooldown.
    expect(ids, ['AC', 'A1', 'B1']);
    expect(result.triggeredEntries.first.source, 'constant');
    expect(ids, isNot(contains('A2')));
    expect(ids, isNot(contains('B2')));
    expect(ids, isNot(contains('C1')));
    expect(ids, isNot(contains('C2')));
  });

  test('vector entries beyond vectorTopK are not reported as triggered', () {
    final result = resolver.resolve(
      history: const [
        ChatMessage(id: 'user', role: 'user', content: 'alpha'),
      ],
      character: character,
      sessionId: 'session',
      lorebooks: const [
        Lorebook(
          id: 'bookK',
          name: 'Book K',
          entries: [
            LorebookEntry(
              id: 'K1',
              comment: 'Keyword',
              keys: ['alpha'],
              content: 'FACT_K1',
              position: 'lorebooksMacro',
              order: 0,
            ),
          ],
        ),
        Lorebook(
          id: 'bookV',
          name: 'Book V',
          entries: const [],
        ),
      ],
      settings: const LorebookGlobalSettings(
        maxInjectedEntries: 10,
        vectorTopK: 1,
      ),
      activations: const LorebookActivations(),
      vectorEntries: const [
        LorebookEntry(
          id: 'V1',
          comment: 'Vector one',
          content: 'FACT_V1',
          position: 'lorebooksMacro',
          order: 0,
          lorebookId: 'bookV',
          lorebookName: 'Book V',
        ),
        LorebookEntry(
          id: 'V2',
          comment: 'Vector two',
          content: 'FACT_V2',
          position: 'lorebooksMacro',
          order: 1,
          lorebookId: 'bookV',
          lorebookName: 'Book V',
        ),
      ],
      macroContext: macroContext,
    );

    final ids = result.triggeredEntries.map((entry) => entry.id).toList();
    expect(ids, ['K1', 'V1']);
    expect(result.triggeredEntries.last.source, 'vector');
    expect(ids, isNot(contains('V2')));
  });

  test('scans only visible history and returns semantic lore slots', () {
    const lorebook = Lorebook(
      id: 'book',
      name: 'World',
      entries: [
        LorebookEntry(
          id: 'keyword',
          comment: 'Visible keyword',
          keys: ['anchor'],
          content: 'Visible fact',
          position: 'worldInfoBefore',
        ),
      ],
    );

    LorebookContextResolution resolve(List<ChatMessage> history) =>
        resolver.resolve(
          history: history,
          character: character,
          sessionId: 'session',
          lorebooks: const [lorebook],
          settings: const LorebookGlobalSettings(),
          activations: const LorebookActivations(),
          vectorEntries: const [],
          macroContext: macroContext,
        );

    final hiddenOnly = resolve(const [
      ChatMessage(
        id: 'hidden',
        role: 'user',
        content: 'anchor',
        isHidden: true,
      ),
      ChatMessage(id: 'visible', role: 'user', content: 'nothing relevant'),
    ]);
    expect(hiddenOnly.mergedEntries, isEmpty);

    final visible = resolve(const [
      ChatMessage(id: 'visible', role: 'user', content: 'anchor'),
    ]);
    expect(visible.loreBefore.single.content, 'Visible fact');
    expect(visible.triggeredEntries.single.source, 'keyword');
  });
}
