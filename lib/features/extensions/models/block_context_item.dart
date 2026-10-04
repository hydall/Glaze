import 'package:freezed_annotation/freezed_annotation.dart';

part 'block_context_item.freezed.dart';
part 'block_context_item.g.dart';

/// Where one context item's text lands in the block's request.
enum ContextItemRole {
  @JsonValue('user')
  user,
  @JsonValue('system')
  system,
  @JsonValue('assistant')
  assistant,
}

/// What a context item pulls in.
enum ContextItemType {
  /// Free text. Supports macros.
  @JsonValue('text')
  text,

  /// The last N visible messages before the anchor.
  @JsonValue('last_messages')
  lastMessages,

  /// Visible messages back to the last one containing a keyword.
  @JsonValue('last_messages_keyword')
  lastMessagesKeyword,

  /// Visible messages back to the last one carrying a named block.
  @JsonValue('last_messages_by_block')
  lastMessagesByBlock,

  /// Earlier stored states of a named block.
  @JsonValue('previous_block')
  previousBlock,
}

/// What goes between messages when an item renders several of them.
enum MessagesSeparator {
  @JsonValue('double_newline')
  doubleNewline,
  @JsonValue('newline')
  newline,
  @JsonValue('space')
  space,
}

extension MessagesSeparatorX on MessagesSeparator {
  /// The literal string inserted between rendered messages.
  String get text => switch (this) {
    MessagesSeparator.doubleNewline => '\n\n',
    MessagesSeparator.newline => '\n',
    MessagesSeparator.space => ' ',
  };
}

/// One entry in a block's ordered context list.
///
/// Field names are serialized exactly as the original ExtBlocks extension
/// writes them, so a context array exported there can be read back here — and
/// ours re-read there — without a translation step. That is also why every
/// type-specific field lives on one flat object instead of a sealed union:
/// the original stores a single shape and omits the keys a given type does not
/// use, and an omitted key has to stay omitted on the way out.
@freezed
abstract class BlockContextItem with _$BlockContextItem {
  const factory BlockContextItem({
    required String id,

    /// Shown in the item list, and used to group blocks that share a context
    /// into a single request.
    @Default('') String name,
    @Default(ContextItemRole.user) ContextItemRole role,
    @Default(ContextItemType.text) ContextItemType type,

    /// Kept in the list but skipped when the context is assembled.
    @Default(false) bool disabled,

    /// [ContextItemType.text] only.
    @Default('') String text,

    /// [ContextItemType.lastMessages] only. Positive counts back from the
    /// anchor, negative takes that many from the start of the chat instead.
    ///
    /// Null for the keyword and by-block variants, which derive their own
    /// count — the original tells those apart by this key being absent.
    @JsonKey(name: 'messages_count', includeIfNull: false) int? messagesCount,

    /// How many of the newest messages to drop before counting.
    @JsonKey(name: 'messages_offset') @Default(0) int messagesOffset,
    @JsonKey(name: 'messages_separator')
    @Default(MessagesSeparator.doubleNewline)
    MessagesSeparator messagesSeparator,
    @JsonKey(name: 'user_prefix') @Default('') String userPrefix,
    @JsonKey(name: 'user_suffix') @Default('') String userSuffix,
    @JsonKey(name: 'char_prefix') @Default('') String charPrefix,
    @JsonKey(name: 'char_suffix') @Default('') String charSuffix,

    /// [ContextItemType.lastMessagesKeyword] only: stop once this string is
    /// seen in a message.
    @JsonKey(name: 'keyword_stopper') @Default('') String keywordStopper,

    /// Block to look for — the anchor block for
    /// [ContextItemType.lastMessagesByBlock], the source block for
    /// [ContextItemType.previousBlock].
    @JsonKey(name: 'block_name') @Default('') String blockName,

    /// [ContextItemType.previousBlock] only: how many earlier states to pull.
    @JsonKey(name: 'block_count') @Default(1) int blockCount,
  }) = _BlockContextItem;

  factory BlockContextItem.fromJson(Map<String, dynamic> json) =>
      _$BlockContextItemFromJson(json);
}
