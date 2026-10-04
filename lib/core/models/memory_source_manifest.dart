import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'chat_message.dart';

enum MemorySourceValidity { verified, unverified, invalid }

/// Evidence captured when a summary is generated, never inferred on import.
/// Session branches retain message identities, so originSessionId is descriptive.
class MemorySourceManifest {
  final int version;
  final String originSessionId;
  final List<MemorySourceStamp> messages;
  final bool invalidated;

  MemorySourceManifest({
    this.version = 1,
    required this.originSessionId,
    required List<MemorySourceStamp> messages,
    this.invalidated = false,
  }) : messages = List.unmodifiable(messages);

  factory MemorySourceManifest.capture(
    String sessionId,
    List<ChatMessage> messages,
    List<String> expectedIds,
  ) {
    if (expectedIds.isEmpty ||
        expectedIds.toSet().length != expectedIds.length ||
        messages.length != expectedIds.length ||
        messages.any((m) => !eligible(m)) ||
        messages.asMap().entries.any((e) => e.value.id != expectedIds[e.key])) {
      throw StateError(
        'Memory sources are missing, reordered, or unavailable.',
      );
    }
    return MemorySourceManifest(
      originSessionId: sessionId,
      messages: List.unmodifiable(messages.map(MemorySourceStamp.capture)),
    );
  }

  static bool eligible(ChatMessage message) =>
      !message.isHidden &&
      !message.isTyping &&
      !message.isError &&
      message.content.trim().isNotEmpty &&
      (message.role == 'user' || message.role == 'assistant');

  MemorySourceValidity validate(
    List<String> expectedIds,
    List<ChatMessage> history,
  ) {
    if (invalidated ||
        version != 1 ||
        messages.isEmpty ||
        messages.length != expectedIds.length ||
        expectedIds.toSet().length != expectedIds.length) {
      return MemorySourceValidity.invalid;
    }
    final indexes = {for (var i = 0; i < history.length; i++) history[i].id: i};
    var previous = -1;
    for (var i = 0; i < messages.length; i++) {
      final stamp = messages[i];
      final index = indexes[stamp.messageId];
      if (stamp.messageId != expectedIds[i] ||
          index == null ||
          index <= previous ||
          !stamp.matches(history[index])) {
        return MemorySourceValidity.invalid;
      }
      previous = index;
    }
    return MemorySourceValidity.verified;
  }

  MemorySourceManifest invalidate() => MemorySourceManifest(
    version: version,
    originSessionId: originSessionId,
    messages: messages,
    invalidated: true,
  );

  /// Swipe indices are positional. Removing an earlier variation renumbers
  /// retained evidence; deleting the evidence itself permanently invalidates it.
  MemorySourceManifest removeVariation(
    String messageId,
    int swipeId,
    int? agentSwipeId,
  ) {
    var removed = invalidated;
    final shifted = messages
        .map((stamp) {
          if (stamp.messageId != messageId) return stamp;
          if (stamp.swipeId == swipeId &&
              (agentSwipeId == null || stamp.agentSwipeId == agentSwipeId)) {
            removed = true;
            return stamp;
          }
          return MemorySourceStamp(
            messageId: stamp.messageId,
            contentHash: stamp.contentHash,
            swipeId: agentSwipeId == null && stamp.swipeId > swipeId
                ? stamp.swipeId - 1
                : stamp.swipeId,
            agentSwipeId:
                agentSwipeId != null &&
                    stamp.swipeId == swipeId &&
                    stamp.agentSwipeId > agentSwipeId
                ? stamp.agentSwipeId - 1
                : stamp.agentSwipeId,
          );
        })
        .toList(growable: false);
    return MemorySourceManifest(
      version: version,
      originSessionId: originSessionId,
      messages: shifted,
      invalidated: removed,
    );
  }

  factory MemorySourceManifest.fromJson(Map<String, dynamic> json) {
    try {
      final rawMessages = json['messages'];
      if (rawMessages is! List) {
        throw const FormatException('Invalid source stamps');
      }
      return MemorySourceManifest(
        version: (json['version'] as num?)?.toInt() ?? 0,
        originSessionId: json['originSessionId'] as String? ?? '',
        messages: rawMessages
            .map(
              (e) => MemorySourceStamp.fromJson(
                Map<String, dynamic>.from(e as Map),
              ),
            )
            .toList(growable: false),
        invalidated: json['invalidated'] == true,
      );
    } catch (_) {
      return MemorySourceManifest(
        version: 0,
        originSessionId: json['originSessionId'] is String
            ? json['originSessionId'] as String
            : '',
        messages: const [],
        invalidated: true,
      );
    }
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'originSessionId': originSessionId,
    'messages': messages.map((m) => m.toJson()).toList(),
    'invalidated': invalidated,
  };

  @override
  bool operator ==(Object other) =>
      other is MemorySourceManifest &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

class MemorySourceStamp {
  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final String contentHash;

  const MemorySourceStamp({
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
    required this.contentHash,
  });

  factory MemorySourceStamp.capture(ChatMessage message) => MemorySourceStamp(
    messageId: message.id,
    swipeId: message.swipeId,
    agentSwipeId: message.agentSwipeId,
    contentHash: fingerprint(message),
  );

  static String fingerprint(ChatMessage message) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'role': message.role,
            'content': message.content,
            'time': message.time,
            'personaId': message.personaId,
            'personaName': message.personaName,
            'isHidden': message.isHidden,
            'imageHidden': message.imageHidden,
          }),
        ),
      )
      .toString();

  bool matches(ChatMessage message) =>
      MemorySourceManifest.eligible(message) &&
      message.id == messageId &&
      message.swipeId == swipeId &&
      message.agentSwipeId == agentSwipeId &&
      fingerprint(message) == contentHash;

  factory MemorySourceStamp.fromJson(Map<String, dynamic> json) =>
      MemorySourceStamp(
        messageId: json['messageId'] as String? ?? '',
        swipeId: (json['swipeId'] as num?)?.toInt() ?? -1,
        agentSwipeId: (json['agentSwipeId'] as num?)?.toInt() ?? -1,
        contentHash: json['contentHash'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'swipeId': swipeId,
    'agentSwipeId': agentSwipeId,
    'contentHash': contentHash,
  };
}
