/// Assembles a block's request from its ordered [BlockConfig.context] list.
///
/// This is the runtime half of the original ExtBlocks "Context Builder": the
/// ordered items (free text, message slices, a previous block's state) become
/// the messages the model sees. Items that share a role are merged into one
/// message, exactly as the original does, and every chat message pulled in is
/// run through the prompt regex pass with its own depth.
library;

import '../../../../core/llm/regex_service.dart';
import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/persona.dart';
import '../../../../core/models/preset.dart';
import '../../../image_gen/services/image_tag_markup.dart';
import '../../models/block_config.dart';
import '../../models/block_context_item.dart';
import '../../models/info_block.dart';
import '../macro_expander.dart';

/// One message produced for a block request: `{'role': ..., 'content': ...}`.
typedef ContextItemMessage = Map<String, dynamic>;

/// Builds the ordered request messages for [blockConfig] from its context
/// items.
///
/// [messages] is the session history in order; counts and offsets are relative
/// to [anchorMessageId] (inclusive), mirroring the original's
/// `chat.slice(0, messageId + 1)`. [blocksByMessageId] is every stored block
/// keyed by the message that owns it, used by the two item types that read
/// earlier block state.
///
/// Returns an empty list when no enabled item produces content.
List<ContextItemMessage> buildContextItemMessages({
  required BlockConfig blockConfig,
  required List<ChatMessage> messages,
  required String anchorMessageId,
  required Character? character,
  required Persona? persona,
  required Map<String, String> sessionVars,
  required Map<String, String> globalVars,
  required List<PresetRegex> promptRegexes,
  required Map<String, List<InfoBlock>> blocksByMessageId,
  int pauseCounter = 0,
}) {
  final anchorIndex = messages.indexWhere((m) => m.id == anchorMessageId);
  final upToAnchor = anchorIndex < 0
      ? List<ChatMessage>.from(messages)
      : messages.sublist(0, anchorIndex + 1);

  final builder = _ContextItemBuilder(
    messages: messages,
    upToAnchor: upToAnchor,
    anchorIndex: anchorIndex < 0 ? messages.length - 1 : anchorIndex,
    character: character,
    persona: persona,
    sessionVars: sessionVars,
    globalVars: globalVars,
    promptRegexes: promptRegexes,
    blocksByMessageId: blocksByMessageId,
    pauseCounter: pauseCounter,
  );

  final out = <ContextItemMessage>[];
  String? currentRole;
  final group = <String>[];

  void flush() {
    if (group.isEmpty) return;
    out.add({'role': currentRole ?? 'user', 'content': group.join('\n')});
    group.clear();
  }

  for (final item in blockConfig.context) {
    if (item.disabled) continue;
    final content = builder.contentFor(item);
    if (content == null || content.isEmpty) continue;

    final role = item.role.name;
    if (role != currentRole) {
      flush();
      currentRole = role;
    }
    group.add(content);
  }
  flush();

  return out;
}

class _ContextItemBuilder {
  const _ContextItemBuilder({
    required this.messages,
    required this.upToAnchor,
    required this.anchorIndex,
    required this.character,
    required this.persona,
    required this.sessionVars,
    required this.globalVars,
    required this.promptRegexes,
    required this.blocksByMessageId,
    required this.pauseCounter,
  });

  final List<ChatMessage> messages;
  final List<ChatMessage> upToAnchor;
  final int anchorIndex;
  final Character? character;
  final Persona? persona;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;
  final List<PresetRegex> promptRegexes;
  final Map<String, List<InfoBlock>> blocksByMessageId;
  final int pauseCounter;

  String? contentFor(BlockContextItem item) {
    switch (item.type) {
      case ContextItemType.text:
        return _expand(item.text);
      case ContextItemType.lastMessages:
      case ContextItemType.lastMessagesKeyword:
        return _lastMessages(item);
      case ContextItemType.lastMessagesByBlock:
        return _lastMessagesByBlock(item);
      case ContextItemType.previousBlock:
        return _previousBlock(item);
    }
  }

  String _expand(String text) {
    if (text.isEmpty) return text;
    return expand(
      text,
      MacroContext(
        character: character,
        persona: persona?.name,
        personaDescription: persona?.prompt,
      ),
    );
  }

  /// Chat visible to context items: hidden, typing and failed messages are
  /// skipped, matching the original's `is_system` filter in spirit.
  List<ChatMessage> get _visible => upToAnchor
      .where(
        (m) =>
            !m.isHidden &&
            !m.isTyping &&
            !m.isError &&
            m.content.trim().isNotEmpty,
      )
      .toList();

  String _lastMessages(BlockContextItem item) {
    var working = _visible;
    final offset = item.messagesOffset;
    if (offset > 0 && working.length > offset) {
      working = working.sublist(0, working.length - offset);
    }
    if (working.isEmpty) return '';

    var count = item.messagesCount;
    if (count == null) {
      // No explicit count: this is a keyword slice, or it produces nothing —
      // the original tells the two apart by this key being absent.
      final stopper = item.keywordStopper;
      if (stopper.isEmpty) return '';
      final searchEnd = pauseCounter > 0
          ? (working.length - pauseCounter - 1).clamp(0, working.length)
          : working.length - 1;
      var lastMatch = -1;
      for (var i = searchEnd - 1; i >= 0; i--) {
        if (working[i].content.contains(stopper)) {
          lastMatch = i;
          break;
        }
      }
      if (lastMatch < 0) lastMatch = 0;
      count = working.length - lastMatch;
    }

    final slice = _slice(working, count);
    if (slice.isEmpty) return '';
    return _formatSlice(slice, item, count);
  }

  List<ChatMessage> _slice(List<ChatMessage> working, int count) {
    if (count > 0) {
      final start = (working.length - count).clamp(0, working.length);
      return working.sublist(start);
    }
    if (count < 0) {
      final end = (-count).clamp(0, working.length);
      return working.sublist(0, end);
    }
    return const [];
  }

  String _lastMessagesByBlock(BlockContextItem item) {
    if (item.blockName.isEmpty) return '';
    final visible = _visible;
    if (visible.isEmpty) return '';

    var lastBlockIndex = -1;
    for (var i = 0; i < visible.length; i++) {
      if (_blocksFor(visible[i]).any((b) => b.blockName == item.blockName)) {
        lastBlockIndex = i;
      }
    }
    final count = lastBlockIndex == -1
        ? visible.length
        : visible.length - lastBlockIndex;
    if (count <= 0) return '';

    final slice = visible.sublist(visible.length - count);
    return _formatSlice(slice, item, count);
  }

  String _previousBlock(BlockContextItem item) {
    if (item.blockName.isEmpty) return '';
    final count = item.blockCount < 1 ? 1 : item.blockCount;
    final collected = <String>[];

    for (var i = anchorIndex - 1; i >= 0 && collected.length < count; i--) {
      final match = _blocksFor(
        messages[i],
      ).where((b) => b.blockName == item.blockName).firstOrNull;
      if (match == null || match.content.trim().isEmpty) continue;
      collected.add(
        _wrap(
          item.blockName,
          ImageTagMarkup.reduceBlocksToInstructions(match.content).trim(),
        ),
      );
    }

    return collected.reversed.join('\n\n');
  }

  /// Wraps a stored block's inner content back in its tag, the way the
  /// original hands earlier block state to the model.
  String _wrap(String blockName, String content) {
    final tag = blockName.trim().split(RegExp(r'\s+')).first;
    if (tag.isEmpty) return content;
    return '<$tag>\n$content\n</$tag>';
  }

  List<InfoBlock> _blocksFor(ChatMessage message) {
    final blocks = blocksByMessageId[message.id];
    if (blocks == null || blocks.isEmpty) return const [];
    return blocks
        .where(
          (b) => b.swipeId == message.swipeId && b.content.trim().isNotEmpty,
        )
        .toList();
  }

  String _formatSlice(
    List<ChatMessage> slice,
    BlockContextItem item,
    int count,
  ) {
    final separator = item.messagesSeparator.text;
    final parts = <String>[];

    for (var i = 0; i < slice.length; i++) {
      final message = slice[i];
      final isUser = message.role == 'user';
      final prefix = _expand(isUser ? item.userPrefix : item.charPrefix);
      final suffix = _expand(isUser ? item.userSuffix : item.charSuffix);
      final placement = isUser ? 1 : 2;
      final depth = count - i - 1;
      // Image blocks reach the model as the tag that asked for the picture,
      // never as the stored element with this device's file paths (INV-IG12).
      final body = _promptRegex(
        ImageTagMarkup.reduceBlocksToInstructions(message.content).trim(),
        placement,
        depth,
      );
      parts.add('$prefix$body$suffix');
    }

    return parts.join(separator);
  }

  String _promptRegex(String text, int placement, int depth) {
    if (promptRegexes.isEmpty || text.isEmpty) return text;
    return applyRegexes(
      text,
      placement,
      2,
      promptRegexes,
      RegexApplyContext(
        char: character,
        persona: persona,
        sessionVars: sessionVars,
        globalVars: globalVars,
        depth: depth,
      ),
      isPrompt: true,
    );
  }
}
