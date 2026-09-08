import 'dart:convert';
import 'dart:typed_data';

const Map<int, String> _typeNames = {
  0x0000: '_meta',
  0x0004: 'character',
  0x0018: 'conversation',
  0x001c: 'model_setting',
  0x0024: 'endpoint',
  0x0028: 'persona_ref',
  0x0038: 'message',
  0x0040: 'chat_theme',
  0x0048: 'preset',
  0x0058: 'ltm_settings',
  0x0060: 'ltm',
  0x0064: 'regex',
  0x0068: 'regex_conversation_ref',
  0x006c: 'lorebook_entry',
  0x0080: 'lorebook',
  0x0084: 'lorebook_character_ref',
  0x00a0: 'ltm_conversation_ref',
  0x00c0: 'conversation_settings',
  0x00dc: 'ltm_settings_ref',
  0x00e0: 'message_metadata',
  0x00e4: 'vision_settings',
  0x00e8: 'vision_conversation_ref',
  0x00ec: 'ltm_personality',
  0x00f0: '_unknown_f0',
};

class _FieldDef {
  final int index;
  final String name;
  final String type;
  const _FieldDef(this.index, this.name, this.type);
}

class TavoField {
  final String type; // 'text' | 'json'
  final dynamic data;
  const TavoField(this.type, this.data);
}

class TavoEntry {
  final int entityId;
  final List<TavoField> fields;
  final Map<String, dynamic> structured;
  int? timestamp;
  int? characterId;
  int? conversationId;

  TavoEntry({
    required this.entityId,
    required this.fields,
    required this.structured,
  });
}

class TavoChatBlock {
  final List<TavoEntry> messages;
  final int? characterId;
  TavoChatBlock({required this.messages, required this.characterId});
}

class TavoData {
  final Map<String, List<TavoEntry>> categories;
  final List<TavoChatBlock> chats;
  TavoData({required this.categories, required this.chats});
}

const _characterFields = <_FieldDef>[
  _FieldDef(1, 'name', 'string'),
  _FieldDef(3, 'description', 'string'),
  _FieldDef(4, 'scenario', 'string'),
  _FieldDef(5, 'first_mes', 'string'),
  _FieldDef(6, 'mes_example', 'string'),
  _FieldDef(13, 'avatarPath', 'string'),
  _FieldDef(14, 'personality', 'string'),
  _FieldDef(15, 'system_prompt', 'string'),
  _FieldDef(25, 'alternate_greetings', 'string'),
  _FieldDef(27, 'source', 'string'),
  _FieldDef(20, 'updatedAt', 'int64'),
  _FieldDef(31, 'creationDate', 'int64'),
  _FieldDef(32, 'modificationDate', 'int64'),
  _FieldDef(34, 'sortIndex', 'int64'),
];

const _messageFields = <_FieldDef>[
  _FieldDef(1, 'characterId', 'int64'),
  _FieldDef(2, 'text', 'string'),
  _FieldDef(3, 'conversationId', 'int64'),
  _FieldDef(5, 'charName', 'string'),
  _FieldDef(6, 'avatarPath', 'string'),
  _FieldDef(7, 'timestamp', 'int64'),
];

const _conversationFields = <_FieldDef>[
  _FieldDef(2, 'createdAt', 'int64'),
  _FieldDef(3, 'updatedAt', 'int64'),
];

const _endpointFields = <_FieldDef>[
  _FieldDef(1, 'name', 'string'),
  _FieldDef(3, 'model', 'string'),
  _FieldDef(4, 'protocol', 'string'),
  _FieldDef(5, 'url', 'string'),
  _FieldDef(13, 'params_json', 'string'),
];

const _presetFields = <_FieldDef>[
  _FieldDef(1, 'name', 'string'),
  _FieldDef(2, 'updatedAt', 'int64'),
  _FieldDef(4, 'format_json', 'string'),
  _FieldDef(5, 'prompts_json', 'string'),
];

const _personaFields = <_FieldDef>[
  _FieldDef(1, 'avatarPath', 'string'),
  _FieldDef(3, 'name', 'string'),
];

const _lorebookFields = <_FieldDef>[
  _FieldDef(1, 'name', 'string'),
  _FieldDef(3, 'updatedAt', 'int64'),
];

const _regexFields = <_FieldDef>[
  _FieldDef(1, 'name', 'string'),
  _FieldDef(4, 'rules_json', 'string'),
];

const _ltmSettingsFields = <_FieldDef>[
  _FieldDef(1, 'summaryPrompt', 'string'),
  _FieldDef(2, 'injectionPrompt', 'string'),
  _FieldDef(3, 'injectionDepth', 'int64'),
  _FieldDef(4, 'maxTokens', 'int64'),
  _FieldDef(11, 'role', 'string'),
];

const _ltmFields = <_FieldDef>[
  _FieldDef(1, 'conversationId', 'int64'),
  _FieldDef(4, 'updatedAt', 'int64'),
];

const _structuredParsers = <String, List<_FieldDef>>{
  'character': _characterFields,
  'message': _messageFields,
  'conversation': _conversationFields,
  'endpoint': _endpointFields,
  'preset': _presetFields,
  'persona_ref': _personaFields,
  'lorebook': _lorebookFields,
  'regex': _regexFields,
  'ltm_settings': _ltmSettingsFields,
  'ltm': _ltmFields,
};

String? _readFieldString(Uint8List buf, int offset) {
  if (offset + 4 > buf.length) return null;
  final dv = ByteData.sublistView(buf);
  final strOffset = dv.getUint32(offset, Endian.little);
  if (strOffset < 4) return null;
  final strAbs = offset + strOffset;
  if (strAbs + 4 > buf.length) return null;
  final slen = dv.getUint32(strAbs, Endian.little);
  if (slen == 0) return '';
  if (slen > 1000000 || strAbs + 4 + slen > buf.length) return null;
  try {
    final raw = Uint8List.sublistView(buf, strAbs + 4, strAbs + 4 + slen);
    return _stripTrailingNulls(utf8.decode(raw, allowMalformed: true));
  } catch (_) {
    return null;
  }
}

List<String>? _readFieldStringVector(Uint8List buf, int offset) {
  if (offset + 4 > buf.length) return null;
  final dv = ByteData.sublistView(buf);
  final vecOffset = dv.getUint32(offset, Endian.little);
  if (vecOffset < 4) return null;
  final vecAbs = offset + vecOffset;
  if (vecAbs + 4 > buf.length) return null;
  final vlen = dv.getUint32(vecAbs, Endian.little);
  if (vlen > 100000 || vecAbs + 4 + vlen * 4 > buf.length) return null;
  final result = <String>[];
  for (var i = 0; i < vlen; i++) {
    final elemPos = vecAbs + 4 + i * 4;
    if (elemPos + 4 > buf.length) break;
    final elemOff = dv.getUint32(elemPos, Endian.little);
    if (elemOff < 4) break;
    final elemAbs = elemPos + elemOff;
    if (elemAbs + 4 > buf.length) break;
    final eslen = dv.getUint32(elemAbs, Endian.little);
    if (elemAbs + 4 + eslen > buf.length) break;
    try {
      final raw = Uint8List.sublistView(buf, elemAbs + 4, elemAbs + 4 + eslen);
      result.add(_stripTrailingNulls(utf8.decode(raw, allowMalformed: true)));
    } catch (_) {
      break;
    }
  }
  return result;
}

int? _readFieldInt64(Uint8List buf, int offset) {
  if (offset + 8 > buf.length) return null;
  return ByteData.sublistView(buf).getInt64(offset, Endian.little);
}

int? _readFieldInt32(Uint8List buf, int offset) {
  if (offset + 4 > buf.length) return null;
  return ByteData.sublistView(buf).getInt32(offset, Endian.little);
}

double? _readFieldFloat64(Uint8List buf, int offset) {
  if (offset + 8 > buf.length) return null;
  return ByteData.sublistView(buf).getFloat64(offset, Endian.little);
}

bool? _readFieldBool(Uint8List buf, int offset) {
  if (offset >= buf.length) return null;
  return buf[offset] != 0;
}

String _stripTrailingNulls(String s) {
  var end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0) {
    end--;
  }
  return end == s.length ? s : s.substring(0, end);
}

Map<String, dynamic> _parseObjectBoxEntity(
    Uint8List dataBuf, List<_FieldDef> fieldDefs) {
  if (dataBuf.length < 8) return {};
  final dv = ByteData.sublistView(dataBuf);

  final rootOffset = dv.getUint32(0, Endian.little);
  if (rootOffset < 4 || rootOffset >= dataBuf.length) return {};

  final tableStart = rootOffset;
  if (tableStart + 4 > dataBuf.length) return {};
  final soffset = dv.getInt32(tableStart, Endian.little);
  final vtableStart = tableStart - soffset;
  if (vtableStart < 0 || vtableStart + 4 > dataBuf.length) return {};

  final vtableSize = dv.getUint16(vtableStart, Endian.little);
  if (vtableSize < 4 || vtableSize > dataBuf.length) return {};
  final numFields = (vtableSize - 4) ~/ 2;

  final offsets = <int>[];
  for (var j = 0; j < numFields; j++) {
    final offPos = vtableStart + 4 + j * 2;
    if (offPos + 2 > dataBuf.length) break;
    offsets.add(dv.getUint16(offPos, Endian.little));
  }

  final result = <String, dynamic>{};
  for (final def in fieldDefs) {
    if (def.index >= offsets.length) continue;
    final fieldOffset = offsets[def.index];
    if (fieldOffset == 0) continue;

    final absPos = tableStart + fieldOffset;

    dynamic val;
    switch (def.type) {
      case 'string':
        val = _readFieldString(dataBuf, absPos);
        break;
      case 'string_vector':
        val = _readFieldStringVector(dataBuf, absPos);
        break;
      case 'int64':
        val = _readFieldInt64(dataBuf, absPos);
        break;
      case 'int32':
        val = _readFieldInt32(dataBuf, absPos);
        break;
      case 'float64':
        val = _readFieldFloat64(dataBuf, absPos);
        break;
      case 'bool':
        val = _readFieldBool(dataBuf, absPos);
        break;
      default:
        val = null;
    }
    if (val != null) {
      result[def.name] = val;
    }
  }
  return result;
}

List<TavoField> _extractStringsAndJson(Uint8List buf) {
  final items = <TavoField>[];
  final len = buf.length;
  var i = 0;

  while (i < len) {
    final b = buf[i];
    final isPrintable = b >= 32 || b == 10 || b == 13 || b == 9;
    if (isPrintable) {
      final start = i;
      while (i < len) {
        final c = buf[i];
        if (!(c >= 32 || c == 10 || c == 13 || c == 9)) break;
        i++;
      }
      try {
        final slice = Uint8List.sublistView(buf, start, i);
        final text = utf8.decode(slice, allowMalformed: true).trim();
        if (text.length < 2) continue;

        if (text.startsWith('[') || text.startsWith('{')) {
          try {
            final parsed = jsonDecode(text);
            items.add(TavoField('json', parsed));
            continue;
          } catch (_) {}
        }
        if (!text.contains('�')) {
          items.add(TavoField('text', text));
        }
      } catch (_) {}
    } else {
      i++;
    }
  }
  return items;
}

TavoData parseTavoLmdb(Uint8List buffer) {
  final dv = ByteData.sublistView(buffer);
  final bufLen = buffer.length;
  const pageSize = 4096;

  final categories = <String, Map<int, TavoEntry>>{};
  for (final name in _typeNames.values) {
    if (!name.startsWith('_')) categories[name] = <int, TavoEntry>{};
  }

  for (var pOffset = 0; pOffset < bufLen; pOffset += pageSize) {
    if (pOffset + 16 > bufLen) break;
    final flags = dv.getUint16(pOffset + 10, Endian.little);
    if ((flags & 0x02) != 0x02) continue;

    final lower = dv.getUint16(pOffset + 12, Endian.little);
    if (lower < 16 || lower > pageSize || pOffset + lower > bufLen) continue;

    final numNodes = (lower - 16) ~/ 2;
    if (numNodes <= 0 || numNodes > (pageSize - 16) ~/ 2) continue;

    for (var i = 0; i < numNodes; i++) {
      final nodePtrOff = pOffset + 16 + (i * 2);
      if (nodePtrOff + 2 > bufLen) break;

      final nodeOffset = dv.getUint16(nodePtrOff, Endian.little);
      if (nodeOffset == 0 || nodeOffset < 16 || nodeOffset >= pageSize) {
        continue;
      }

      final ptr = pOffset + nodeOffset;
      if (ptr + 16 > bufLen) continue;

      final mnDsize = dv.getUint32(ptr, Endian.little);
      final mnFlags = dv.getUint16(ptr + 4, Endian.little);
      final mnKsize = dv.getUint16(ptr + 6, Endian.little);

      if (mnKsize < 8 || ptr + 8 + mnKsize > bufLen) continue;
      if (buffer[ptr + 8] != 0x18) continue;

      final typeId = (buffer[ptr + 10] << 8) | buffer[ptr + 11];
      final typeName = _typeNames[typeId];
      if (typeName == null || typeName.startsWith('_')) continue;

      // entity_id is big-endian per JS (dv.getUint32(ptr + 12, false))
      final entityId = dv.getUint32(ptr + 12, Endian.big);

      Uint8List? dataBuffer;
      final keyOffset = ptr + 8;
      final dataOffset = keyOffset + mnKsize;

      if (mnFlags == 0) {
        if (dataOffset + mnDsize <= bufLen) {
          dataBuffer = Uint8List.sublistView(
              buffer, dataOffset, dataOffset + mnDsize);
        }
      } else if (mnFlags == 1) {
        if (dataOffset + 4 <= bufLen) {
          final pgno = dv.getUint32(dataOffset, Endian.little);
          final ovfOffset = pgno * pageSize;
          if (ovfOffset + 16 + mnDsize <= bufLen) {
            dataBuffer = Uint8List.sublistView(
                buffer, ovfOffset + 16, ovfOffset + 16 + mnDsize);
          }
        }
      }

      if (dataBuffer != null && dataBuffer.isNotEmpty) {
        final structured = _structuredParsers.containsKey(typeName)
            ? _parseObjectBoxEntity(dataBuffer, _structuredParsers[typeName]!)
            : <String, dynamic>{};
        final fields = _extractStringsAndJson(dataBuffer);
        final entry = TavoEntry(
          entityId: entityId,
          fields: fields,
          structured: structured,
        );

        if (typeName == 'message') {
          entry.timestamp = structured['timestamp'] as int?;
          entry.characterId = structured['characterId'] as int?;
          entry.conversationId = structured['conversationId'] as int?;
        }

        categories[typeName]![entityId] = entry;
      }
    }
  }

  final flatCategories = <String, List<TavoEntry>>{
    for (final e in categories.entries) e.key: e.value.values.toList(),
  };

  final chats = _groupMessagesIntoChats(flatCategories);
  return TavoData(categories: flatCategories, chats: chats);
}

List<TavoChatBlock> _groupMessagesIntoChats(
    Map<String, List<TavoEntry>> categories) {
  final chats = <TavoChatBlock>[];
  final messages = categories['message'];
  if (messages == null || messages.isEmpty) return chats;

  final byConv = <int, List<TavoEntry>>{};
  final orphansByChar = <int, List<TavoEntry>>{};

  for (final msg in messages) {
    final convId = msg.conversationId ?? msg.structured['conversationId'] as int?;
    final charId = msg.characterId ?? msg.structured['characterId'] as int?;
    if (convId != null && convId != 0) {
      (byConv[convId] ??= []).add(msg);
    } else if (charId != null && charId != 0) {
      (orphansByChar[charId] ??= []).add(msg);
    }
  }

  int sortKey(TavoEntry m) => m.timestamp ?? m.entityId;

  for (final entry in byConv.entries) {
    final convId = entry.key;
    final msgs = entry.value;
    msgs.sort((a, b) => sortKey(a).compareTo(sortKey(b)));

    int? charId;
    for (final m in msgs) {
      final cid = m.characterId ?? m.structured['characterId'] as int?;
      if (cid != null && cid != 0) {
        charId = cid;
        break;
      }
    }
    if (charId == null) {
      final convList = categories['conversation'];
      if (convList != null) {
        final conv = convList.firstWhere(
          (c) => c.entityId == convId,
          orElse: () => TavoEntry(entityId: -1, fields: [], structured: {}),
        );
        final convChars = conv.structured['characters'];
        if (convChars is List) {
          for (final v in convChars) {
            final n = v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0;
            if (n != 0) {
              charId = n;
              break;
            }
          }
        }
      }
    }
    if (charId != null && orphansByChar.containsKey(charId)) {
      msgs.addAll(orphansByChar[charId]!);
      orphansByChar.remove(charId);
      msgs.sort((a, b) => sortKey(a).compareTo(sortKey(b)));
    }

    chats.add(TavoChatBlock(messages: msgs, characterId: charId));
  }

  for (final entry in orphansByChar.entries) {
    final msgs = entry.value;
    msgs.sort((a, b) => sortKey(a).compareTo(sortKey(b)));
    chats.add(TavoChatBlock(messages: msgs, characterId: entry.key));
  }

  return chats;
}
