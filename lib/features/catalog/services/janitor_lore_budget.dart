import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/llm/tokenizer.dart';
import '../../../core/llm/tokenizers/tokenizer_codec.dart';
import '../../../core/llm/tokenizers/tokenizer_store.dart';
import '../../../core/utils/platform_paths.dart';
import 'janitor_separate.dart';

/// Most lorebook text JanitorAI injects into one assembled prompt, in tokens.
///
/// The cap is applied server-side while `/generateAlpha` assembles the prompt:
/// once the triggered entries add up to it, the rest are silently left out. A
/// trigger message that fires more than that loses entries without any sign
/// in the response, so the capture measures what came back and, when it is at
/// the cap, re-fires the trigger in smaller pieces (see [splitTrigger]).
const int janitorLoreTokenCap = 120000;

/// How close to [janitorLoreTokenCap] a capture has to be to count as cut off.
/// The server stops at the first entry that no longer fits, so a capped prompt
/// lands somewhere below the cap by up to one entry; and the measure counts a
/// little text around the entries that is not lore. A false positive only
/// costs one more pass, a miss loses entries — hence the generous margin.
const int janitorLoreSaturationMargin = 8000;

/// Counts the lorebook text in captured `generateAlpha` payloads the way
/// JanitorAI counts it.
///
/// JanitorAI's web client counts tokens with `gpt-tokenizer` on `cl100k_base`
/// (its `gp-tokenizer-*.js` chunk); Glaze's own BPE on the `cl100k` vocabulary
/// matches it token for token. The vocabulary is the one the tokenizer
/// settings already download, held in a private instance so the extraction
/// never switches the tokenizer the active connection counts with.
class JanitorLoreBudget {
  JanitorLoreBudget(this._count, {this.exact = true});

  final int Function(String text) _count;

  /// False when the vocabulary could not be loaded and [count] is a
  /// deliberately high character estimate instead.
  final bool exact;

  static JanitorLoreBudget? _loaded;

  /// The `cl100k` budget, downloading the vocabulary on first use. Never
  /// throws: without the vocabulary it falls back to an estimate that errs
  /// towards splitting (an extra pass is cheap, a lost entry is not).
  static Future<JanitorLoreBudget> load() async {
    final loaded = _loaded;
    if (loaded != null) return loaded;
    try {
      final store = TokenizerStore(dataDir: await getAppDataDir());
      await store.ensureCached(TokenizerKind.cl100k);
      final bytes = await File(
        tokenizerCachePath(store.dataDir, TokenizerKind.cl100k),
      ).readAsBytes();
      final tokenizer = decodeTokenizerCache(bytes);
      if (tokenizer != null) {
        return _loaded = JanitorLoreBudget(tokenizer.count);
      }
      debugPrint('[janitor-lore-budget] cl100k cache unreadable');
    } catch (e) {
      debugPrint('[janitor-lore-budget] cl100k unavailable: $e');
    }
    // Not cached: the next extraction tries the download again.
    return JanitorLoreBudget((t) => (t.length / 3).ceil(), exact: false);
  }

  int count(String text) => text.isEmpty ? 0 : _count(text);

  /// Tokens of lorebook text JanitorAI injected into [payload].
  ///
  /// Most of it sits outside the card's wrapper blocks, where [separate] looks
  /// for it. Entries placed into a field (personality, scenario, example
  /// dialogue) land inside a wrapper instead; with the [probe] snapshot their
  /// share is how much the wrappers grew between the two sends.
  int loreTokens(Map<String, dynamic> payload, {Map<String, dynamic>? probe}) {
    final split = stripWrappers(getSystemContent(payload));
    var lore = count(split.out);
    if (probe != null) {
      final grown =
          _wrapperTokens(split.removed) -
          _wrapperTokens(stripWrappers(getSystemContent(probe)).removed);
      if (grown > 0) lore += grown;
    }
    return lore;
  }

  /// Whether [payload]'s lore reached the cap, so some fired entries may have
  /// been left out of it.
  bool isSaturated(
    Map<String, dynamic> payload, {
    Map<String, dynamic>? probe,
  }) =>
      loreTokens(payload, probe: probe) >=
      janitorLoreTokenCap - janitorLoreSaturationMargin;

  int _wrapperTokens(List<RemovedBlock> blocks) =>
      blocks.fold(0, (sum, b) => sum + count(b.text));
}

/// Where [splitTrigger] may cut, coarsest first, and what rejoins the pieces.
final _triggerBoundaries = <(RegExp, String)>[
  (RegExp(r'\n\s*\n'), '\n\n'),
  (RegExp(r'\n'), '\n'),
  (RegExp(r'(?<=[.!?…])\s+'), ' '),
  (RegExp(r'\s+'), ' '),
];

/// Splits a trigger message into two halves of about equal length, cutting at
/// the coarsest boundary that has more than one piece: paragraphs, then lines,
/// then sentences, then words. Keywords stay whole, and an entry keyed on two
/// names in one paragraph keeps firing as long as the paragraph does.
///
/// Returns `[text]` when there is nothing left to cut — a single word.
List<String> splitTrigger(String text) {
  final trimmed = text.trim();
  for (final (boundary, joiner) in _triggerBoundaries) {
    final units = trimmed
        .split(boundary)
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList();
    if (units.length < 2) continue;
    final total = units.fold<int>(0, (sum, u) => sum + u.length);
    var cut = 1;
    var left = units.first.length;
    // Move the cut while it brings the left half closer to half the text.
    while (cut < units.length - 1 &&
        (left + units[cut].length) * 2 <= total + units[cut].length) {
      left += units[cut].length;
      cut++;
    }
    return [
      units.sublist(0, cut).join(joiner),
      units.sublist(cut).join(joiner),
    ];
  }
  return [trimmed];
}
