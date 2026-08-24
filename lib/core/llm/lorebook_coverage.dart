import '../models/character.dart';
import '../models/chat_message.dart';
import '../models/lorebook.dart';
import 'glaze_matcher.dart';
import 'lorebook_activation.dart';

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
  final bool cutOffByBudget;

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
    this.cutOffByBudget = false,
  });
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
}

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
    if (vectorEntries.isEmpty) {
      return const CoverageResult(
        entries: [],
        totalCandidates: 0,
        activatedCount: 0,
        cutOffCount: 0,
      );
    }
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
        matchedKeys: ['[vector]'],
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

  if (activeLorebooks.isEmpty) {
    return const CoverageResult(
      entries: [],
      totalCandidates: 0,
      activatedCount: 0,
      cutOffCount: 0,
    );
  }

  final maxInjectedEntries = globalSettings.maxInjectedEntries.clamp(1, 100);
  final candidates = <String, _Candidate>{};

  for (final lb in activeLorebooks) {
    final lbSettings = lb.settings;
    final lbScanDepth = lbSettings?.scanDepth ?? globalSettings.scanDepth;
    final lbCaseSensitive =
        lbSettings?.caseSensitive ?? globalSettings.caseSensitive;
    final lbMatchWholeWords = lbSettings?.matchWholeWords;

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
        matchMessageIndex: entry.constant ? null : null,
        caseSensitive: effectiveCaseSensitive,
        wholeWords: effectiveWholeWords,
        scanDepth: effectiveScanDepth,
      );
    }
  }

  final nonHidden = history.where((m) => !m.isHidden).toList();

  for (final c in candidates.values) {
    final entry = c.entry;
    if (entry.constant) continue;

    final caseSensitive = c.caseSensitive;
    final wholeWords = c.wholeWords;
    final scanDepth = c.scanDepth;

    final scanMessages = nonHidden.length > scanDepth
        ? nonHidden.sublist(nonHidden.length - scanDepth)
        : nonHidden;

    final scanText = caseSensitive
        ? '$textToScan\n${scanMessages.map((m) => m.content).join('\n')}'
        : '${textToScan.toLowerCase()}\n${scanMessages.map((m) => m.content).join('\n').toLowerCase()}';

    final matchedPrimary = <String>[];
    for (final key in entry.keys) {
      if (key.isEmpty) continue;
      if (glazeCheckMatch(key, scanText, caseSensitive, wholeWords)) {
        matchedPrimary.add(key);
      }
    }

    int? matchIdx;
    if (matchedPrimary.isNotEmpty) {
      for (int i = scanMessages.length - 1; i >= 0; i--) {
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

    if (matchedPrimary.isEmpty) continue;

    bool secondaryPass = true;
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

    if (secondaryPass) {
      c.activated = true;
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
  final usedKeyword = keywordActivatedList.take(triggeredKeywordSlots).toList();

  final keywordSlotCount = constantActivated.length + usedKeyword.length;
  final remainingSlots = maxInjectedEntries - keywordSlotCount;
  final vectorSlots = hasVector
      ? (remainingSlots < maxVector ? remainingSlots : maxVector)
      : 0;
  final usableVectorSlots = vectorSlots < 0 ? 0 : vectorSlots;

  final usedVector = dedupedVectorEntries.take(usableVectorSlots).toList();

  // Keyword entries beyond the keyword budget are cut off by the entry cap.
  final keywordCutOffCount = keywordActivatedList.length > usedKeyword.length
      ? keywordActivatedList.length - usedKeyword.length
      : 0;
  for (int i = usedKeyword.length; i < keywordActivatedList.length; i++) {
    keywordActivatedList[i].cutOffByBudget = true;
  }

  // Vector entries beyond usableVectorSlots are cut off by the entry cap.
  final vectorCutOffCount = dedupedVectorEntries.length > usableVectorSlots
      ? dedupedVectorEntries.length - usableVectorSlots
      : 0;
  final vectorInBudget = usedVector;
  final vectorOverBudget = dedupedVectorEntries
      .skip(usableVectorSlots)
      .toList();

  final totalCutOff = keywordCutOffCount + vectorCutOffCount;
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
      matchedKeys: ['[vector]'],
      cutOffByBudget: cutOff,
    );
  }

  final allEntries = <CoverageEntry>[
    // Constants first — always active, never cut off.
    ...constantActivated.map(_toCoverage),
    // In-budget keyword entries.
    ...usedKeyword.map(_toCoverage),
    // Over-budget keyword entries (cut off by entry cap).
    ...keywordActivatedList.skip(usedKeyword.length).map((c) {
      final base = _toCoverage(c);
      return CoverageEntry(
        id: base.id,
        comment: base.comment,
        content: base.content,
        position: base.position,
        order: base.order,
        lorebookName: base.lorebookName,
        lorebookId: base.lorebookId,
        constant: base.constant,
        activated: base.activated,
        matchedKeys: base.matchedKeys,
        matchedSecondaryKeys: base.matchedSecondaryKeys,
        matchMessageIndex: base.matchMessageIndex,
        cutOffByBudget: true,
      );
    }),
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
  cutOffByBudget: c.cutOffByBudget,
);

class _Candidate {
  final LorebookEntry entry;
  final String lorebookName;
  final String lorebookId;
  bool activated;
  List<String> matchedKeys;
  List<String> matchedSecondaryKeys;
  int? matchMessageIndex;
  bool cutOffByBudget = false;
  final bool caseSensitive;
  final WholeWordMode wholeWords;
  final int scanDepth;

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
  });
}
