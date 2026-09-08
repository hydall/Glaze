import '../models/lorebook.dart';
import 'lorebook_scanner.dart';

List<LorebookEntry> mergeKeywordVector({
  required List<ScannedEntry> keywordEntries,
  required List<LorebookEntry> vectorEntries,
  required LorebookGlobalSettings settings,
}) {
  final maxEntries = settings.maxInjectedEntries;
  final maxVector = settings.vectorTopK;
  final constantKeywords = keywordEntries.where((e) => e.constant).toList();
  final triggeredKeywords = applyLorebookPerBookLimits(
    keywordEntries.where((e) => !e.constant).toList(),
  );

  // Step 1: fill with keyword entries first (constants + triggered).
  // Constants bypass the entry cap by design (see lorebook_coverage.dart);
  // only triggered keywords are counted against `maxEntries`. When constants
  // already exceed `maxEntries`, no triggered-keyword slots remain — clamp to
  // 0 so `.take()` never receives a negative count (RangeError).
  final triggeredKeywordSlots = maxEntries - constantKeywords.length < 0
      ? 0
      : maxEntries - constantKeywords.length;
  final usedKeyword = triggeredKeywords.take(triggeredKeywordSlots).toList();

  if (vectorEntries.isEmpty) {
    return [
      ...constantKeywords.map(_fromScanned),
      ...usedKeyword.map(_fromScanned),
    ];
  }

  // Step 2: fill remaining slots with vector entries, but no more than
  // maxVector (vectorTopK).  Unused keyword slots do NOT carry over to
  // vector — vectorTopK is a hard cap, not a split percentage.
  final keywordSlotCount = constantKeywords.length + usedKeyword.length;
  final remainingSlots = maxEntries - keywordSlotCount;
  final vectorSlots = remainingSlots < maxVector ? remainingSlots : maxVector;
  final usableVectorSlots = vectorSlots < 0 ? 0 : vectorSlots;

  // Dedupe vector entries against keyword entries already selected.
  final keywordIds = {
    ...constantKeywords.map(_scannedKey),
    ...usedKeyword.map(_scannedKey),
  };
  final dedupedVector = vectorEntries
      .where((e) => !keywordIds.contains(_entryKey(e)))
      .toList();

  final usedVector = dedupedVector.take(usableVectorSlots).toList();

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
);

String _scannedKey(ScannedEntry entry) => '${entry.lorebookId}_${entry.id}';

String _entryKey(LorebookEntry entry) => '${entry.lorebookId}_${entry.id}';
