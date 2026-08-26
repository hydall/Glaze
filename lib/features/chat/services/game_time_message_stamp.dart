import '../../../core/models/chat_message.dart';

/// Stores a Ledger clock on the exact green/blue variation it describes.
/// [ChatMessage.time] remains a denormalized projection of the active variant
/// for the WebView and auxiliary consumers.
ChatMessage stampGameTimeForVariation(
  ChatMessage message, {
  required int swipeId,
  required int agentSwipeId,
  required String time,
}) {
  if (swipeId < 0) return message;

  final meta = List<Map<String, dynamic>>.generate(
    message.swipes.length > swipeId ? message.swipes.length : swipeId + 1,
    (index) => index < message.swipesMeta.length
        ? Map<String, dynamic>.from(message.swipesMeta[index])
        : <String, dynamic>{},
  );
  final targetMeta = meta[swipeId];
  final isActiveGreen = message.swipeId == swipeId;
  var agentSwipes = isActiveGreen
      ? List<AgentSwipe>.from(message.agentSwipes)
      : _agentSwipesFromMeta(targetMeta);

  if (agentSwipes.isEmpty) {
    final greenContent = swipeId < message.swipes.length
        ? message.swipes[swipeId]
        : isActiveGreen
        ? message.content
        : '';
    agentSwipes = [
      AgentSwipe(
        content: greenContent,
        reasoning: targetMeta['reasoning'] as String?,
        genTime: targetMeta['genTime'] as String?,
        tokens: targetMeta['tokens'] as int?,
        studioOutputs: _studioOutputsFromMeta(targetMeta),
      ),
    ];
  }
  if (agentSwipeId < 0 || agentSwipeId >= agentSwipes.length) return message;

  agentSwipes[agentSwipeId] = agentSwipes[agentSwipeId].copyWith(time: time);
  targetMeta
    ..['time'] = time
    ..['agentSwipes'] = agentSwipes.map((swipe) => swipe.toJson()).toList()
    ..['agentSwipeId'] = agentSwipeId;

  final isActive = isActiveGreen && message.agentSwipeId == agentSwipeId;
  return message.copyWith(
    time: isActive ? time : message.time,
    swipesMeta: meta,
    agentSwipes: isActiveGreen ? agentSwipes : message.agentSwipes,
  );
}

List<AgentSwipe> _agentSwipesFromMeta(Map<String, dynamic> meta) {
  final raw = meta['agentSwipes'];
  if (raw is! List) return <AgentSwipe>[];
  return raw
      .whereType<Map<dynamic, dynamic>>()
      .map((value) => AgentSwipe.fromJson(Map<String, dynamic>.from(value)))
      .toList();
}

List<Map<String, dynamic>> _studioOutputsFromMeta(Map<String, dynamic> meta) {
  final raw = meta['studioOutputs'];
  if (raw is! List) return const [];
  return raw
      .whereType<Map<dynamic, dynamic>>()
      .map((value) => Map<String, dynamic>.from(value))
      .toList();
}
