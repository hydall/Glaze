import '../../models/chat_message.dart';

int? _toInt(dynamic value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  if (value is double) return value.toInt();
  return null;
}

Map<String, dynamic> normalizeJsMessage(
    Map<String, dynamic> msg, String charId, int sessionIdx, int mi) {
  var role = msg['role'] as String? ?? 'user';
  if (role == 'char') role = 'assistant';

  final content =
      (msg['text'] is String ? msg['text'] as String : null) ??
          (msg['content'] is String
              ? msg['content'] as String
              : null) ??
          (msg['mes'] is String ? msg['mes'] as String : null) ??
          '';

  final swipes = <String>[];
  final rawSwipes = msg['swipes'];
  if (rawSwipes is List) {
    for (final s in rawSwipes) {
      swipes.add(s.toString());
    }
  }
  if (swipes.isEmpty && content.isNotEmpty) {
    swipes.add(content);
  }

  String? reasoning;
  final rawReasoning = msg['reasoning'];
  if (rawReasoning is String && rawReasoning.isNotEmpty) {
    reasoning = rawReasoning;
  }

  final persona = msg['persona'];
  String? personaId;
  String? personaName;
  if (persona is Map) {
    personaId = persona['id'] as String?;
    personaName = persona['name'] as String?;
  }

  return {
    'id': msg['id']?.toString() ??
        '${charId}_${sessionIdx}_$mi',
    'role': role,
    'content': content,
    'timestamp': msg['timestamp'],
    'personaId': msg['personaId'] ?? personaId,
    'personaName': msg['personaName'] ?? personaName,
    'swipes': swipes,
    'swipeId': _toInt(msg['swipeId'] ?? msg['swipe_id']) ?? 0,
    'reasoning': reasoning,
    'isHidden': msg['isHidden'] ?? msg['is_hidden'] ?? false,
    'isError': msg['isError'] ?? false,
    'genTime': msg['genTime']?.toString(),
    'tokens': _toInt(msg['tokens']),
    'greetingIndex':
        _toInt(msg['greetingIndex'] ?? msg['greeting_index']),
    'contextRefs': msg['contextRefs'] is List
        ? List<String>.from((msg['contextRefs'] as List).whereType<String>())
        : <String>[],
    'swipeDirection': msg['swipeDirection'] is String
        ? msg['swipeDirection']
        : (msg['swipe_direction'] is String
            ? msg['swipe_direction'] as String
            : 'none'),
    'isEditing':
        msg['isEditing'] == true || msg['is_editing'] == true,
    'isTyping':
        msg['isTyping'] == true || msg['is_typing'] == true,
    'guidanceText': msg['guidanceText'] is String
        ? msg['guidanceText'] as String
        : null,
    'guidanceType': msg['guidanceType'] is String
        ? msg['guidanceType'] as String
        : 'GENERATION',
    'triggeredLorebooks': msg['triggeredLorebooks'] is List
        ? parseTriggeredEntries(msg['triggeredLorebooks'] as List)
        : <TriggeredEntry>[],
    'triggeredMemories': msg['triggeredMemories'] is List
        ? parseTriggeredEntries(msg['triggeredMemories'] as List)
            .map((e) => TriggeredEntry(id: e.id, name: e.name, lorebookName: e.lorebookName, lorebookId: e.lorebookId, source: 'memory'))
            .toList()
        : <TriggeredEntry>[],
    'swipesMeta': msg['swipesMeta'] is List
        ? (msg['swipesMeta'] as List)
            .whereType<Map<String, dynamic>>()
            .toList()
        : <Map<String, dynamic>>[],
    'memoryCoverage': msg['memoryCoverage'] is Map
        ? Map<String, dynamic>.from(msg['memoryCoverage'] as Map)
        : <String, dynamic>{},
    'time':
        msg['time'] is String ? msg['time'] as String : null,
  };
}

List<TriggeredEntry> parseTriggeredEntries(List<dynamic> raw) {
  return raw.map((item) {
    if (item is Map<String, dynamic>) {
      return TriggeredEntry(
        id: item['id'] as String? ?? '',
        name: item['name'] as String? ?? item['comment'] as String? ?? '',
        lorebookName: item['lorebookName'] as String? ?? '',
        lorebookId: item['lorebookId'] as String? ?? '',
        source: item['_source'] as String? ?? item['source'] as String? ?? 'keyword',
      );
    }
    if (item is String) {
      return TriggeredEntry(id: item, name: item, source: 'keyword');
    }
    return TriggeredEntry(id: '', name: '', source: 'keyword');
  }).toList();
}
