/// Writes context items the way the original ExtBlocks extension does.
///
/// Reading needs no code of its own: [BlockContextItem] is serialized under the
/// original's field names, so its generated `fromJson` reads an exported item
/// directly. Writing does need code, because the original emits only the keys
/// its item type actually uses — a `previous_block` item must not come back
/// carrying message affixes it never had.
library;

import '../models/block_context_item.dart';

String upstreamContextTypeValue(ContextItemType type) => switch (type) {
  ContextItemType.text => 'text',
  ContextItemType.lastMessages => 'last_messages',
  ContextItemType.lastMessagesKeyword => 'last_messages_keyword',
  ContextItemType.lastMessagesByBlock => 'last_messages_by_block',
  ContextItemType.previousBlock => 'previous_block',
};

String upstreamSeparatorValue(MessagesSeparator separator) => switch (separator) {
  MessagesSeparator.doubleNewline => 'double_newline',
  MessagesSeparator.newline => 'newline',
  MessagesSeparator.space => 'space',
};

/// Per-message affixes, shared by the three message-slice item types.
Map<String, dynamic> _messageAffixes(BlockContextItem item) => {
  'messages_separator': upstreamSeparatorValue(item.messagesSeparator),
  'user_prefix': item.userPrefix,
  'user_suffix': item.userSuffix,
  'char_prefix': item.charPrefix,
  'char_suffix': item.charSuffix,
};

Map<String, dynamic> encodeUpstreamContextItem(BlockContextItem item) {
  final base = <String, dynamic>{
    'id': item.id,
    'name': item.name,
    'role': item.role.name,
    'type': upstreamContextTypeValue(item.type),
    'disabled': item.disabled,
  };

  return switch (item.type) {
    ContextItemType.text => {...base, 'text': item.text},
    ContextItemType.lastMessages => {
      ...base,
      'messages_count': item.messagesCount ?? 10,
      'messages_offset': item.messagesOffset,
      ..._messageAffixes(item),
    },
    ContextItemType.lastMessagesKeyword => {
      ...base,
      'keyword_stopper': item.keywordStopper,
      ..._messageAffixes(item),
    },
    ContextItemType.lastMessagesByBlock => {
      ...base,
      'block_name': item.blockName,
      ..._messageAffixes(item),
    },
    ContextItemType.previousBlock => {
      ...base,
      'block_name': item.blockName,
      'block_count': item.blockCount,
    },
  };
}
