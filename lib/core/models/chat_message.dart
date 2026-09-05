import 'package:freezed_annotation/freezed_annotation.dart';

part 'chat_message.freezed.dart';
part 'chat_message.g.dart';

/// How many images one message may carry. The composer stops accepting
/// attachments at this many, and the WebView lays them out as a grid up to
/// exactly this count — raising it needs a matching grid case in
/// `assets/chat_webview/renderer/image_embed.js` and `styles.css`.
const int maxMessageAttachments = 4;

class TriggeredEntry {
  final String id;
  final String name;
  final String lorebookName;
  final String lorebookId;
  final String source;

  /// Raw regex pattern for `source == 'regex'` entries. Empty for a
  /// trim-out-only script (rendered as "Trim Out" in the triggered sheet).
  final String pattern;

  const TriggeredEntry({
    required this.id,
    required this.name,
    this.lorebookName = '',
    this.lorebookId = '',
    this.source = 'keyword',
    this.pattern = '',
  });

  factory TriggeredEntry.fromJson(Map<String, dynamic> json) => TriggeredEntry(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    lorebookName: json['lorebookName'] as String? ?? '',
    lorebookId: json['lorebookId'] as String? ?? '',
    source: json['source'] as String? ?? 'keyword',
    pattern: json['pattern'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'lorebookName': lorebookName,
    'lorebookId': lorebookId,
    'source': source,
    'pattern': pattern,
  };
}

/// A nested swipe variation produced by the Studio pipeline (POST-cleaner
/// rewrite, final-regen, etc.). Stored as a colour-coded sub-swipe under a
/// [ChatMessage]; `kind` drives the WebView colour coding ('cleaned' = blue,
/// 'final' = white). `parentSwipeId` links a sub-swipe to its parent green
/// swipe index for diffing.
class AgentSwipe {
  final String content;
  final String kind;
  final String? reasoning;
  final String? genTime;
  final int? tokens;
  final String? time;
  final List<Map<String, dynamic>> studioOutputs;
  final int? parentSwipeId;

  const AgentSwipe({
    required this.content,
    this.kind = 'final',
    this.reasoning,
    this.genTime,
    this.tokens,
    this.time,
    this.studioOutputs = const [],
    this.parentSwipeId,
  });

  factory AgentSwipe.fromJson(Map<String, dynamic> json) => AgentSwipe(
    content: json['content'] as String? ?? '',
    kind: json['kind'] as String? ?? 'final',
    reasoning: json['reasoning'] as String?,
    genTime: json['genTime'] as String?,
    tokens: json['tokens'] as int?,
    time: json['time'] as String?,
    studioOutputs:
        (json['studioOutputs'] as List?)
            ?.whereType<Map<dynamic, dynamic>>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const [],
    parentSwipeId: json['parentSwipeId'] as int?,
  );

  Map<String, dynamic> toJson() => {
    'content': content,
    'kind': kind,
    'reasoning': reasoning,
    'genTime': genTime,
    'tokens': tokens,
    'time': time,
    'studioOutputs': studioOutputs,
    'parentSwipeId': parentSwipeId,
  };

  AgentSwipe copyWith({
    String? content,
    String? kind,
    String? reasoning,
    String? genTime,
    int? tokens,
    String? time,
    List<Map<String, dynamic>>? studioOutputs,
    int? parentSwipeId,
  }) => AgentSwipe(
    content: content ?? this.content,
    kind: kind ?? this.kind,
    reasoning: reasoning ?? this.reasoning,
    genTime: genTime ?? this.genTime,
    tokens: tokens ?? this.tokens,
    time: time ?? this.time,
    studioOutputs: studioOutputs ?? this.studioOutputs,
    parentSwipeId: parentSwipeId ?? this.parentSwipeId,
  );
}

@freezed
abstract class ChatMessage with _$ChatMessage {
  const factory ChatMessage({
    required String id,
    required String role,
    required String content,
    int? timestamp,
    String? personaId,
    String? personaName,

    /// First attachment. Kept as its own field so sessions written before
    /// multi-attach — and every reader that only knows this one — keep
    /// working; attachments 2..N live in [extraImagePaths]. Read
    /// [ChatMessageAttachments.attachments] instead of either field.
    String? imagePath,

    /// Attachments after the first, in the order they were attached. Empty on
    /// a single-image message.
    @Default([]) List<String> extraImagePaths,

    /// Attachment visibility for the LLM. `false` (the default) means the
    /// images travel with the message in the prompt; the eye toggle on the
    /// bubble flips it so they stay visible in the chat but are dropped from
    /// the request (see [HistoryAssembler.assemble]). One flag covers every
    /// attachment on the message.
    @Default(false) bool imageHidden,
    @Default([]) List<String> swipes,
    @Default(0) int swipeId,
    String? reasoning,
    @Default(false) bool isAllReasoning,
    @Default(false) bool isHidden,
    @Default(false) bool isError,
    String? genTime,
    int? tokens,
    int? greetingIndex,
    @Default([]) List<String> contextRefs,
    @Default('none') String swipeDirection,
    @Default(false) bool isEditing,
    @Default(false) bool isTyping,
    String? guidanceText,
    @Default('GENERATION') String guidanceType,
    @Default([]) List<TriggeredEntry> triggeredLorebooks,
    @Default([]) List<TriggeredEntry> triggeredMemories,
    @Default([]) List<Map<String, dynamic>> swipesMeta,
    @Default([]) List<Map<String, dynamic>> studioOutputs,
    @Default([]) List<AgentSwipe> agentSwipes,
    @Default(0) int agentSwipeId,
    @Default({}) Map<String, dynamic> memoryCoverage,
    String? time,
  }) = _ChatMessage;

  factory ChatMessage.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageFromJson(json);
}

/// The attachments of a message as one list, whichever field they were stored
/// in. Everything that renders or sends attachments reads this — the split
/// between [ChatMessage.imagePath] and [ChatMessage.extraImagePaths] exists
/// only so old sessions keep rendering.
extension ChatMessageAttachments on ChatMessage {
  List<String> get attachments => [
    if (imagePath?.isNotEmpty == true) imagePath!,
    for (final path in extraImagePaths)
      if (path.isNotEmpty) path,
  ];

  bool get hasAttachments => attachments.isNotEmpty;
}

/// Splits [paths] across the two storage fields of [ChatMessage].
({String? imagePath, List<String> extraImagePaths}) splitAttachments(
  List<String> paths,
) {
  final kept = paths.where((p) => p.isNotEmpty).toList(growable: false);
  if (kept.isEmpty) return (imagePath: null, extraImagePaths: const []);
  return (
    imagePath: kept.first,
    extraImagePaths: kept.skip(1).toList(growable: false),
  );
}

@freezed
abstract class AuthorsNote with _$AuthorsNote {
  const factory AuthorsNote({
    @Default('') String content,
    @Default('system') String role,
    @Default('relative') String insertionMode,
    @Default(0) int depth,
    @Default(true) bool enabled,
  }) = _AuthorsNote;

  factory AuthorsNote.fromJson(Map<String, dynamic> json) =>
      _$AuthorsNoteFromJson(json);
}

@freezed
abstract class ChatSummary with _$ChatSummary {
  const factory ChatSummary({
    @Default('') String content,
    @Default('system') String role,
    @Default('relative') String insertionMode,
    @Default(4) int depth,
    @Default('Summary: ') String prefix,
  }) = _ChatSummary;

  factory ChatSummary.fromJson(Map<String, dynamic> json) =>
      _$ChatSummaryFromJson(json);
}

@freezed
abstract class ChatSession with _$ChatSession {
  const factory ChatSession({
    required String id,
    required String characterId,
    required int sessionIndex,
    @Default([]) List<ChatMessage> messages,
    @Default(0) int updatedAt,
    @Default({}) Map<String, String> sessionVars,
    AuthorsNote? authorsNote,
    ChatSummary? summary,
    String? draft,
    @Default({}) Map<String, dynamic> lastScrollAnchor,
  }) = _ChatSession;

  factory ChatSession.fromJson(Map<String, dynamic> json) =>
      _$ChatSessionFromJson(json);
}

class SessionMetadata {
  final String sessionId;
  final String characterId;
  final int sessionIndex;
  final int updatedAt;
  final int messageCount;
  final String lastMessageContent;
  final int lastMessageTimestamp;
  final String? sessionName;

  /// Origin event timestamp (ms) — branch time, else creation time. 0 when
  /// unknown. Kept separate from [lastMessageTimestamp] so it can drive the
  /// list preview/sort without perturbing the cloud-sync metadata hash.
  final int originTimestamp;

  /// 'branched' or 'created' when [originTimestamp] > 0, else null.
  final String? originKind;

  const SessionMetadata({
    required this.sessionId,
    required this.characterId,
    required this.sessionIndex,
    required this.updatedAt,
    required this.messageCount,
    required this.lastMessageContent,
    required this.lastMessageTimestamp,
    this.sessionName,
    this.originTimestamp = 0,
    this.originKind,
  });
}

/// How a [ChatSession] came into being — used for the "Created on" /
/// "Branched on" origin marker shown as a chat separator and in the session
/// list preview.
enum ChatOriginKind { created, branched }

/// The origin event of a [ChatSession]: its kind and the moment it happened,
/// in milliseconds since epoch (matching [ChatMessage.timestamp]).
class ChatOriginEvent {
  final ChatOriginKind kind;
  final int timestampMs;

  const ChatOriginEvent({required this.kind, required this.timestampMs});
}

extension ChatSessionX on ChatSession {
  /// Reserved [sessionVars] key holding the cumulative number of messages
  /// deleted from this session through any per-message delete path (single
  /// delete, bulk delete). Persisted here so the count survives the messages
  /// themselves being removed. It is intentionally *not* bumped when the whole
  /// chat/session is deleted — that removes the session (and this counter)
  /// along with it, so chat-deletion is excluded from the "Deleted" statistic.
  static const deletedMessagesVarKey = '__deletedMessages';

  /// Cumulative count of messages deleted from this session. See
  /// [deletedMessagesVarKey].
  int get deletedMessageCount =>
      int.tryParse(sessionVars[deletedMessagesVarKey] ?? '') ?? 0;

  String get historyText => messages
      .where((m) => (m.role == 'user' || m.role == 'assistant') && !m.isHidden)
      .map((m) => m.content)
      .join('\n');

  /// Branch time (ms) when this session was created via Branch, else null.
  /// Stored as a reserved `branchedAt` session var (see `branchSession`).
  int? get branchedAtMs {
    final raw = sessionVars['branchedAt'];
    if (raw == null) return null;
    final v = int.tryParse(raw);
    return (v != null && v > 0) ? v : null;
  }

  /// The session's origin event: a branch stamp when present, otherwise the
  /// creation time inferred from the first message. Null when no usable
  /// timestamp exists (legacy sessions with untimestamped messages).
  ChatOriginEvent? get originEvent {
    final branched = branchedAtMs;
    if (branched != null) {
      return ChatOriginEvent(
        kind: ChatOriginKind.branched,
        timestampMs: branched,
      );
    }
    final firstTs = messages.isNotEmpty ? messages.first.timestamp : null;
    if (firstTs != null && firstTs > 0) {
      return ChatOriginEvent(
        kind: ChatOriginKind.created,
        timestampMs: firstTs,
      );
    }
    return null;
  }

  /// Last activity time (ms) used to order the session list: the newest of the
  /// stored `updatedAt` (seconds → ms), the last message timestamp, and the
  /// origin event. Lets branch/creation bump a session to the top even when no
  /// message has been sent yet.
  int get lastActivityMs {
    final updated = updatedAt > 0 ? updatedAt * 1000 : 0;
    final lastMsg = messages.isNotEmpty ? (messages.last.timestamp ?? 0) : 0;
    final origin = originEvent?.timestampMs ?? 0;
    var best = updated;
    if (lastMsg > best) best = lastMsg;
    if (origin > best) best = origin;
    return best;
  }
}
