import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_studio_service.dart';

void main() {
  group('matchesActivationKeywords', () {
    test('returns true when keywords is empty (always activate)', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const [],
          ['hello world'],
          5,
        ),
        isTrue,
      );
    });

    test('returns false when history is empty but keywords non-empty', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather'],
          const [],
          5,
        ),
        isFalse,
      );
    });

    test('returns true when keyword found in last message', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather'],
          ['hi', 'how are you', 'the weather is nice today'],
          5,
        ),
        isTrue,
      );
    });

    test('returns true when keyword found in earlier message within window', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather'],
          ['the weather is nice', 'how are you', 'good thanks'],
          5,
        ),
        isTrue,
      );
    });

    test('returns false when keyword not in any message', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather'],
          ['hi', 'how are you', 'good thanks'],
          5,
        ),
        isFalse,
      );
    });

    test('returns false when keyword is outside scan window', () {
      // 5 messages, scanDepth=2 → only last 2 scanned. Keyword 'weather'
      // is in message 0, outside the window.
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather'],
          ['the weather is nice', 'how are you', 'good thanks', 'see you', 'bye'],
          2,
        ),
        isFalse,
      );
    });

    test('returns true when keyword is in the last message of scan window', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather'],
          ['the weather is nice', 'how are you', 'good thanks', 'see you', 'bye'],
          5,
        ),
        isTrue,
      );
    });

    test('case-insensitive match', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['WEATHER'],
          ['The Weather Is Nice'],
          5,
        ),
        isTrue,
      );
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['Weather'],
          ['the WEATHER is nice'],
          5,
        ),
        isTrue,
      );
    });

    test('multiple keywords — any match activates', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather', 'combat', 'magic'],
          ['the magic sword glowed'],
          5,
        ),
        isTrue,
      );
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather', 'combat', 'magic'],
          ['nothing relevant here'],
          5,
        ),
        isFalse,
      );
    });

    test('scanDepth 0 scans entire history', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather'],
          ['the weather is nice', 'a', 'b', 'c', 'd', 'e', 'f', 'g'],
          0,
        ),
        isTrue,
      );
    });

    test('negative scanDepth scans entire history', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather'],
          ['the weather is nice', 'a', 'b', 'c'],
          -1,
        ),
        isTrue,
      );
    });

    test('scanDepth larger than history scans entire history', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weather'],
          ['the weather is nice', 'a'],
          100,
        ),
        isTrue,
      );
    });

    test('whitespace-only keywords are treated as empty (always activate)', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['   ', '\n\t', ''],
          ['nothing relevant'],
          5,
        ),
        isTrue,
      );
    });

    test('keywords are trimmed before matching', () {
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['  weather  '],
          ['the weather is nice'],
          5,
        ),
        isTrue,
      );
    });

    test('substring match — not whole-word', () {
      // 'weath' matches 'weather' via substring contains.
      expect(
        MemoryStudioService.matchesActivationKeywords(
          const ['weath'],
          ['the weather is nice'],
          5,
        ),
        isTrue,
      );
    });
  });
}
