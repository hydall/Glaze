import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/llm/lorebook_scanner.dart';

ChatMessage _message(String id, String content) =>
    ChatMessage(id: id, role: 'user', content: content);

LorebookEntry _entry(String id, {required List<String> keys, String? content}) =>
    LorebookEntry(
      id: id,
      keys: keys,
      content: content ?? 'content of $id',
      order: 0,
    );

Lorebook _book(List<LorebookEntry> entries, {LorebookSettings? settings}) =>
    Lorebook(
      id: 'lb1',
      name: 'Book',
      enabled: true,
      activationScope: 'global',
      entries: entries,
      settings: settings,
    );

List<ScannedEntry> _scan({
  required List<ChatMessage> history,
  required List<Lorebook> lorebooks,
  String textToScan = 'the current message',
  LorebookGlobalSettings settings = const LorebookGlobalSettings(),
}) => scanLorebooks(
  history: history,
  char: null,
  textToScan: textToScan,
  chatId: null,
  lorebooks: lorebooks,
  globalSettings: settings,
  activations: const LorebookActivations(),
);

void main() {
  setUp(() => lorebookScanSourceBuilds = 0);

  // Every candidate entry scans the same text, and that text was rebuilt for
  // each of them — a fresh lowercase pass over the recursion buffer plus a
  // fresh concatenation with the history slice. So the work was proportional
  // to entries x characters when it only ever needed to be characters, which
  // is what "PromptWorker getting overwhelmed with too many lorebooks" costs
  // and what a SillyTavern import, arriving with a chat far larger than
  // anything Glaze creates itself, multiplies.
  group('the text to scan is built once per depth', () {
    test('two hundred entries build it once, not two hundred times', () {
      final history = [
        for (var i = 0; i < 200; i++) _message('m$i', 'message number $i'),
      ];
      final entries = [
        for (var i = 0; i < 200; i++) _entry('e$i', keys: ['nothing$i']),
      ];

      _scan(history: history, lorebooks: [_book(entries)]);

      expect(lorebookScanSourceBuilds, 1);
    });

    test('entries at different depths get one build each', () {
      // The cache is keyed by what the text actually depends on, so two scan
      // depths cost two builds however many entries ask for them.
      final entries = [
        for (var i = 0; i < 50; i++)
          _entry('shallow$i', keys: ['none']).copyWith(scanDepth: 2),
        for (var i = 0; i < 50; i++)
          _entry('deep$i', keys: ['none']).copyWith(scanDepth: 40),
      ];

      _scan(
        history: [for (var i = 0; i < 60; i++) _message('m$i', 'text $i')],
        lorebooks: [_book(entries)],
      );

      expect(lorebookScanSourceBuilds, 2);
    });

    test('a match rebuilds it, because recursion changes what is scanned', () {
      // A matched entry appends its content to the buffer and every later
      // entry must see it. One rebuild per append is the price of that, and it
      // is the reason the cache cannot simply live for the whole scan.
      final entries = [
        _entry('a', keys: ['dragon'], content: 'the dragon guards a hoard'),
        _entry('b', keys: ['hoard']),
      ];

      final matched = _scan(
        history: [_message('m1', 'we saw a dragon')],
        lorebooks: [_book(entries)],
        settings: const LorebookGlobalSettings(recursiveScan: true),
      );

      expect(matched.map((e) => e.id), containsAll(['a', 'b']));
      expect(lorebookScanSourceBuilds, greaterThan(1));
    });
  });

  group('what matches is unchanged', () {
    test('a key in the recent history still triggers its entry', () {
      final scanned = _scan(
        history: [_message('m1', 'Alicia rules the kingdom')],
        lorebooks: [
          _book([
            _entry('queen', keys: ['Alicia']),
            _entry('absent', keys: ['Bartholomew']),
          ]),
        ],
      );

      expect(scanned.map((e) => e.id), ['queen']);
    });

    test('a key in the current message still triggers its entry', () {
      final scanned = _scan(
        history: [_message('m1', 'nothing relevant')],
        textToScan: 'tell me about the kingdom',
        lorebooks: [
          _book([_entry('realm', keys: ['kingdom'])]),
        ],
      );

      expect(scanned.map((e) => e.id), ['realm']);
    });

    test('case sensitivity is still honoured per entry', () {
      final scanned = _scan(
        history: [_message('m1', 'alicia rules')],
        lorebooks: [
          _book([
            _entry('loose', keys: ['Alicia']),
            _entry('strict', keys: ['Alicia']).copyWith(caseSensitive: true),
          ]),
        ],
      );

      // The loose entry folds case and matches; the strict one does not. Both
      // read the same cached text, which is the thing that had to keep working
      // when one build started serving both.
      expect(scanned.map((e) => e.id), ['loose']);
    });

    test('scan depth still bounds how far back a key is looked for', () {
      final history = [
        _message('old', 'Alicia was here'),
        for (var i = 0; i < 10; i++) _message('m$i', 'later message $i'),
      ];

      final shallow = _scan(
        history: history,
        lorebooks: [
          _book([_entry('queen', keys: ['Alicia']).copyWith(scanDepth: 2)]),
        ],
      );
      final deep = _scan(
        history: history,
        lorebooks: [
          _book([_entry('queen', keys: ['Alicia']).copyWith(scanDepth: 40)]),
        ],
      );

      expect(shallow, isEmpty);
      expect(deep.map((e) => e.id), ['queen']);
    });
  });
}
