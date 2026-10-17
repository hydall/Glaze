/// Writes context items the way the original ExtBlocks extension does.
///
/// Reading needs no code of its own: [BlockContextItem] is serialized under the
/// original's field names, so its generated `fromJson` reads an exported item
/// directly. Writing does need code, because the original emits only the keys
/// its item type actually uses — a `previous_block` item must not come back
/// carrying message affixes it never had.
library;

import '../../../core/utils/id_generator.dart';
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

/// A fresh item of [type] with the original editor's defaults
/// (`EditorService.createContextItem`).
BlockContextItem newContextItem(ContextItemType type, {String? id}) =>
    BlockContextItem(
      id: id ?? generateId(),
      type: type,
      messagesCount: type == ContextItemType.lastMessages ? 10 : null,
    );

/// [item] switched to [type], keeping what both types share. Only the
/// last-messages item carries a count: the original tells the keyword and
/// by-block items apart by that key being absent.
BlockContextItem withContextType(BlockContextItem item, ContextItemType type) =>
    item.copyWith(
      type: type,
      messagesCount: type == ContextItemType.lastMessages
          ? (item.messagesCount ?? 10)
          : null,
    );

/// The original's context file: `{"items": [...]}`.
Map<String, dynamic> encodeContextItemsFile(List<BlockContextItem> items) => {
  'items': items.map(encodeUpstreamContextItem).toList(growable: false),
};

/// Reads the original's context file, or a bare array of items. Items the
/// original wrote before it assigned ids get one here, as its editor does on
/// load; anything that is not an item is skipped. Null when [decoded] holds no
/// item list at all.
List<BlockContextItem>? decodeContextItemsFile(Object? decoded) {
  final raw = decoded is Map ? decoded['items'] : decoded;
  if (raw is! List) return null;
  final items = <BlockContextItem>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final map = Map<String, dynamic>.from(entry);
    final id = map['id'];
    if (id is! String || id.isEmpty) map['id'] = generateId();
    try {
      items.add(BlockContextItem.fromJson(map));
    } catch (_) {
      continue;
    }
  }
  return items;
}
