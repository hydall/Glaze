import 'dart:convert';

import '../llm/tokenizer.dart';
import '../utils/cast_helpers.dart';
import 'chat_message.dart';

/// One piece of a chat's summary.
///
/// The summary is a chain of these rather than one text. A level-1 block
/// retells a run of messages; once there are enough of them, adjacent blocks
/// of one level are merged into a block a level up, and the merged ones move
/// to the archive. A level-0 block is a note the reader wrote: it covers no
/// messages and is never merged.
///
/// While a block is active and its source messages are unchanged, those
/// messages are left out of the prompt — the block stands in for them. That is
/// what makes summarizing free context instead of only adding to it.
class SummaryBlock {
  final String id;

  /// 0 for a reader's note, 1 for a retelling of messages, 2+ for a merge.
  final int level;
  final String content;

  /// Source messages, oldest first. A merge carries the union of its parts.
  final List<String> messageIds;

  /// Fingerprint of [messageIds] and their text when the block was written.
  /// A block whose sources no longer hash the same is stale — see
  /// [SummaryChain.isStale].
  final String sourceHash;

  /// Blocks this one was merged from. They sit in the archive until this
  /// block is deleted, which restores them.
  final List<String> childIds;
  final bool archived;
  final int tokens;

  /// Estimated tokens of what the block replaced — its messages for level 1,
  /// its parts for a merge.
  final int sourceTokens;
  final int createdAt;

  const SummaryBlock({
    required this.id,
    required this.level,
    required this.content,
    this.messageIds = const [],
    this.sourceHash = '',
    this.childIds = const [],
    this.archived = false,
    this.tokens = 0,
    this.sourceTokens = 0,
    this.createdAt = 0,
  });

  bool get isNote => level == 0;

  SummaryBlock copyWith({String? content, bool? archived, int? tokens}) =>
      SummaryBlock(
        id: id,
        level: level,
        content: content ?? this.content,
        messageIds: messageIds,
        sourceHash: sourceHash,
        childIds: childIds,
        archived: archived ?? this.archived,
        tokens: tokens ?? this.tokens,
        sourceTokens: sourceTokens,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'level': level,
    'content': content,
    'messageIds': messageIds,
    'sourceHash': sourceHash,
    'childIds': childIds,
    'archived': archived,
    'tokens': tokens,
    'sourceTokens': sourceTokens,
    'createdAt': createdAt,
  };

  static SummaryBlock? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final content = raw['content'];
    if (id is! String || id.isEmpty || content is! String) return null;
    List<String> strings(Object? value) => value is List
        ? value.whereType<String>().toList(growable: false)
        : const [];
    int number(Object? value) => value is num ? value.toInt() : 0;
    return SummaryBlock(
      id: id,
      level: number(raw['level']).clamp(0, 99),
      content: content,
      messageIds: strings(raw['messageIds']),
      sourceHash: raw['sourceHash'] as String? ?? '',
      childIds: strings(raw['childIds']),
      archived: raw['archived'] == true,
      tokens: number(raw['tokens']),
      sourceTokens: number(raw['sourceTokens']),
      createdAt: number(raw['createdAt']),
    );
  }

  static String encodeList(List<SummaryBlock> blocks) =>
      jsonEncode([for (final block in blocks) block.toJson()]);

  /// An unreadable list decodes to nothing rather than throwing: the prompt
  /// then carries the full history, which is the safe way to be wrong.
  static List<SummaryBlock> decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [for (final item in decoded) ?SummaryBlock.fromJson(item)];
    } catch (_) {
      return const [];
    }
  }
}

/// What the prompt gets from the summary: the text, and the messages it
/// stands in for.
class SummaryPromptView {
  final String content;
  final Set<String> coveredMessageIds;

  const SummaryPromptView({
    required this.content,
    this.coveredMessageIds = const {},
  });

  static const empty = SummaryPromptView(content: '');
}

/// A run of messages picked for a new level-1 block.
class SummarySourcePlan {
  final List<ChatMessage> source;
  final int sourceTokens;

  /// Tokens of the fresh tail that stays as raw history.
  final int tailTokens;

  const SummarySourcePlan({
    required this.source,
    required this.sourceTokens,
    required this.tailTokens,
  });
}

/// Operations over a session's list of [SummaryBlock]s. Pure: every method
/// takes the list and returns a new one.
class SummaryChain {
  const SummaryChain._();

  /// The newest messages never summarized, however small the tail budget.
  static const minTailMessages = 2;

  /// Messages a summary can stand in for: what the prompt would carry.
  static bool isSummarizable(ChatMessage message) =>
      (message.role == 'user' || message.role == 'assistant') &&
      !message.isHidden &&
      !message.isTyping &&
      !message.isError &&
      message.content.trim().isNotEmpty;

  static String fingerprint(
    List<String> messageIds,
    Map<String, ChatMessage> byId,
  ) {
    final buffer = StringBuffer();
    for (final id in messageIds) {
      // A deleted source hashes differently from any text it could have had.
      buffer
        ..write(id)
        ..write('\u0000')
        ..write(byId[id]?.content ?? '\u0001missing')
        ..write('\u0000');
    }
    return computeHash(buffer.toString());
  }

  /// True once a source message was edited, swiped to another variant or
  /// deleted. A stale block is left out of the prompt and its messages come
  /// back; the next compaction replaces it.
  static bool isStale(SummaryBlock block, Map<String, ChatMessage> byId) {
    if (block.isNote || block.messageIds.isEmpty) return false;
    return fingerprint(block.messageIds, byId) != block.sourceHash;
  }

  static Map<String, ChatMessage> index(List<ChatMessage> messages) => {
    for (final message in messages) message.id: message,
  };

  /// Active blocks in story order: notes first, then by where their first
  /// source message sits in [messages]. A block whose sources are all gone
  /// sorts last, where it does no harm — it is stale anyway.
  static List<SummaryBlock> ordered(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
  ) {
    final position = {
      for (var i = 0; i < messages.length; i++) messages[i].id: i,
    };
    int start(SummaryBlock block) {
      if (block.isNote) return -1;
      for (final id in block.messageIds) {
        final at = position[id];
        if (at != null) return at;
      }
      return messages.length;
    }

    final active = blocks.where((b) => !b.archived).toList();
    active.sort((a, b) {
      final byStart = start(a).compareTo(start(b));
      return byStart != 0 ? byStart : a.createdAt.compareTo(b.createdAt);
    });
    return active;
  }

  /// Active blocks the prompt uses, in story order.
  static List<SummaryBlock> live(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
  ) {
    final byId = index(messages);
    return ordered(
      blocks,
      messages,
    ).where((b) => !isStale(b, byId)).toList(growable: false);
  }

  static String render(Iterable<SummaryBlock> blocks) => blocks
      .map((b) => b.content.trim())
      .where((text) => text.isNotEmpty)
      .join('\n\n');

  static SummaryPromptView promptView(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
  ) {
    final used = live(blocks, messages);
    return SummaryPromptView(
      content: render(used),
      coveredMessageIds: {for (final block in used) ...block.messageIds},
    );
  }

  /// [history] without the messages [view] stands in for. Matched by id,
  /// so a history whose text was rewritten on the way (ExtBlocks) still
  /// loses exactly the covered messages.
  static List<ChatMessage> withoutCovered(
    List<ChatMessage> history,
    SummaryPromptView? view,
  ) {
    final covered = view?.coveredMessageIds ?? const <String>{};
    if (covered.isEmpty) return history;
    return history.where((m) => !covered.contains(m.id)).toList();
  }

  static int liveTokens(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
  ) => live(blocks, messages).fold(0, (sum, b) => sum + b.tokens);

  /// Drops stale active blocks together with the archive they were merged
  /// from: the archived parts cover the same changed messages.
  static List<SummaryBlock> withoutStale(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
  ) {
    final byId = index(messages);
    final removed = <String>{};
    void drop(SummaryBlock block) {
      if (!removed.add(block.id)) return;
      for (final childId in block.childIds) {
        final child = blocks.where((b) => b.id == childId).firstOrNull;
        if (child != null) drop(child);
      }
    }

    for (final block in blocks) {
      if (!block.archived && isStale(block, byId)) drop(block);
    }
    if (removed.isEmpty) return blocks;
    return blocks.where((b) => !removed.contains(b.id)).toList();
  }

  /// Summarizable messages outside the fresh tail that no live block covers:
  /// the oldest unbroken run of them, capped at [maxSourceTokens] (always at
  /// least one message).
  static SummarySourcePlan planSource({
    required List<SummaryBlock> blocks,
    required List<ChatMessage> messages,
    required int tailBudgetTokens,
    required int maxSourceTokens,
  }) {
    final eligible = messages.where(isSummarizable).toList();
    var tailTokens = 0;
    var split = eligible.length;
    for (var i = eligible.length - 1; i >= 0; i--) {
      final tokens = estimateTokens(eligible[i].content);
      final mustKeep = eligible.length - i <= minTailMessages;
      if (!mustKeep && tailTokens + tokens > tailBudgetTokens) break;
      tailTokens += tokens;
      split = i;
    }

    final covered = promptView(blocks, messages).coveredMessageIds;
    final source = <ChatMessage>[];
    var sourceTokens = 0;
    for (final message in eligible.take(split)) {
      if (covered.contains(message.id)) {
        // The run ends where a block begins, so a new block never straddles
        // an existing one.
        if (source.isNotEmpty) break;
        continue;
      }
      final tokens = estimateTokens(message.content);
      if (source.isNotEmpty && sourceTokens + tokens > maxSourceTokens) break;
      source.add(message);
      sourceTokens += tokens;
    }
    return SummarySourcePlan(
      source: source,
      sourceTokens: sourceTokens,
      tailTokens: tailTokens,
    );
  }

  /// Oldest run of adjacent live blocks sharing the lowest level that has a
  /// run of two or more, capped at [maxInputTokens] (always at least two).
  /// Empty when nothing can be merged.
  static List<SummaryBlock> mergeCandidate(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages, {
    required int maxInputTokens,
  }) {
    final chain = live(blocks, messages).where((b) => !b.isNote).toList();
    final levels = chain.map((b) => b.level).toSet().toList()..sort();
    for (final level in levels) {
      var run = <SummaryBlock>[];
      for (final block in chain) {
        if (block.level == level) {
          run.add(block);
          continue;
        }
        if (run.length >= 2) break;
        run = [];
      }
      if (run.length < 2) continue;
      final capped = <SummaryBlock>[];
      var tokens = 0;
      for (final block in run) {
        if (capped.length >= 2 && tokens + block.tokens > maxInputTokens) {
          break;
        }
        capped.add(block);
        tokens += block.tokens;
      }
      return capped;
    }
    return const [];
  }

  /// Checks a reader's selection for a manual merge. Returns the blocks in
  /// story order, or throws [SummaryChainException].
  static List<SummaryBlock> manualMergeSelection(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
    Set<String> selectedIds,
  ) {
    if (selectedIds.length < 2) {
      throw const SummaryChainException('select_two');
    }
    final chain = live(blocks, messages).where((b) => !b.isNote).toList();
    final positions = [
      for (var i = 0; i < chain.length; i++)
        if (selectedIds.contains(chain[i].id)) i,
    ];
    if (positions.length != selectedIds.length) {
      throw const SummaryChainException('not_live');
    }
    for (var i = 1; i < positions.length; i++) {
      if (positions[i] != positions[i - 1] + 1) {
        throw const SummaryChainException('not_adjacent');
      }
    }
    final selected = [for (final i in positions) chain[i]];
    if (selected.map((b) => b.level).toSet().length != 1) {
      throw const SummaryChainException('mixed_levels');
    }
    return selected;
  }

  /// Adds a level-1 block, unless another run already covers any of its
  /// messages — a concurrent compaction got there first.
  static List<SummaryBlock> commitSource(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
    SummaryBlock block,
  ) {
    final covered = {
      for (final b in blocks.where((b) => !b.archived)) ...b.messageIds,
    };
    if (block.messageIds.any(covered.contains)) {
      throw const SummaryChainException('already_covered');
    }
    return [...blocks, block];
  }

  /// Archives [childIds] and adds [merged] in their place. Throws when one of
  /// the parts is no longer active.
  static List<SummaryBlock> commitMerge(
    List<SummaryBlock> blocks,
    SummaryBlock merged,
  ) {
    final children = merged.childIds.toSet();
    final found = blocks.where((b) => children.contains(b.id) && !b.archived);
    if (found.length != children.length) {
      throw const SummaryChainException('not_live');
    }
    return [
      for (final block in blocks)
        children.contains(block.id) ? block.copyWith(archived: true) : block,
      merged,
    ];
  }

  /// Removes an active block. A merge gives its parts back to the chain; a
  /// level-1 block lets its messages return to the prompt.
  static List<SummaryBlock> delete(List<SummaryBlock> blocks, String id) {
    final target = blocks.where((b) => b.id == id && !b.archived).firstOrNull;
    if (target == null) return blocks;
    final restored = target.childIds.toSet();
    return [
      for (final block in blocks)
        if (block.id != id)
          restored.contains(block.id) ? block.copyWith(archived: false) : block,
    ];
  }

  static List<SummaryBlock> edit(
    List<SummaryBlock> blocks,
    String id,
    String content,
  ) => [
    for (final block in blocks)
      block.id == id
          ? block.copyWith(
              content: content.trim(),
              tokens: estimateTokens(content.trim()),
            )
          : block,
  ];
}

class SummaryChainException implements Exception {
  /// Stable reason code; the UI maps it to a message.
  final String reason;

  const SummaryChainException(this.reason);

  @override
  String toString() => 'SummaryChainException($reason)';
}
