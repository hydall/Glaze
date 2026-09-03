import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/lorebook_coverage.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

/// The coverage preview must answer with the same rules the real scan uses
/// (`lorebook_scanner.dart`), or the Prompt Inspector and the context card
/// under the chat header describe a prompt the model never receives.
void main() {
  CoverageResult run(
    List<Lorebook> books, {
    String message = 'we ride to the castle at dawn',
    LorebookGlobalSettings settings = const LorebookGlobalSettings(),
  }) => computeLorebookCoverage(
    history: [ChatMessage(id: 'm1', role: 'user', content: message)],
    char: null,
    textToScan: message,
    chatId: null,
    lorebooks: books,
    globalSettings: settings,
    activations: const LorebookActivations(),
  );

  CoverageEntry entryNamed(CoverageResult result, String id) =>
      result.entries.firstWhere((e) => e.id == id);

  test('recursion activates an entry only its predecessor could reach', () {
    final result = run(const [
      Lorebook(
        id: 'b',
        name: 'Book',
        // Ordered so the dragon entry is judged BEFORE the castle entry feeds
        // its content back in — otherwise it would match on the first pass and
        // prove nothing about recursion.
        entries: [
          LorebookEntry(id: 'dragon', keys: ['dragon'], content: 'Scaly.'),
          LorebookEntry(
            id: 'castle',
            keys: ['castle'],
            content: 'The keep is guarded by a dragon.',
          ),
        ],
      ),
    ]);

    expect(entryNamed(result, 'castle').activated, isTrue);
    final dragon = entryNamed(result, 'dragon');
    expect(dragon.activated, isTrue, reason: 'reached through recursion');
    expect(dragon.recursionPass, 2);
    expect(dragon.viaRecursion, isTrue);
  });

  test('preventRecursion stops the chain at that entry', () {
    final result = run(const [
      Lorebook(
        id: 'b',
        name: 'Book',
        entries: [
          LorebookEntry(id: 'dragon', keys: ['dragon'], content: 'Scaly.'),
          LorebookEntry(
            id: 'castle',
            keys: ['castle'],
            content: 'The keep is guarded by a dragon.',
            preventRecursion: true,
          ),
        ],
      ),
    ]);

    expect(entryNamed(result, 'dragon').activated, isFalse);
  });

  test('a per-book cap cuts entries before the global budget does', () {
    final result = run(const [
      Lorebook(
        id: 'b',
        name: 'Book',
        settings: LorebookSettings(maxInjectedEntries: 1),
        entries: [
          LorebookEntry(id: 'a', keys: ['castle'], order: 1, content: 'A'),
          LorebookEntry(id: 'b', keys: ['castle'], order: 2, content: 'B'),
        ],
      ),
    ]);

    expect(entryNamed(result, 'a').cutOff, isNull);
    expect(entryNamed(result, 'b').cutOff, CoverageCutOff.bookLimit);
    expect(result.cutOffCount, 1);
    expect(result.injectedCount, 1);
  });

  test('the global entry cap reports a budget cut-off', () {
    final result = run(
      const [
        Lorebook(
          id: 'b',
          name: 'Book',
          entries: [
            LorebookEntry(id: 'a', keys: ['castle'], order: 1, content: 'A'),
            LorebookEntry(id: 'b', keys: ['castle'], order: 2, content: 'B'),
          ],
        ),
      ],
      settings: const LorebookGlobalSettings(maxInjectedEntries: 1),
    );

    expect(entryNamed(result, 'a').cutOff, isNull);
    expect(entryNamed(result, 'b').cutOff, CoverageCutOff.budget);
  });

  test('constant entries bypass the entry cap', () {
    final result = run(
      const [
        Lorebook(
          id: 'b',
          name: 'Book',
          entries: [
            LorebookEntry(id: 'c1', constant: true, content: 'always'),
            LorebookEntry(id: 'c2', constant: true, content: 'always too'),
            LorebookEntry(id: 'k', keys: ['castle'], content: 'K'),
          ],
        ),
      ],
      settings: const LorebookGlobalSettings(maxInjectedEntries: 1),
    );

    expect(entryNamed(result, 'c1').cutOff, isNull);
    expect(entryNamed(result, 'c2').cutOff, isNull);
    expect(entryNamed(result, 'k').cutOff, CoverageCutOff.budget);
  });

  test('a cooling entry stays out even though its key is in the message', () {
    final result = run(const [
      Lorebook(
        id: 'b',
        name: 'Book',
        entries: [
          LorebookEntry(
            id: 'cool',
            keys: ['castle'],
            cooldown: 2,
            content: 'C',
          ),
        ],
      ),
    ]);

    final entry = entryNamed(result, 'cool');
    expect(entry.activated, isFalse);
    expect(entry.onCooldown, isTrue);
  });

  test('a hidden message cannot trigger an entry', () {
    final result = computeLorebookCoverage(
      history: const [
        ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'the castle burns',
          isHidden: true,
        ),
      ],
      char: null,
      textToScan: '',
      chatId: null,
      lorebooks: const [
        Lorebook(
          id: 'b',
          name: 'Book',
          entries: [LorebookEntry(id: 'k', keys: ['castle'], content: 'K')],
        ),
      ],
      globalSettings: const LorebookGlobalSettings(),
      activations: const LorebookActivations(),
    );

    expect(entryNamed(result, 'k').activated, isFalse);
  });
}
