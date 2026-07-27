import '../../../core/models/chat_message.dart';

/// Whether the variation restored from [original] is an error variation.
///
/// Error state is tracked per swipe (`swipesMeta[i]['isError']`, see
/// `ChatMessageService.setSwipe`), so a rollback has to read the marker of the
/// swipe it puts back rather than blanket-clearing the flag. Falls back to
/// [ChatMessage.isError] on the snapshot when the meta list carries no marker
/// (legacy messages, or a single-swipe message written before the per-swipe
/// markers existed).
bool restoredVariationIsError(
  ChatMessage original,
  List<Map<String, dynamic>> restoredSwipesMeta,
) {
  final idx = original.swipeId;
  if (idx >= 0 && idx < restoredSwipesMeta.length) {
    final marked = restoredSwipesMeta[idx]['isError'];
    if (marked is bool) return marked;
  }
  return original.isError;
}
