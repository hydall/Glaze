import 'dart:convert';

import 'package:crypto/crypto.dart';

const String cacheBreakpointModeDepth = 'depth';
const String cacheBreakpointModeStablePrefix = 'stable_prefix';

/// Adds one `cache_control` marker to the last content block that is identical
/// between the previous and current request prefixes.
///
/// This is useful when recent turns contain volatile injected blocks: instead
/// of assuming a fixed depth from the end, it finds the actual shared prefix.
List<Map<String, dynamic>> markStablePrefixCacheControl(
  List<Map<String, dynamic>> current,
  List<Map<String, dynamic>>? previous, {
  required String ttl,
}) {
  if (previous == null || previous.isEmpty || current.isEmpty) return current;

  final out = current
      .map((m) => Map<String, dynamic>.from(m))
      .toList(growable: true);
  final currentBlocks = _flatten(out);
  final previousBlocks = _flatten(previous);
  final max = currentBlocks.length < previousBlocks.length
      ? currentBlocks.length
      : previousBlocks.length;

  _CacheBlock? lastCommon;
  for (var i = 0; i < max; i++) {
    if (currentBlocks[i].hash != previousBlocks[i].hash) break;
    if (_canMark(currentBlocks[i].part)) {
      lastCommon = currentBlocks[i];
    }
  }
  if (lastCommon == null) return out;

  final message = out[lastCommon.messageIndex];
  final cacheControl = <String, dynamic>{
    'type': 'ephemeral',
    if (ttl == '1h') 'ttl': '1h',
  };
  final content = message['content'];
  if (content is String) {
    message['content'] = [
      {'type': 'text', 'text': content, 'cache_control': cacheControl},
    ];
  } else if (content is List && lastCommon.partIndex < content.length) {
    final mutable = content.cast<dynamic>().toList();
    final part = mutable[lastCommon.partIndex];
    if (part is Map) {
      final updated = Map<String, dynamic>.from(part);
      updated['cache_control'] = cacheControl;
      mutable[lastCommon.partIndex] = updated;
      message['content'] = mutable;
    }
  }
  return out;
}

List<_CacheBlock> _flatten(List<Map<String, dynamic>> messages) {
  final blocks = <_CacheBlock>[];
  for (var messageIndex = 0; messageIndex < messages.length; messageIndex++) {
    final message = messages[messageIndex];
    final role = message['role'];
    final content = message['content'];
    if (content is String) {
      blocks.add(
        _CacheBlock(
          messageIndex: messageIndex,
          partIndex: 0,
          part: {'type': 'text', 'text': content},
          hash: _hash({'role': role, 'type': 'text', 'text': content}),
        ),
      );
    } else if (content is List) {
      for (var partIndex = 0; partIndex < content.length; partIndex++) {
        final part = content[partIndex];
        blocks.add(
          _CacheBlock(
            messageIndex: messageIndex,
            partIndex: partIndex,
            part: part,
            hash: _hash({'role': role, 'part': _stripCacheControl(part)}),
          ),
        );
      }
    }
  }
  return blocks;
}

bool _canMark(dynamic part) {
  if (part is! Map) return false;
  if (part['type'] == 'text') {
    final text = part['text'];
    return text is String && text.trim().isNotEmpty;
  }
  return true;
}

dynamic _stripCacheControl(dynamic value) {
  if (value is Map) {
    return {
      for (final key in value.keys.map((k) => k.toString()).toList()..sort())
        if (key != 'cache_control') key: _stripCacheControl(value[key]),
    };
  }
  if (value is List) return value.map(_stripCacheControl).toList();
  return value;
}

String _hash(dynamic value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

class _CacheBlock {
  final int messageIndex;
  final int partIndex;
  final dynamic part;
  final String hash;

  const _CacheBlock({
    required this.messageIndex,
    required this.partIndex,
    required this.part,
    required this.hash,
  });
}
