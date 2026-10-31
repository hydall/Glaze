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

  /// The block written again, waiting for the reader to approve it.
  final SummaryDraft? draft;

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
    this.draft,
  });

  bool get isNote => level == 0;

  /// The id of the note a summary from before blocks existed reads as (see
  /// `SummaryService`): the old summary itself, not a reader's note, so the
  /// chat prompt keeps carrying it.
  static const legacyNoteId = 'note-legacy';

  /// A note the reader wrote for the retelling — every note but the
  /// [legacyNoteId] one.
  bool get isReaderNote => isNote && id != legacyNoteId;

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
        draft: draft,
      );

  /// This block with [draft] in place of the one it has; null drops it.
  SummaryBlock withDraft(SummaryDraft? draft) => SummaryBlock(
    id: id,
    level: level,
    content: content,
    messageIds: messageIds,
    sourceHash: sourceHash,
    childIds: childIds,
    archived: archived,
    tokens: tokens,
    sourceTokens: sourceTokens,
    createdAt: createdAt,
    draft: draft,
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
    if (draft case final draft?) 'draft': draft.toJson(),
  };

  static SummaryBlock? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final content = raw['content'];
    if (id is! String || id.isEmpty || content is! String) return null;
    return SummaryBlock(
      id: id,
      level: _number(raw['level']).clamp(0, 99),
      content: content,
      messageIds: _strings(raw['messageIds']),
      sourceHash: raw['sourceHash'] as String? ?? '',
      childIds: _strings(raw['childIds']),
      archived: raw['archived'] == true,
      tokens: _number(raw['tokens']),
      sourceTokens: _number(raw['sourceTokens']),
      createdAt: _number(raw['createdAt']),
      draft: SummaryDraft.fromJson(raw['draft']),
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

/// A block written again, waiting for the reader — the way a Memory Books
/// draft waits for approval. Until it is approved the block keeps standing in
/// for its messages with the text it had; a draft is never sent.
///
/// It records the sources it was written over — a level-1 block's messages
/// that still exist, a merge's union — and their fingerprint, so a draft whose
/// messages changed after it was written is never approved
/// ([SummaryChain.isDraftStale]).
class SummaryDraft {
  final String content;
  final List<String> messageIds;
  final String sourceHash;
  final int tokens;
  final int sourceTokens;
  final int createdAt;

  const SummaryDraft({
    required this.content,
    this.messageIds = const [],
    this.sourceHash = '',
    this.tokens = 0,
    this.sourceTokens = 0,
    this.createdAt = 0,
  });

  SummaryDraft copyWith({String? content, int? tokens}) => SummaryDraft(
    content: content ?? this.content,
    messageIds: messageIds,
    sourceHash: sourceHash,
    tokens: tokens ?? this.tokens,
    sourceTokens: sourceTokens,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'content': content,
    'messageIds': messageIds,
    'sourceHash': sourceHash,
    'tokens': tokens,
    'sourceTokens': sourceTokens,
    'createdAt': createdAt,
  };

  static SummaryDraft? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final content = raw['content'];
    if (content is! String) return null;
    return SummaryDraft(
      content: content,
      messageIds: _strings(raw['messageIds']),
      sourceHash: raw['sourceHash'] as String? ?? '',
      tokens: _number(raw['tokens']),
      sourceTokens: _number(raw['sourceTokens']),
      createdAt: _number(raw['createdAt']),
    );
  }
}

List<String> _strings(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const [];

int _number(Object? value) => value is num ? value.toInt() : 0;

/// What the prompt gets from the summary: the text, and the messages it
/// stands in for.
class SummaryPromptView {
  final String content;
  final Set<String> coveredMessageIds;

  /// [content] cut where the history runs between blocks, for a summary sent
  /// in place of its messages. Story order.
  final List<SummarySegment> segments;

  const SummaryPromptView({
    required this.content,
    this.coveredMessageIds = const {},
    this.segments = const [],
  });

  static const empty = SummaryPromptView(content: '');
}

/// One unbroken run of live blocks: no message the prompt carries sits
/// between them. Sent in place of the messages it covers — right before
/// [beforeMessageId], the first message after the run the history still
/// carries, or after the whole history when none follows.
class SummarySegment {
  final String content;
  final String? beforeMessageId;

  const SummarySegment({required this.content, this.beforeMessageId});

  Map<String, dynamic> toJson() => {
    'content': content,
    'beforeMessageId': beforeMessageId,
  };

  static SummarySegment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final content = raw['content'];
    if (content is! String) return null;
    final before = raw['beforeMessageId'];
    return SummarySegment(
      content: content,
      beforeMessageId: before is String ? before : null,
    );
  }

  static List<Map<String, dynamic>> encodeList(List<SummarySegment> list) => [
    for (final segment in list) segment.toJson(),
  ];

  static List<SummarySegment> decodeList(Object? raw) => raw is List
      ? [for (final item in raw) ?SummarySegment.fromJson(item)]
      : const [];
}

/// A run of messages picked for a new level-1 block.
class SummarySourcePlan {
  final List<ChatMessage> source;
  final int sourceTokens;

  /// Tokens of the fresh tail that stays as raw history.
  final int tailTokens;

  /// Summarizable messages outside the tail that no live block covers,
  /// [source] included: what is left to retell, counted in messages.
  final int remainingMessages;

  const SummarySourcePlan({
    required this.source,
    required this.sourceTokens,
    required this.tailTokens,
    this.remainingMessages = 0,
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

  /// True once a draft's sources changed after it was written: approved, it
  /// would stand in for messages that no longer read the way it says.
  static bool isDraftStale(SummaryDraft draft, Map<String, ChatMessage> byId) =>
      fingerprint(draft.messageIds, byId) != draft.sourceHash;

  /// A stale block with a fresh draft waits for the reader: approving the
  /// draft brings it back, so compaction neither drops it nor retells its
  /// messages over again meanwhile.
  static bool awaitsReview(SummaryBlock block, Map<String, ChatMessage> byId) {
    final draft = block.draft;
    return draft != null &&
        !block.archived &&
        isStale(block, byId) &&
        !isDraftStale(draft, byId);
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

  /// Live blocks the chat prompt carries, in story order: every live block
  /// but the reader's notes. A note is an instruction for the retelling —
  /// handed to it with the earlier summary (see [liveBefore]) — and never
  /// reaches the chat request, where it would only repeat the author's note.
  /// A summary from before blocks (the [SummaryBlock.legacyNoteId] note) is
  /// still carried: it is the old retelling, not a note.
  static List<SummaryBlock> inPrompt(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
  ) => live(
    blocks,
    messages,
  ).where((b) => !b.isReaderNote).toList(growable: false);

  /// Live blocks that come before [firstMessageId] in story order, notes
  /// included: the earlier summary a retelling of the run starting there is
  /// handed as context.
  static List<SummaryBlock> liveBefore(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
    String firstMessageId,
  ) {
    final position = {
      for (var i = 0; i < messages.length; i++) messages[i].id: i,
    };
    final first = position[firstMessageId] ?? messages.length;
    return live(blocks, messages)
        .where(
          (b) =>
              b.isNote ||
              b.messageIds.any((id) => (position[id] ?? -1) < first),
        )
        .toList(growable: false);
  }

  static String render(Iterable<SummaryBlock> blocks) => blocks
      .map((b) => b.content.trim())
      .where((text) => text.isNotEmpty)
      .join('\n\n');

  static SummaryPromptView promptView(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
  ) {
    final used = inPrompt(blocks, messages);
    final covered = {for (final block in used) ...block.messageIds};
    return SummaryPromptView(
      content: render(used),
      coveredMessageIds: covered,
      segments: _segments(used, messages, covered),
    );
  }

  /// Cuts [used] — the blocks the prompt carries, in story order — where a
  /// message the prompt carries sits between two of them.
  static List<SummarySegment> _segments(
    List<SummaryBlock> used,
    List<ChatMessage> messages,
    Set<String> covered,
  ) {
    final position = {
      for (var i = 0; i < messages.length; i++) messages[i].id: i,
    };
    int end(SummaryBlock block) {
      var last = -1;
      for (final id in block.messageIds) {
        final at = position[id];
        if (at != null && at > last) last = at;
      }
      return last;
    }

    // The first message after [from] that the history still carries: what
    // the history assembler sends, less what a block stands in for.
    int? next(int from) {
      for (var i = from + 1; i < messages.length; i++) {
        final message = messages[i];
        if (message.isHidden || message.isTyping) continue;
        if (!covered.contains(message.id)) return i;
      }
      return null;
    }

    final segments = <SummarySegment>[];
    var run = <SummaryBlock>[];
    var runEnd = -1;
    void flush() {
      final text = render(run);
      if (text.isNotEmpty) {
        final at = next(runEnd);
        segments.add(
          SummarySegment(
            content: text,
            beforeMessageId: at == null ? null : messages[at].id,
          ),
        );
      }
      run = [];
    }

    for (final block in used) {
      final blockEnd = end(block);
      if (run.isNotEmpty && blockEnd >= 0) {
        final gap = next(runEnd);
        final start = position[block.messageIds.first] ?? blockEnd;
        if (gap != null && gap < start) flush();
      }
      run.add(block);
      if (blockEnd > runEnd) runEnd = blockEnd;
    }
    if (run.isNotEmpty) flush();
    return segments;
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

  /// What the summary takes in the chat prompt: the blocks [inPrompt]
  /// carries, notes left out.
  static int liveTokens(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
  ) => inPrompt(blocks, messages).fold(0, (sum, b) => sum + b.tokens);

  /// Drops stale active blocks together with the archive they were merged
  /// from: the archived parts cover the same changed messages. A block that
  /// [awaitsReview] stays.
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
      if (!block.archived &&
          isStale(block, byId) &&
          !awaitsReview(block, byId)) {
        drop(block);
      }
    }
    if (removed.isEmpty) return blocks;
    return blocks.where((b) => !removed.contains(b.id)).toList();
  }

  /// Summarizable messages outside the fresh tail that no live block covers:
  /// the oldest unbroken run of them, capped at [maxSourceTokens] (always at
  /// least one message).
  ///
  /// The tail is the newest messages that fit [tailBudgetTokens], never fewer
  /// than [minTailMessages].
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

    final byId = index(messages);
    final covered = {
      ...promptView(blocks, messages).coveredMessageIds,
      // Messages under a draft waiting for review are not retold again.
      for (final block in blocks)
        if (awaitsReview(block, byId)) ...[
          ...block.messageIds,
          ...block.draft!.messageIds,
        ],
    };
    final source = <ChatMessage>[];
    var sourceTokens = 0;
    var remaining = 0;
    var open = true;
    for (final message in eligible.take(split)) {
      if (covered.contains(message.id)) {
        // The run ends where a block begins, so a new block never straddles
        // an existing one.
        if (source.isNotEmpty) open = false;
        continue;
      }
      remaining++;
      if (!open) continue;
      final tokens = estimateTokens(message.content);
      if (source.isNotEmpty && sourceTokens + tokens > maxSourceTokens) {
        open = false;
        continue;
      }
      source.add(message);
      sourceTokens += tokens;
    }
    return SummarySourcePlan(
      source: source,
      sourceTokens: sourceTokens,
      tailTokens: tailTokens,
      remainingMessages: remaining,
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
    // An archived part is never written again, so a draft it had goes.
    return [
      for (final block in blocks)
        children.contains(block.id)
            ? block.copyWith(archived: true).withDraft(null)
            : block,
      merged,
    ];
  }

  /// Leaves [draft] on the active block [id], in place of any it had; a null
  /// [draft] discards it. Throws when that block is no longer active.
  static List<SummaryBlock> putDraft(
    List<SummaryBlock> blocks,
    String id,
    SummaryDraft? draft,
  ) {
    if (!blocks.any((b) => b.id == id && !b.archived)) {
      throw const SummaryChainException('not_live');
    }
    return [
      for (final block in blocks)
        block.id == id ? block.withDraft(draft) : block,
    ];
  }

  /// Puts the draft of the active block [id] in place of its text: same id,
  /// level, parts and place in the chain, the draft's sources and
  /// fingerprint. Throws `not_live` when there is no such draft, and
  /// `changed` when its messages changed after it was written.
  static List<SummaryBlock> approveDraft(
    List<SummaryBlock> blocks,
    List<ChatMessage> messages,
    String id,
  ) {
    final block = blocks.where((b) => b.id == id && !b.archived).firstOrNull;
    final draft = block?.draft;
    if (block == null || draft == null) {
      throw const SummaryChainException('not_live');
    }
    if (isDraftStale(draft, index(messages))) {
      throw const SummaryChainException('changed');
    }
    final approved = SummaryBlock(
      id: block.id,
      level: block.level,
      content: draft.content,
      messageIds: draft.messageIds,
      sourceHash: draft.sourceHash,
      childIds: block.childIds,
      tokens: draft.tokens,
      sourceTokens: draft.sourceTokens,
      createdAt: block.createdAt,
    );
    return [for (final b in blocks) b.id == id ? approved : b];
  }

  /// The draft of [id] with [content] as its text. Throws `not_live` when
  /// the active block [id] has no draft any more — merged away or discarded
  /// while the editor was open — rather than drop the edit unsaid.
  static List<SummaryBlock> editDraft(
    List<SummaryBlock> blocks,
    String id,
    String content,
  ) {
    if (!blocks.any((b) => b.id == id && !b.archived && b.draft != null)) {
      throw const SummaryChainException('not_live');
    }
    final text = content.trim();
    return [
      for (final block in blocks)
        switch (block.draft) {
          final draft? when block.id == id => block.withDraft(
            draft.copyWith(content: text, tokens: estimateTokens(text)),
          ),
          _ => block,
        },
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
