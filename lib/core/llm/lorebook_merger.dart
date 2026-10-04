import '../models/lorebook.dart';
import 'lorebook_limits.dart';
import 'lorebook_scanner.dart';

List<LorebookEntry> mergeKeywordVector({
  required List<ScannedEntry> keywordEntries,
  required List<LorebookEntry> vectorEntries,
  required LorebookGlobalSettings settings,
}) {
  final maxEntries = resolveGlobalEntryCap(settings);
  final maxVector = settings.vectorTopK;
  final constantKeywords = keywordEntries.where((e) => e.constant).toList();
  final triggeredKeywords = applyLorebookPerBookLimits(
    keywordEntries.where((e) => !e.constant).toList(),
  );

  // Step 1: fill with keyword entries first (constants + triggered).
  // Constants bypass the entry cap by design (see lorebook_coverage.dart) but
  // still spend slots, so only the remainder is open to triggered
  // keywords. An entry flagged `ignoreBudget` is exempt on both counts: it is
  // always kept and it never spends a slot, so it cannot starve the rest.
  // When constants already exceed `maxEntries` the remainder clamps to 0
  // rather than going negative.
  final budgetedConstants = constantKeywords
      .where((e) => !e.ignoreBudget)
      .length;
  var freeSlots = maxEntries - budgetedConstants;
  if (freeSlots < 0) freeSlots = 0;

  final usedKeyword = <ScannedEntry>[];
  for (final entry in triggeredKeywords) {
    if (entry.ignoreBudget) {
      usedKeyword.add(entry);
      continue;
    }
    if (freeSlots == 0) continue;
    freeSlots--;
    usedKeyword.add(entry);
  }

  if (vectorEntries.isEmpty) {
    return [
      ...constantKeywords.map(_fromScanned),
      ...usedKeyword.map(_fromScanned),
    ];
  }

  // Step 2: fill the slots the keyword pass left over with vector entries, but
  // no more than maxVector (vectorTopK). vectorTopK is a hard cap, not a split
  // percentage — unused keyword slots do not raise it.
  var vectorSlots = freeSlots < maxVector ? freeSlots : maxVector;
  if (vectorSlots < 0) vectorSlots = 0;

  // Dedupe vector entries against keyword entries already selected.
  final keywordIds = {
    ...constantKeywords.map(_scannedKey),
    ...usedKeyword.map(_scannedKey),
  };
  final dedupedVector = vectorEntries
      .where((e) => !keywordIds.contains(_entryKey(e)))
      .toList();

  final usedVector = <LorebookEntry>[];
  for (final entry in dedupedVector) {
    if (entry.ignoreBudget) {
      usedVector.add(entry);
      continue;
    }
    if (vectorSlots == 0) continue;
    vectorSlots--;
    usedVector.add(entry);
  }

  return [
    ...constantKeywords.map(_fromScanned),
    ...usedKeyword.map(_fromScanned),
    ...usedVector,
  ];
}

LorebookEntry _fromScanned(ScannedEntry e) => LorebookEntry(
  id: e.id,
  comment: e.comment,
  content: e.content,
  position: e.position,
  lorebookId: e.lorebookId,
  lorebookName: e.lorebookName,
  ignoreBudget: e.ignoreBudget,
);

String _scannedKey(ScannedEntry entry) => '${entry.lorebookId}_${entry.id}';

String _entryKey(LorebookEntry entry) => '${entry.lorebookId}_${entry.id}';
