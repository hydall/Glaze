import 'package:flutter/foundation.dart';

import '../../models/block_config.dart';

/// Which side of the conversation a block answers to.
///
/// The original extension gives every block two independent switches, so one
/// block may run after the user's message and after the character's. Blocks
/// saved before those switches existed carry only [BlockConfig.trigger]; for
/// them [BlockTrigger.afterUser] without [BlockConfig.triggerOnUser] still
/// means "after the user only", which is what the editor reads it as too.
extension BlockTriggerSides on BlockConfig {
  bool get _legacyUserOnly =>
      trigger == BlockTrigger.afterUser && !triggerOnUser;

  /// Runs after a user message.
  bool get runsOnUser =>
      trigger != BlockTrigger.periodic &&
      (triggerOnUser || trigger == BlockTrigger.afterUser);

  /// Runs after a character message.
  bool get runsOnChar =>
      trigger != BlockTrigger.periodic && !_legacyUserOnly && triggerOnChar;

  /// Runs on the side [trigger] names. [BlockTrigger.periodic] has no side.
  bool runsOn(BlockTrigger side) => switch (side) {
    BlockTrigger.afterUser => runsOnUser,
    BlockTrigger.afterAssistant => runsOnChar,
    BlockTrigger.periodic => trigger == BlockTrigger.periodic,
  };
}

/// Builds a [RegExp] from a keyword the way the original's `stringToRegex`
/// does: `/pattern/flags` is read as a JavaScript literal, anything else is
/// the pattern itself. Returns `null` for a pattern that does not compile.
///
/// JavaScript's `g` and `y` change how a regex is iterated, not what it
/// matches, so they have no counterpart here and are dropped. An unknown flag
/// makes the original ignore every flag, and so does this.
RegExp? upstreamStringToRegex(String source) {
  try {
    if (source.startsWith('/')) {
      final lastSlash = source.lastIndexOf('/');
      if (lastSlash > 0) {
        final pattern = source.substring(1, lastSlash);
        final flags = source.substring(lastSlash + 1);
        const valid = 'gimyus';
        if (flags.split('').any((f) => !valid.contains(f))) {
          return RegExp(pattern);
        }
        return RegExp(
          pattern,
          caseSensitive: !flags.contains('i'),
          multiLine: flags.contains('m'),
          dotAll: flags.contains('s'),
          unicode: flags.contains('u'),
        );
      }
    }
    return RegExp(source);
  } on FormatException catch (e) {
    debugPrint('[ExtBlocks] invalid keyword regex "$source": $e');
    return null;
  }
}

/// Whether [text] contains the block's keyword. A keyword that is not a valid
/// regex never matches.
bool blockKeywordMatches(BlockConfig block, String text) {
  if (block.keywordIsRegex) {
    return upstreamStringToRegex(block.keyword)?.hasMatch(text) ?? false;
  }
  return text.contains(block.keyword);
}

/// The original's per-message trigger condition, on top of the side check.
///
/// With a [BlockConfig.keyword] the block runs when the triggering message
/// contains it. Without one it runs every [BlockConfig.period] messages,
/// counted over the whole chat by [messageIndex] (the greeting is index 0):
/// a character message at an index divisible by the period, a user message at
/// one past such an index. With the default period of 2 in a chat that
/// alternates turns that is every message.
bool blockConditionsMet(
  BlockConfig block, {
  required int messageIndex,
  required bool isUser,
  required String messageText,
}) {
  if (block.keyword.isNotEmpty) {
    return blockKeywordMatches(block, messageText);
  }
  final period = block.period;
  if (period <= 0) return true;
  final index = isUser ? messageIndex - 1 : messageIndex;
  return index % period == 0;
}
