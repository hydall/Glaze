import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'chat_message.dart';

enum MemorySourceValidity { verified, unverified, invalid }

/// Why one source of a draft cannot be captured: the message is gone from
/// the chat, or [MemorySourceManifest.eligible] refuses it. A hidden message
/// is no problem — the draft skips it — unless every source is hidden
/// ([allHidden]), when there is nothing left to retell.
enum MemorySourceProblemKind { deleted, allHidden, error, empty }

/// A source [MemorySourceManifest.capture] would refuse, by its position in
/// the chat (1-based, every message counted) so the reader can find it. A
/// deleted source has no position and carries 0.
class MemorySourceProblem {
  final int position;
  final MemorySourceProblemKind kind;

  const MemorySourceProblem({required this.position, required this.kind});

  @override
  bool operator ==(Object other) =>
      other is MemorySourceProblem &&
      other.position == position &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(position, kind);

  @override
  String toString() => 'MemorySourceProblem(#$position ${kind.name})';
}

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

  /// [expectedIds] less the messages of [chat] that are hidden: what a
  /// draft retells. A hidden message is the reader's choice to keep it out of
  /// the story, so the draft skips it, as the transcript does, rather than
  /// refuse the whole range.
  static List<String> withoutHidden(
    List<String> expectedIds,
    List<ChatMessage> chat,
  ) {
    final hidden = {
      for (final message in chat)
        if (message.isHidden) message.id,
    };
    return [
      for (final id in expectedIds)
        if (!hidden.contains(id)) id,
    ];
  }

  static bool eligible(ChatMessage message) =>
      !message.isHidden &&
      !message.isTyping &&
      !message.isError &&
      message.content.trim().isNotEmpty &&
      (message.role == 'user' || message.role == 'assistant');

  /// Every source among [expectedIds] that [capture] would refuse, in chat
  /// order: a deleted message sorts last, having no position of its own.
  /// Empty when the draft can be captured from [chat] as it stands. A draft
  /// is planned over the messages of its day; a hidden one is skipped (see
  /// [withoutHidden]), but one emptied, deleted or turned into an error
  /// bubble since is not — the memory would then hold a gap — and is named,
  /// so the reader can put it right. A range hidden whole has nothing to
  /// retell and is one [MemorySourceProblemKind.allHidden] problem.
  static List<MemorySourceProblem> problems(
    List<String> expectedIds,
    List<ChatMessage> chat,
  ) {
    final position = {for (var i = 0; i < chat.length; i++) chat[i].id: i};
    final found = <MemorySourceProblem>[];
    var deleted = 0;
    var shown = 0;
    var hidden = 0;
    for (final id in expectedIds) {
      final at = position[id];
      if (at == null) {
        deleted++;
        continue;
      }
      final message = chat[at];
      if (message.isHidden) {
        hidden++;
        continue;
      }
      shown++;
      final MemorySourceProblemKind kind;
      if (message.isError) {
        kind = MemorySourceProblemKind.error;
      } else if (message.isTyping ||
          message.content.trim().isEmpty ||
          (message.role != 'user' && message.role != 'assistant')) {
        kind = MemorySourceProblemKind.empty;
      } else {
        continue;
      }
      found.add(MemorySourceProblem(position: at + 1, kind: kind));
    }
    if (hidden > 0 && shown == 0 && deleted == 0) {
      return const [
        MemorySourceProblem(
          position: 0,
          kind: MemorySourceProblemKind.allHidden,
        ),
      ];
    }
    found.sort((a, b) => a.position.compareTo(b.position));
    for (var i = 0; i < deleted; i++) {
      found.add(
        const MemorySourceProblem(
          position: 0,
          kind: MemorySourceProblemKind.deleted,
        ),
      );
    }
    return found;
  }

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
