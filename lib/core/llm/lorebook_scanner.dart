import 'dart:math';

import '../models/character.dart';
import '../models/chat_message.dart';
import '../models/lorebook.dart';
import 'glaze_matcher.dart';
import 'lorebook_activation.dart';

final _rng = Random();

class ScannedEntry {
  final String id;
  final String comment;
  final String content;
  final String position;
  final int order;
  final String lorebookName;
  final String lorebookId;
  final bool constant;
  final int? maxInjectedEntries;

  const ScannedEntry({
    required this.id,
    required this.comment,
    required this.content,
    required this.position,
    required this.order,
    required this.lorebookName,
    required this.lorebookId,
    required this.constant,
    this.maxInjectedEntries,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'comment': comment,
    'content': content,
    'position': position,
    'order': order,
    'lorebookName': lorebookName,
    'lorebookId': lorebookId,
    'constant': constant,
    'maxInjectedEntries': maxInjectedEntries,
  };

  factory ScannedEntry.fromJson(Map<String, dynamic> json) => ScannedEntry(
    id: json['id'] as String,
    comment: json['comment'] as String,
    content: json['content'] as String,
    position: json['position'] as String,
    order: json['order'] as int,
    lorebookName: json['lorebookName'] as String,
    lorebookId: json['lorebookId'] as String,
    constant: json['constant'] as bool,
    maxInjectedEntries: json['maxInjectedEntries'] as int?,
  );
}

List<ScannedEntry> scanLorebooks({
  required List<ChatMessage> history,
  required Character? char,
  required String textToScan,
  required String? chatId,
  required List<Lorebook> lorebooks,
  required LorebookGlobalSettings globalSettings,
  required LorebookActivations activations,
  bool applyPerBookLimits = true,
}) {
  if (globalSettings.searchType == 'vector') return [];

  final activeLorebooks = activeLorebooksFor(
    lorebooks: lorebooks,
    charId: char?.id,
    charGroupId: char?.variantGroupId,
    charWorld: char?.world,
    chatId: chatId,
    activations: activations,
  );

  if (activeLorebooks.isEmpty) return [];

  final allRelevantEntries = <ScannedEntry>[];
  final relevantEntryKeys = <String>{};
  final candidateEntries = <_CandidateEntry>[];
  final visibleHistory = history
      .where((message) => !message.isHidden && !message.isTyping)
      .toList(growable: false);
  final historyByDepth = <int, String>{};
  final lowerHistoryByDepth = <int, String>{};

  String historyTextFor(int depth, {required bool caseSensitive}) {
    final cache = caseSensitive ? historyByDepth : lowerHistoryByDepth;
    return cache.putIfAbsent(depth, () {
      final start = visibleHistory.length > depth
          ? visibleHistory.length - depth
          : 0;
      final text = visibleHistory
          .skip(start)
          .map((message) => message.content)
          .join('\n');
      return caseSensitive ? text : text.toLowerCase();
    });
  }

  for (final lb in activeLorebooks) {
    final lbSettings = lb.settings;
    final lbScanDepth = lbSettings?.scanDepth;
    final lbRecursiveScan = lbSettings?.recursiveScan;
    final lbCaseSensitive = lbSettings?.caseSensitive;
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

      candidateEntries.add(
        _CandidateEntry(
          entry: entry,
          lorebookName: lb.name,
          lorebookId: lb.id,
          scanDepth: lbScanDepth,
          recursiveScan: lbRecursiveScan,
          caseSensitive: lbCaseSensitive,
          matchWholeWords: lbMatchWholeWords,
          maxInjectedEntries: lbSettings?.maxInjectedEntries,
        ),
      );
    }
  }

  for (final c in candidateEntries) {
    if (c.entry.constant) {
      if (relevantEntryKeys.add(_candidateKey(c))) {
        allRelevantEntries.add(_toScanned(c));
      }
    }
  }

  var changed = true;
  var iteration = 0;
  final maxIterations =
      (candidateEntries.firstOrNull?.recursiveScan ??
          globalSettings.recursiveScan)
      ? 5
      : 1;
  var scanText = textToScan;

  while (changed && iteration < maxIterations) {
    changed = false;
    iteration++;

    for (final c in candidateEntries) {
      final entry = c.entry;
      if (relevantEntryKeys.contains(_candidateKey(c))) {
        continue;
      }
      if (entry.constant) continue;

      final primaryKeys = entry.keys;
      final secondaryKeys = entry.secondaryKeys;
      final logic = entry.selectiveLogic;

      final caseSensitive =
          entry.caseSensitive ??
          c.caseSensitive ??
          globalSettings.caseSensitive;
      final wholeWords = resolveWholeWords(
        entry.matchWholeWords,
        c.matchWholeWords != null
            ? (c.matchWholeWords == 'true')
            : globalSettings.matchWholeWords,
        globalSettings.keySearchMode,
      );

      final scanDepth =
          entry.scanDepth ?? c.scanDepth ?? globalSettings.scanDepth;
      final temporalDepth = entry.sticky > entry.cooldown
          ? entry.sticky
          : entry.cooldown;
      final effectiveScanDepth = temporalDepth > 0
          ? scanDepth < temporalDepth
                ? scanDepth
                : temporalDepth
          : scanDepth;

      final messagesToScan = historyTextFor(
        effectiveScanDepth,
        caseSensitive: caseSensitive,
      );
      final scanSource = caseSensitive
          ? '$messagesToScan$scanText'
          : '$messagesToScan${scanText.toLowerCase()}';

      bool isStickyActive = false;
      bool isOnCooldown = false;

      if (entry.sticky > 0 || entry.cooldown > 0) {
        final temporalMax = entry.sticky > entry.cooldown
            ? entry.sticky
            : entry.cooldown;
        for (var i = 1; i <= temporalMax; i++) {
          final idx = visibleHistory.length - i;
          if (idx < 0) break;
          final histSource = caseSensitive
              ? visibleHistory[idx].content
              : visibleHistory[idx].content.toLowerCase();
          final wasMatched = primaryKeys.any(
            (key) =>
                glazeCheckMatch(key, histSource, caseSensitive, wholeWords),
          );
          if (wasMatched) {
            if (i <= entry.sticky) isStickyActive = true;
            if (i <= entry.cooldown) isOnCooldown = true;
            break;
          }
        }
      }

      if (isOnCooldown) continue;

      final matchedPrimary =
          isStickyActive ||
          primaryKeys.any(
            (key) =>
                glazeCheckMatch(key, scanSource, caseSensitive, wholeWords),
          );

      if (matchedPrimary) {
        bool secondaryMatches = true;

        if (logic == 4 || secondaryKeys.isEmpty) {
          secondaryMatches = true;
        } else if (secondaryKeys.isNotEmpty) {
          final matches = secondaryKeys.map(
            (key) =>
                glazeCheckMatch(key, scanSource, caseSensitive, wholeWords),
          );
          final anyMatch = matches.any((m) => m);
          final allMatch = matches.every((m) => m);

          switch (logic) {
            case 0:
              secondaryMatches = anyMatch;
            case 1:
              secondaryMatches = allMatch;
            case 2:
              secondaryMatches = !anyMatch;
            case 3:
              secondaryMatches = !allMatch;
          }
        }

        if (secondaryMatches) {
          if (entry.probability < 100) {
            if (_randomPercent() > entry.probability) continue;
          }

          allRelevantEntries.add(_toScanned(c));
          relevantEntryKeys.add(_candidateKey(c));

          if (!entry.preventRecursion && iteration < maxIterations) {
            scanText = '$scanText\n${entry.content.toLowerCase()}';
            changed = true;
          }
        }
      }
    }
  }

  allRelevantEntries.sort((a, b) => a.order.compareTo(b.order));

  // Separate constant entries from keyword-triggered ones.
  // Constant entries are always injected and do not count toward any cap.
  final constantEntries = allRelevantEntries.where((e) => e.constant).toList();
  var triggeredEntries = allRelevantEntries.where((e) => !e.constant).toList();

  final perBookLimits = <String, int>{};
  for (final c in candidateEntries) {
    if (c.maxInjectedEntries != null && c.maxInjectedEntries! > 0) {
      perBookLimits[c.lorebookId] = c.maxInjectedEntries!;
    }
  }

  if (applyPerBookLimits) {
    triggeredEntries = applyLorebookPerBookLimits(triggeredEntries);
  }

  // Do not apply the global entry cap here. Hybrid keyword/vector merge needs
  // the full keyword-activated set so keyword hits can dedupe matching vector
  // hits even when they overflow the final keyword slot budget.
  return [...constantEntries, ...triggeredEntries];
}

List<ScannedEntry> applyLorebookPerBookLimits(List<ScannedEntry> entries) {
  final lorebookCounts = <String, int>{};
  final filtered = <ScannedEntry>[];
  for (final entry in entries) {
    final limit = entry.maxInjectedEntries;
    if (limit != null) {
      final count = lorebookCounts[entry.lorebookId] ?? 0;
      if (count >= limit) continue;
      lorebookCounts[entry.lorebookId] = count + 1;
    }
    filtered.add(entry);
  }
  return filtered;
}

int _randomPercent() => _rng.nextInt(100);

ScannedEntry _toScanned(_CandidateEntry c) => ScannedEntry(
  id: c.entry.id,
  comment: c.entry.comment,
  content: c.entry.content,
  position: c.entry.position,
  order: c.entry.order,
  lorebookName: c.lorebookName,
  lorebookId: c.lorebookId,
  constant: c.entry.constant,
  maxInjectedEntries: c.maxInjectedEntries,
);

String _candidateKey(_CandidateEntry candidate) =>
    '${candidate.lorebookId}_${candidate.entry.id}';

class _CandidateEntry {
  final LorebookEntry entry;
  final String lorebookName;
  final String lorebookId;
  final int? scanDepth;
  final bool? recursiveScan;
  final bool? caseSensitive;
  final String? matchWholeWords;
  final int? maxInjectedEntries;

  const _CandidateEntry({
    required this.entry,
    required this.lorebookName,
    required this.lorebookId,
    this.scanDepth,
    this.recursiveScan,
    this.caseSensitive,
    this.matchWholeWords,
    this.maxInjectedEntries,
  });
}
