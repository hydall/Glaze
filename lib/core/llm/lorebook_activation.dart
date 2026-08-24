import '../models/lorebook.dart';

/// Which lorebooks apply to a given character/chat pair.
///
/// A book is active when it is globally enabled, when it was explicitly
/// activated for this character or this chat (the `lorebookActivations`
/// prefs maps), when its own `activationScope`/`activationTargetId` points at
/// this character or chat, or when its name matches the character's `world`
/// field (SillyTavern character-book convention).
///
/// This is the single definition of "active lorebook": the keyword scanner
/// ([scanLorebooks]), the vector search ([LorebookVectorSearch.search]) and
/// the Quick Access lorebook card all resolve activation through here, so a
/// card can never disagree with what generation actually injects.
List<Lorebook> activeLorebooksFor({
  required List<Lorebook> lorebooks,
  required String? charId,
  String? charGroupId,
  required String? charWorld,
  required String? chatId,
  required LorebookActivations? activations,
}) {
  final characterTargets = <String>{
    if (charId?.isNotEmpty == true) charId!,
    if (charGroupId?.isNotEmpty == true) charGroupId!,
  };
  return lorebooks.where((lb) {
    if (lb.enabled) return true;
    if (characterTargets.any(
      (id) => activations?.character[id]?.contains(lb.id) == true,
    )) {
      return true;
    }
    if (chatId != null && activations?.chat[chatId]?.contains(lb.id) == true) {
      return true;
    }
    if (characterTargets.isNotEmpty &&
        lb.activationScope == 'character' &&
        characterTargets.contains(lb.activationTargetId)) {
      return true;
    }
    if (chatId != null &&
        lb.activationScope == 'chat' &&
        lb.activationTargetId == chatId) {
      return true;
    }
    if (charWorld != null && charWorld.isNotEmpty && lb.name == charWorld) {
      return true;
    }
    return false;
  }).toList();
}

/// Enabled entries across every book active for this character/chat.
///
/// Disabled entries are excluded because they can never be injected. Entries
/// that only activate through vector search are counted — they are still live
/// for the chat, just via a different retrieval path.
int activeLorebookEntryCount({
  required List<Lorebook> lorebooks,
  required String? charId,
  String? charGroupId,
  required String? charWorld,
  required String? chatId,
  required LorebookActivations? activations,
}) {
  final active = activeLorebooksFor(
    lorebooks: lorebooks,
    charId: charId,
    charGroupId: charGroupId,
    charWorld: charWorld,
    chatId: chatId,
    activations: activations,
  );
  var count = 0;
  for (final lb in active) {
    for (final entry in lb.entries) {
      if (entry.enabled) count++;
    }
  }
  return count;
}
