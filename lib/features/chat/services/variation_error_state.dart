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

/// Whether variation [index] of [message] is an error variation: its meta
/// carries `isError: true`, or — for the active variation of a message written
/// before the per-swipe markers existed — the message itself is flagged.
bool variationIsError(ChatMessage message, int index) {
  if (index >= 0 && index < message.swipesMeta.length) {
    final marked = message.swipesMeta[index]['isError'];
    if (marked is bool) return marked;
  }
  return index == message.swipeId && message.isError;
}

/// The variations a regenerate of [message] builds on.
///
/// [swipes] and [swipesMeta] are always the same length. The active entry's
/// meta carries the message's live stats and its blue sub-swipes, so switching
/// back to it after the regen restores what the reader last saw.
class RegenBase {
  final List<String> swipes;
  final List<Map<String, dynamic>> swipesMeta;

  /// Index of the previously active variation inside [swipes], or -1 when it
  /// was an error and has been left out.
  final int activeIndex;

  const RegenBase({
    required this.swipes,
    required this.swipesMeta,
    required this.activeIndex,
  });

  bool get droppedActiveError => activeIndex < 0;
}

/// Builds the [RegenBase] for regenerating [message].
///
/// A regenerate over an error *replaces* the error: the failed variation is
/// left out, so the new reply (or the next error) takes its place instead of
/// piling up beside it. The caller's restoration snapshot still holds the full
/// message, so cancelling the regen with nothing streamed puts the error back
/// (INV-A2b).
RegenBase regenBaseOf(ChatMessage message) {
  final swipes = message.swipes.isNotEmpty
      ? List<String>.from(message.swipes)
      : [message.content];
  final active = message.swipeId.clamp(0, swipes.length - 1);
  final meta = List<Map<String, dynamic>>.generate(
    swipes.length,
    (i) => i < message.swipesMeta.length
        ? Map<String, dynamic>.from(message.swipesMeta[i])
        : <String, dynamic>{},
  );

  if (variationIsError(message, active)) {
    swipes.removeAt(active);
    meta.removeAt(active);
    return RegenBase(swipes: swipes, swipesMeta: meta, activeIndex: -1);
  }

  final activeMeta = meta[active];
  final nested = message.agentSwipes.map((swipe) => swipe.toJson()).toList();
  if (message.agentSwipeId >= 0 &&
      message.agentSwipeId < nested.length &&
      nested[message.agentSwipeId]['time'] == null) {
    nested[message.agentSwipeId]['time'] = message.time;
  }
  meta[active] = <String, dynamic>{
    ...activeMeta,
    if (!activeMeta.containsKey('genTime')) 'genTime': message.genTime,
    if (!activeMeta.containsKey('reasoning')) 'reasoning': message.reasoning,
    if (!activeMeta.containsKey('tokens')) 'tokens': message.tokens,
    if (!activeMeta.containsKey('time')) 'time': message.time,
    if (nested.isNotEmpty) 'agentSwipes': nested,
    if (nested.isNotEmpty) 'agentSwipeId': message.agentSwipeId,
  };
  return RegenBase(swipes: swipes, swipesMeta: meta, activeIndex: active);
}
