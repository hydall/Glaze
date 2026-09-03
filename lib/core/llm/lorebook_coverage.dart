import '../models/character.dart';
import '../models/chat_message.dart';
import '../models/lorebook.dart';
import 'glaze_matcher.dart';
import 'lorebook_activation.dart';

/// Why an activated entry still did not make it into the prompt.
enum CoverageCutOff {
  /// The global `maxInjectedEntries` (or `vectorTopK`) budget ran out.
  budget,

  /// The entry's own lorebook hit its per-book `maxInjectedEntries` cap first
  /// — the same cut `applyLorebookPerBookLimits` makes in the real scan.
  bookLimit,
}

class CoverageEntry {
  final String id;
  final String comment;
  final String content;
  final String position;
  final int order;
  final String lorebookName;
  final String lorebookId;
  final bool constant;
  final bool activated;
  final List<String> matchedKeys;
  final List<String> matchedSecondaryKeys;
  final int? matchMessageIndex;
  final CoverageCutOff? cutOff;

  /// Which recursion pass activated the entry. 1 is the ordinary first pass;
  /// anything higher means the entry was only reached because an earlier
  /// entry's content was fed back into the scan text.
  final int recursionPass;

  /// The entry did not match on this turn but is still held active by its
  /// `sticky` window.
  final bool stickyHeld;

  /// The entry matched but its `cooldown` window suppresses it.
  final bool onCooldown;

  const CoverageEntry({
    required this.id,
    required this.comment,
    required this.content,
    required this.position,
    required this.order,
    required this.lorebookName,
    required this.lorebookId,
    required this.constant,
    required this.activated,
    this.matchedKeys = const [],
    this.matchedSecondaryKeys = const [],
    this.matchMessageIndex,
    this.cutOff,
    this.recursionPass = 1,
    this.stickyHeld = false,
    this.onCooldown = false,
  });

  /// Activated but not injected, for whatever reason. Kept as the name the
  /// filters and badges have always used; [cutOff] says which cap did it.
  bool get cutOffByBudget => cutOff != null;

  bool get viaRecursion => recursionPass > 1;
}

class CoverageResult {
  final List<CoverageEntry> entries;
  final int totalCandidates;
  final int activatedCount;
  final int cutOffCount;

  const CoverageResult({
    required this.entries,
    required this.totalCandidates,
    required this.activatedCount,
    required this.cutOffCount,
  });

  static const empty = CoverageResult(
    entries: [],
    totalCandidates: 0,
    activatedCount: 0,
    cutOffCount: 0,
  );

  int get injectedCount => activatedCount - cutOffCount;
  int get inactiveCount => totalCandidates - activatedCount;
}

/// Dry-runs lorebook activation for the diagnostics surfaces (the coverage tab
/// of the Prompt Inspector and the context card under the chat header).
///
/// It mirrors [scanLorebooks] (`lorebook_scanner.dart`) deliberately: recursive
/// scanning, sticky/cooldown windows and per-book entry caps all behave the way
/// the real prompt build behaves, so a reading here is not a different answer
/// from what the model will actually receive. The one rule it does NOT
/// reproduce is `entry.probability`: rolling dice would make the same chat
/// report a different coverage on every refresh, so a sub-100 % entry is shown
/// as it would be at 100 %.
CoverageResult computeLorebookCoverage({
  required List<ChatMessage> history,
  required Character? char,
  required String textToScan,
  required String? chatId,
  required List<Lorebook> lorebooks,
  required LorebookGlobalSettings globalSettings,
  required LorebookActivations activations,
  List<LorebookEntry> vectorEntries = const [],
  // Maps a namespaced entry id to its lorebook for legacy callers whose vector
  // entries do not carry provenance yet.
  Map<String, String> vectorEntryLorebookIds = const {},
}) {
  Lorebook? lbForEntry(LorebookEntry entry) {
    final lbId = entry.lorebookId.isNotEmpty
        ? entry.lorebookId
        : vectorEntryLorebookIds.entries
              .where((item) => item.key.endsWith('_${entry.id}'))
              .map((item) => item.value)
              .firstOrNull;
    if (lbId != null) return lorebooks.where((l) => l.id == lbId).firstOrNull;
    return lorebooks
        .where((l) => l.entries.any((en) => en.id == entry.id))
        .firstOrNull;
  }

  // In vector-only mode, show only vector results (keyword scan is skipped).
  if (globalSettings.searchType == 'vector') {
    if (vectorEntries.isEmpty) return CoverageResult.empty;
    final entries = vectorEntries.map((e) {
      final lb = lbForEntry(e);
      return CoverageEntry(
        id: e.id,
        comment: e.comment,
        content: e.content,
        position: e.position,
        order: e.order,
        lorebookName: lb?.name ?? '',
        lorebookId: lb?.id ?? '',
        constant: e.constant,
        activated: true,
        matchedKeys: const ['[vector]'],
      );
    }).toList();
    return CoverageResult(
      entries: entries,
      totalCandidates: entries.length,
      activatedCount: entries.length,
      cutOffCount: 0,
    );
  }

  final activeLorebooks = activeLorebooksFor(
    lorebooks: lorebooks,
    charId: char?.id,
    charGroupId: char?.variantGroupId,
    charWorld: char?.world,
    chatId: chatId,
    activations: activations,
  );

  if (activeLorebooks.isEmpty) return CoverageResult.empty;

  final maxInjectedEntries = globalSettings.maxInjectedEntries.clamp(1, 100);
  final candidates = <String, _Candidate>{};

  for (final lb in activeLorebooks) {
    final lbSettings = lb.settings;
    final lbScanDepth = lbSettings?.scanDepth ?? globalSettings.scanDepth;
    final lbCaseSensitive =
        lbSettings?.caseSensitive ?? globalSettings.caseSensitive;
    final lbMatchWholeWords = lbSettings?.matchWholeWords;
    final lbRecursiveScan = lbSettings?.recursiveScan;
    final lbMaxInjected = lbSettings?.maxInjectedEntries;

    for (final entry in lb.entries) {
      final isVectorOnly = entry.vectorSearch && !entry.useKeywordSearch;
      if (!entry.enabled || isVectorOnly) continue;

      if (char != null && entry.characterFilter != null) {
        final filter = entry.characterFilter!;
        if (filter.names.isNotEmpty) {
          final charName = char.name.toLowerCase();
          final isInCategory = filter.names.any(
            (n) => charName.contains(n.toLowerCase()),
          );
          if (filter.isExclude && isInCategory) continue;
          if (!filter.isExclude && !isInCategory) continue;
        }
      }

      final effectiveCaseSensitive = entry.caseSensitive ?? lbCaseSensitive;
      final effectiveWholeWords = resolveWholeWords(
        entry.matchWholeWords,
        lbMatchWholeWords != null
            ? (lbMatchWholeWords == 'true')
            : globalSettings.matchWholeWords,
        globalSettings.keySearchMode,
      );
      final effectiveScanDepth = entry.scanDepth ?? lbScanDepth;

      candidates['${lb.id}_${entry.id}'] = _Candidate(
        entry: entry,
        lorebookName: lb.name,
        lorebookId: lb.id,
        activated: entry.constant,
        matchedKeys: [],
        matchedSecondaryKeys: [],
        matchMessageIndex: null,
        caseSensitive: effectiveCaseSensitive,
        wholeWords: effectiveWholeWords,
        scanDepth: effectiveScanDepth,
        recursiveScan: lbRecursiveScan,
        maxInjectedEntries: (lbMaxInjected != null && lbMaxInjected > 0)
            ? lbMaxInjected
            : null,
      );
    }
  }

  // Same visibility rule as the scanner: a hidden or still-streaming message is
  // not part of the prompt, so it must not trigger an entry here either.
  final nonHidden = history
      .where((m) => !m.isHidden && !m.isTyping)
      .toList(growable: false);

  // Recursion feeds activated entry content back into the scan text, exactly as
  // `scanLorebooks` does, so a chain A -> B -> C reads the same in the preview
  // as it does in the built prompt.
  final recursiveScan =
      candidates.values.firstOrNull?.recursiveScan ??
      globalSettings.recursiveScan;
  final maxIterations = recursiveScan ? 5 : 1;
  var recursionText = textToScan;
  var changed = true;
  var iteration = 0;

  while (changed && iteration < maxIterations) {
    changed = false;
    iteration++;

    for (final c in candidates.values) {
      final entry = c.entry;
      if (entry.constant || c.activated) continue;

      final caseSensitive = c.caseSensitive;
      final wholeWords = c.wholeWords;

      // Sticky/cooldown shorten the window the entry is judged on.
      final temporalDepth = entry.sticky > entry.cooldown
          ? entry.sticky
          : entry.cooldown;
      final scanDepth = temporalDepth > 0 && temporalDepth < c.scanDepth
          ? temporalDepth
          : c.scanDepth;

      final scanMessages = nonHidden.length > scanDepth
          ? nonHidden.sublist(nonHidden.length - scanDepth)
          : nonHidden;

      final historyText = scanMessages.map((m) => m.content).join('\n');
      final scanText = caseSensitive
          ? '$historyText\n$recursionText'
          : '${historyText.toLowerCase()}\n${recursionText.toLowerCase()}';

      // A sticky entry stays on for `sticky` messages after its last hit; a
      // cooling one is suppressed for `cooldown` messages after it.
      var stickyHeld = false;
      var onCooldown = false;
      if (entry.sticky > 0 || entry.cooldown > 0) {
        for (var i = 1; i <= temporalDepth; i++) {
          final idx = nonHidden.length - i;
          if (idx < 0) break;
          final histSource = caseSensitive
              ? nonHidden[idx].content
              : nonHidden[idx].content.toLowerCase();
          final wasMatched = entry.keys.any(
            (key) =>
                key.isNotEmpty &&
                glazeCheckMatch(key, histSource, caseSensitive, wholeWords),
          );
          if (wasMatched) {
            if (i <= entry.sticky) stickyHeld = true;
            if (i <= entry.cooldown) onCooldown = true;
            break;
          }
        }
      }

      final matchedPrimary = <String>[];
      for (final key in entry.keys) {
        if (key.isEmpty) continue;
        if (glazeCheckMatch(key, scanText, caseSensitive, wholeWords)) {
          matchedPrimary.add(key);
        }
      }

      int? matchIdx;
      if (matchedPrimary.isNotEmpty) {
        for (var i = scanMessages.length - 1; i >= 0; i--) {
          final msgText = caseSensitive
              ? scanMessages[i].content
              : scanMessages[i].content.toLowerCase();
          for (final key in entry.keys) {
            if (key.isNotEmpty &&
                glazeCheckMatch(key, msgText, caseSensitive, wholeWords)) {
              matchIdx = history.indexOf(scanMessages[i]);
              break;
            }
          }
          if (matchIdx != null) break;
        }
      }

      final matchedSecondary = <String>[];
      if (matchedPrimary.isNotEmpty && entry.secondaryKeys.isNotEmpty) {
        for (final key in entry.secondaryKeys) {
          if (key.isEmpty) continue;
          if (glazeCheckMatch(key, scanText, caseSensitive, wholeWords)) {
            matchedSecondary.add(key);
          }
        }
      }

      c.matchedKeys = matchedPrimary;
      c.matchedSecondaryKeys = matchedSecondary;
      c.matchMessageIndex = matchIdx;
      c.stickyHeld = stickyHeld;
      c.onCooldown = onCooldown;

      if (onCooldown) continue;
      if (matchedPrimary.isEmpty && !stickyHeld) continue;

      var secondaryPass = true;
      final logic = entry.selectiveLogic;
      if (logic != 4 && entry.secondaryKeys.isNotEmpty) {
        final anyMatch = matchedSecondary.isNotEmpty;
        final allMatch = entry.secondaryKeys.every(
          (k) =>
              k.isEmpty ||
              glazeCheckMatch(k, scanText, caseSensitive, wholeWords),
        );

        switch (logic) {
          case 0:
            secondaryPass = anyMatch;
          case 1:
            secondaryPass = allMatch;
          case 2:
            secondaryPass = !anyMatch;
          case 3:
            secondaryPass = !allMatch;
        }
      }

      if (!secondaryPass) continue;

      c.activated = true;
      c.recursionPass = iteration;

      if (!entry.preventRecursion && iteration < maxIterations) {
        recursionText = '$recursionText\n${entry.content.toLowerCase()}';
        changed = true;
      }
    }
  }

  // Separate constant entries from keyword-triggered ones.
  // Constants are always injected and never count toward the slot cap.
  final constantActivated =
      candidates.values.where((c) => c.activated && c.entry.constant).toList()
        ..sort((a, b) => a.entry.order.compareTo(b.entry.order));

  final keywordActivatedList =
      candidates.values.where((c) => c.activated && !c.entry.constant).toList()
        ..sort((a, b) => a.entry.order.compareTo(b.entry.order));

  final notActivatedList = candidates.values.where((c) => !c.activated).toList()
    ..sort((a, b) => a.entry.order.compareTo(b.entry.order));

  // Per-book caps come first, before the global budget — the same order as
  // `scanLorebooks` -> `applyLorebookPerBookLimits` -> `mergeKeywordVector`.
  final perBookCounts = <String, int>{};
  final withinBookLimit = <_Candidate>[];
  final bookLimitCutOff = <_Candidate>[];
  for (final c in keywordActivatedList) {
    final limit = c.maxInjectedEntries;
    if (limit != null) {
      final used = perBookCounts[c.lorebookId] ?? 0;
      if (used >= limit) {
        c.cutOff = CoverageCutOff.bookLimit;
        bookLimitCutOff.add(c);
        continue;
      }
      perBookCounts[c.lorebookId] = used + 1;
    }
    withinBookLimit.add(c);
  }

  // Dedupe vector entries against all keyword-activated IDs (constants excluded —
  // they can't be vector-matched anyway since constant=true disables vectorSearch).
  final keywordActivatedIds = keywordActivatedList
      .map((c) => '${c.lorebookId}_${c.entry.id}')
      .toSet();
  final dedupedVectorEntries = vectorEntries
      .where((e) => !keywordActivatedIds.contains('${e.lorebookId}_${e.id}'))
      .toList();

  final hasVector = dedupedVectorEntries.isNotEmpty;

  // Apply the same keyword-first logic as mergeKeywordVector.
  // Constants bypass this entirely — they are always in-budget.
  // Keywords fill up to maxInjectedEntries; vectors fill remaining slots
  // but no more than vectorTopK (hard cap, no carry-over from unused
  // keyword slots). When constants already exceed `maxInjectedEntries`,
  // clamp triggered-keyword slots to 0 so `.take()` never receives a
  // negative count (RangeError).
  final maxVector = globalSettings.vectorTopK;

  final triggeredKeywordSlots =
      maxInjectedEntries - constantActivated.length < 0
      ? 0
      : maxInjectedEntries - constantActivated.length;
  final usedKeyword = withinBookLimit.take(triggeredKeywordSlots).toList();

  final keywordSlotCount = constantActivated.length + usedKeyword.length;
  final remainingSlots = maxInjectedEntries - keywordSlotCount;
  final vectorSlots = hasVector
      ? (remainingSlots < maxVector ? remainingSlots : maxVector)
      : 0;
  final usableVectorSlots = vectorSlots < 0 ? 0 : vectorSlots;

  final usedVector = dedupedVectorEntries.take(usableVectorSlots).toList();

  // Keyword entries beyond the keyword budget are cut off by the entry cap.
  final budgetCutOff = withinBookLimit.skip(usedKeyword.length).toList();
  for (final c in budgetCutOff) {
    c.cutOff = CoverageCutOff.budget;
  }

  // Vector entries beyond usableVectorSlots are cut off by the entry cap.
  final vectorCutOffCount = dedupedVectorEntries.length > usableVectorSlots
      ? dedupedVectorEntries.length - usableVectorSlots
      : 0;
  final vectorInBudget = usedVector;
  final vectorOverBudget = dedupedVectorEntries
      .skip(usableVectorSlots)
      .toList();

  final totalCutOff =
      budgetCutOff.length + bookLimitCutOff.length + vectorCutOffCount;
  // Constants are always active; keyword/vector cut-offs still count as "activated"
  // for the summary bar (they were triggered, just not injected).
  final totalActivated =
      constantActivated.length + usedKeyword.length + vectorInBudget.length;

  // Build vector CoverageEntries for in-budget and over-budget.
  CoverageEntry vectorToCoverage(LorebookEntry e, bool cutOff) {
    final lb = lbForEntry(e);
    return CoverageEntry(
      id: e.id,
      comment: e.comment,
      content: e.content,
      position: e.position,
      order: e.order,
      lorebookName: lb?.name ?? '',
      lorebookId: lb?.id ?? '',
      constant: e.constant,
      activated: true,
      matchedKeys: const ['[vector]'],
      cutOff: cutOff ? CoverageCutOff.budget : null,
    );
  }

  final allEntries = <CoverageEntry>[
    // Constants first — always active, never cut off.
    ...constantActivated.map(_toCoverage),
    // In-budget keyword entries.
    ...usedKeyword.map(_toCoverage),
    // Over-budget keyword entries (cut off by the global cap or a per-book one).
    ...budgetCutOff.map(_toCoverage),
    ...bookLimitCutOff.map(_toCoverage),
    ...vectorInBudget.map((e) => vectorToCoverage(e, false)),
    ...vectorOverBudget.map((e) => vectorToCoverage(e, true)),
    ...notActivatedList.map(_toCoverage),
  ];

  return CoverageResult(
    entries: allEntries,
    totalCandidates: candidates.length + dedupedVectorEntries.length,
    activatedCount: totalActivated + totalCutOff,
    cutOffCount: totalCutOff,
  );
}

CoverageEntry _toCoverage(_Candidate c) => CoverageEntry(
  id: c.entry.id,
  comment: c.entry.comment,
  content: c.entry.content,
  position: c.entry.position,
  order: c.entry.order,
  lorebookName: c.lorebookName,
  lorebookId: c.lorebookId,
  constant: c.entry.constant,
  activated: c.activated,
  matchedKeys: c.matchedKeys,
  matchedSecondaryKeys: c.matchedSecondaryKeys,
  matchMessageIndex: c.matchMessageIndex,
  cutOff: c.cutOff,
  recursionPass: c.recursionPass,
  stickyHeld: c.stickyHeld,
  onCooldown: c.onCooldown,
);

class _Candidate {
  final LorebookEntry entry;
  final String lorebookName;
  final String lorebookId;
  bool activated;
  List<String> matchedKeys;
  List<String> matchedSecondaryKeys;
  int? matchMessageIndex;
  CoverageCutOff? cutOff;
  int recursionPass = 1;
  bool stickyHeld = false;
  bool onCooldown = false;
  final bool caseSensitive;
  final WholeWordMode wholeWords;
  final int scanDepth;
  final bool? recursiveScan;
  final int? maxInjectedEntries;

  _Candidate({
    required this.entry,
    required this.lorebookName,
    required this.lorebookId,
    required this.activated,
    required this.matchedKeys,
    required this.matchedSecondaryKeys,
    required this.matchMessageIndex,
    required this.caseSensitive,
    required this.wholeWords,
    required this.scanDepth,
    this.recursiveScan,
    this.maxInjectedEntries,
  });
}
