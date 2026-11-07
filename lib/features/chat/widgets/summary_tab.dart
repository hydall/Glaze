import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/summary_block.dart';
import '../../../core/state/summary_providers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../../../shared/widgets/glaze_expansion_tile.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../chat_provider.dart';
import '../services/summary_generation_service.dart';
import '../state/summary_compaction_provider.dart';
import '../state/summary_regeneration_provider.dart';
import 'summary_block_card.dart';
import 'summary_block_editor_sheet.dart';

/// Summary tab of the Memory sheet.
///
/// The summary is a chain of blocks (see [SummaryBlock]): each retells a run
/// of old messages and is sent in their place. The tab lists the active
/// chain in story order, the archive of merged-away blocks below it, and the
/// actions that change the chain — compact now, merge a selection, add a note,
/// write one block again, shorten one. Compacting runs in
/// `summaryCompactionProvider`, block after block until the backlog is retold,
/// with its progress and a Stop button in the action bar, and goes on when the
/// sheet is closed. A block written again comes back as a draft on its card
/// and replaces the block's text only once approved, the way a Memory Books
/// draft becomes an entry; so does a block shortened to the block size, which
/// the card of a block past that size offers.
///
/// Everything else — the master switch, the template, when compaction runs,
/// the injection point — is behind the header's settings button, in
/// `SummarySettingsSheet`.
class SummaryTab extends ConsumerStatefulWidget {
  final String charId;

  const SummaryTab({super.key, required this.charId});

  @override
  ConsumerState<SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends ConsumerState<SummaryTab> {
  List<SummaryBlock> _blocks = const [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  ChatSession? get _session =>
      ref.read(chatProvider(widget.charId)).value?.session;

  Future<void> _load() async {
    final session = _session;
    if (session == null) return;
    final blocks = await ref.read(summaryServiceProvider).getBlocks(session.id);
    if (!mounted) return;
    setState(() {
      _blocks = blocks;
      _selected.removeWhere(
        (id) => !blocks.any((b) => b.id == id && !b.archived),
      );
      _loading = false;
    });
  }

  /// Runs a change to the chain, then reloads it. Errors land under the
  /// action bar rather than in a toast: a summarizer failure needs reading.
  /// Returns whether the change went through.
  Future<bool> _run(Future<void> Function(ChatSession session) action) async {
    final session = _session;
    if (session == null || _busy) return false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(session);
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = _describe(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  /// Says a saved change landed — the reader pressed Save or Approve and the
  /// sheet gives no other sign of it.
  void _saved(bool ok, String message) {
    if (ok && mounted) GlazeToast.show(context, message.tr());
  }

  Object _describe(Object error) {
    if (error is! SummaryChainException) return error;
    return switch (error.reason) {
      'busy' => 'summary_error_busy'.tr(),
      'not_shorter' => 'summary_error_not_shorter'.tr(),
      'not_adjacent' => 'summary_error_not_adjacent'.tr(),
      'mixed_levels' => 'summary_error_mixed_levels'.tr(),
      'select_two' => 'summary_error_select_two'.tr(),
      'stale_merge' => 'summary_error_stale_merge'.tr(),
      'stale' => 'summary_block_stale'.tr(),
      'sources_gone' => 'summary_error_sources_gone'.tr(),
      'nothing_to_compact' => 'summary_nothing_to_compact'.tr(),
      _ => 'summary_error_changed'.tr(),
    };
  }

  SummaryGenerationService get _generator =>
      ref.read(summaryGenerationServiceProvider);

  SummaryCompactionNotifier get _compaction =>
      ref.read(summaryCompactionProvider.notifier);

  /// Starts the run and leaves it alone: it belongs to
  /// [summaryCompactionProvider], which this tab watches, so the blocks keep
  /// landing and the progress keeps counting whether or not the sheet stays
  /// open. Each block written bumps `summaryRevisionProvider`, and the list
  /// follows.
  void _compact() {
    final session = _session;
    if (session == null) return;
    setState(() => _error = null);
    unawaited(_compaction.compact(charId: widget.charId, session: session));
  }

  void _stopCompaction() {
    final session = _session;
    if (session != null) _compaction.cancel(session.id);
  }

  Future<void> _mergeSelected() => _run((session) async {
    await _generator.mergeSelected(session: session, blockIds: {..._selected});
    _selected.clear();
  });

  SummaryRegenerationNotifier get _regeneration =>
      ref.read(summaryRegenerationProvider.notifier);

  /// Starts the run and leaves it alone: it belongs to
  /// [summaryRegenerationProvider], which this tab watches, so the card keeps
  /// counting whether or not the sheet is still open when the draft lands.
  void _regenerate(SummaryBlock block) {
    final session = _session;
    if (session == null) return;
    setState(() => _error = null);
    unawaited(
      _regeneration.regenerate(
        charId: widget.charId,
        session: session,
        blockId: block.id,
      ),
    );
  }

  /// As [_regenerate]: the run belongs to [summaryRegenerationProvider].
  void _shorten(SummaryBlock block) {
    final session = _session;
    if (session == null) return;
    setState(() => _error = null);
    unawaited(_regeneration.shorten(session: session, blockId: block.id));
  }

  /// Whether a card offers Shorten: a live block past the block size, with
  /// no draft waiting on it. A stale block is not sent, so there is nothing
  /// to gain; a draft is shortened by approving a shorter one later.
  bool _canShorten(
    SummaryBlock block,
    Map<String, ChatMessage> byId,
    int? blockTarget,
  ) =>
      blockTarget != null &&
      !block.isNote &&
      block.draft == null &&
      block.tokens > blockTarget &&
      !SummaryChain.isStale(block, byId);

  void _stop(SummaryBlock block) {
    final session = _session;
    if (session != null) _regeneration.cancel(session.id, block.id);
  }

  Future<void> _approve(SummaryBlock block) async => _saved(
    await _run(
      (session) => _generator.approveDraft(session: session, blockId: block.id),
    ),
    'summary_saved',
  );

  Future<void> _discardDraft(SummaryBlock block) => _run(
    (session) => _generator.discardDraft(session: session, blockId: block.id),
  );

  Future<void> _addNote() async {
    final text = await SummaryBlockEditorSheet.show(
      context,
      title: 'summary_note_add'.tr(),
      description: 'summary_note_hint'.tr(),
    );
    if (text == null) return;
    _saved(
      await _run(
        (session) => _generator.addNote(session: session, content: text),
      ),
      'summary_saved',
    );
  }

  /// Tapping a card edits what it shows: the draft when there is one, as on a
  /// Memory Books draft, the block otherwise. The sheet is named by the
  /// messages the block covers, as a memory entry is.
  Future<void> _edit(SummaryBlock block) async {
    final draft = block.draft;
    final current = draft?.content ?? block.content;
    final text = await SummaryBlockEditorSheet.show(
      context,
      title: block.isNote ? _level(block) : _range(block) ?? _level(block),
      description: block.isNote
          ? 'summary_note_hint'.tr()
          : [
              _level(block),
              if (draft != null) 'memory_books_badge_draft'.tr(),
              'summary_tokens_n'.tr(args: ['${draft?.tokens ?? block.tokens}']),
            ].join(' · '),
      initialValue: current,
    );
    if (text == null || text == current.trim()) return;
    _saved(
      await _run(
        (session) => draft == null
            ? _generator.editBlock(
                session: session,
                blockId: block.id,
                content: text,
              )
            : _generator.editDraft(
                session: session,
                blockId: block.id,
                content: text,
              ),
      ),
      draft == null ? 'summary_saved' : 'summary_draft_saved',
    );
  }

  Future<void> _delete(SummaryBlock block) async {
    final description = block.childIds.isNotEmpty
        ? 'summary_delete_merge_hint'.tr()
        : block.isNote
        ? 'summary_delete_note_hint'.tr()
        : 'summary_delete_block_hint'.tr();
    if (!await _confirm(_title(block), description)) return;
    _selected.remove(block.id);
    await _run(
      (session) => _generator.deleteBlock(session: session, blockId: block.id),
    );
  }

  Future<void> _clear() async {
    if (!await _confirm('summary_clear'.tr(), 'summary_clear_hint'.tr())) {
      return;
    }
    _selected.clear();
    await _run((session) => _generator.clear(session: session));
  }

  Future<bool> _confirm(String title, String description) async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: title,
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: description,
      ),
      items: [
        BottomSheetItem(
          label: 'action_delete'.tr(),
          centered: true,
          isDestructive: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'action_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    return confirmed == true;
  }

  static String _level(SummaryBlock block) => block.isNote
      ? 'summary_note'.tr()
      : 'summary_block_level'.tr(args: ['${block.level}']);

  /// The level, and the messages the block covers — "Level 1 · 641-650", as a
  /// Memory Books row reads "title · range".
  String _title(SummaryBlock block) => switch (_range(block)) {
    final range? => '${_level(block)} · $range',
    null => _level(block),
  };

  /// The messages [block] covers, numbered as the chat counts them: "641-650",
  /// the way a Memory Books entry is named. Null for a note, and when none of
  /// its messages is left.
  String? _range(SummaryBlock block) => _rangeOf(block.messageIds);

  String? _rangeOf(Iterable<String> messageIds) {
    final messages = _session?.messages ?? const <ChatMessage>[];
    final ids = messageIds.toSet();
    int? first;
    int? last;
    for (var i = 0; i < messages.length; i++) {
      if (!ids.contains(messages[i].id)) continue;
      first ??= i + 1;
      last = i + 1;
    }
    if (first == null) return null;
    return first == last ? '$first' : '$first-$last';
  }

  @override
  Widget build(BuildContext context) {
    // Auto-compaction writes from the background; follow it.
    ref.listen(summaryRevisionProvider, (_, _) => _load());
    // A run that fails reports here while the sheet is open, whether or not
    // it was started from this sheet.
    ref.listen(summaryRegenerationProvider.select((s) => s.lastFailure), (
      _,
      failure,
    ) {
      if (failure == null || failure.sessionId != _session?.id) return;
      setState(() => _error = _describe(failure.error));
    });
    ref.listen(summaryCompactionProvider.select((s) => s.lastFailure), (
      _,
      failure,
    ) {
      if (failure == null || failure.sessionId != _session?.id) return;
      setState(() => _error = _describe(failure.error));
    });
    final session = ref.watch(chatProvider(widget.charId)).value?.session;
    final messages = session?.messages ?? const <ChatMessage>[];
    final regeneration = ref.watch(summaryRegenerationProvider);
    final regenerating = session != null && regeneration.isBusy(session.id);
    final blockTarget = ref
        .watch(summaryCompactionSettingsProvider)
        .value
        ?.blockTargetTokens;
    final compacting = session == null
        ? null
        : ref.watch(summaryCompactionProvider.select((s) => s.run(session.id)));
    // The chain is held by one summarizer run at a time, whichever kind.
    final held = _busy || regenerating || compacting != null;
    final byId = SummaryChain.index(messages);
    final active = SummaryChain.ordered(_blocks, messages);
    final archived = _blocks.where((b) => b.archived).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final live = active.where((b) => !SummaryChain.isStale(b, byId));
    final liveTokens = live.fold(0, (sum, b) => sum + b.tokens);
    final covered = {for (final b in live) ...b.messageIds}.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _loading
              ? const SizedBox.shrink()
              : ListView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    MediaQuery.paddingOf(context).top + 8,
                    16,
                    16,
                  ),
                  children: [
                    _Summary(
                      text: active.isEmpty
                          ? 'summary_empty'.tr()
                          : 'summary_stats'.tr(
                              args: [
                                '${live.length}',
                                '$liveTokens',
                                '$covered',
                              ],
                            ),
                    ),
                    const SizedBox(height: 12),
                    for (final block in active)
                      SummaryBlockCard(
                        key: ValueKey(block.id),
                        block: block,
                        title: _title(block),
                        stale: SummaryChain.isStale(block, byId),
                        draftStale: switch (block.draft) {
                          final draft? => SummaryChain.isDraftStale(
                            draft,
                            byId,
                          ),
                          null => false,
                        },
                        selected: _selected.contains(block.id),
                        onToggleSelected: block.isNote
                            ? null
                            : () => setState(() {
                                if (!_selected.remove(block.id)) {
                                  _selected.add(block.id);
                                }
                              }),
                        onEdit: () => _edit(block),
                        onDelete: () => _delete(block),
                        onRegenerate: block.isNote
                            ? null
                            : () => _regenerate(block),
                        onShorten: _canShorten(block, byId, blockTarget)
                            ? () => _shorten(block)
                            : null,
                        generatingSince: session == null
                            ? null
                            : regeneration.since(session.id, block.id),
                        onStop: () => _stop(block),
                        onApprove: () => _approve(block),
                        onDiscardDraft: () => _discardDraft(block),
                        busy: held,
                      ),
                    if (archived.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      GlazeExpansionTile(
                        title: Text(
                          'summary_archive'.tr(args: ['${archived.length}']),
                        ),
                        subtitle: Text('summary_archive_hint'.tr()),
                        children: [
                          for (final block in archived)
                            SummaryBlockCard(
                              key: ValueKey(block.id),
                              block: block,
                              title: _title(block),
                            ),
                        ],
                      ),
                    ],
                    if (_blocks.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      GlazeActionButton(
                        icon: Icons.delete_sweep_outlined,
                        label: 'summary_clear'.tr(),
                        tone: GlazeActionTone.destructive,
                        onTap: held ? null : _clear,
                      ),
                    ],
                  ],
                ),
        ),
        _buildActionBar(
          context,
          regenerating: regenerating,
          compacting: compacting,
        ),
      ],
    );
  }

  /// [regenerating]: a block is being written again, which holds the
  /// summarizer for this chat — compaction and merging wait for it.
  /// [compacting]: the compaction under way, if any; the bar then shows where
  /// it stands and offers Stop in place of Compact.
  Widget _buildActionBar(
    BuildContext context, {
    required bool regenerating,
    required SummaryCompactionRun? compacting,
  }) {
    final error = _error;
    final canMerge = _selected.length >= 2 && compacting == null;
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        MediaQuery.paddingOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.cs.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (canMerge) ...[
            GlazeActionButton(
              icon: Icons.merge_rounded,
              label: 'summary_merge_selected'.tr(args: ['${_selected.length}']),
              tone: GlazeActionTone.primary,
              expand: true,
              busy: _busy,
              onTap: regenerating ? null : _mergeSelected,
            ),
            const SizedBox(height: 8),
          ],
          if (compacting != null) ...[
            _CompactionProgress(
              run: compacting,
              range: _rangeOf(compacting.progress.sourceIds),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: compacting != null
                    ? GlazeActionButton(
                        icon: Icons.stop_rounded,
                        label: compacting.stopping
                            ? 'summary_compact_stopping'.tr()
                            : 'summary_compact_stop'.tr(),
                        tone: GlazeActionTone.primary,
                        expand: true,
                        busy: compacting.stopping,
                        onTap: _stopCompaction,
                      )
                    : GlazeActionButton(
                        icon: Icons.compress_rounded,
                        label: _busy
                            ? 'summary_generating'.tr()
                            : 'summary_compact_now'.tr(),
                        tone: canMerge
                            ? GlazeActionTone.neutral
                            : GlazeActionTone.primary,
                        expand: true,
                        busy: _busy && !canMerge,
                        onTap: regenerating ? null : _compact,
                      ),
              ),
              const SizedBox(width: 8),
              GlazeActionButton(
                icon: Icons.note_add_outlined,
                label: 'summary_note_add'.tr(),
                onTap: _busy || compacting != null ? null : _addNote,
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            GlazeErrorBlock.fromError(error),
          ],
        ],
      ),
    );
  }
}

/// Where the compaction stands: which block is being written over which
/// messages, how many messages are still ahead, and the seconds elapsed.
class _CompactionProgress extends StatelessWidget {
  final SummaryCompactionRun run;

  /// The messages being retold, numbered as the chat counts them.
  final String? range;

  const _CompactionProgress({required this.run, required this.range});

  @override
  Widget build(BuildContext context) {
    final progress = run.progress;
    final retelling = !progress.merging && progress.sourceIds.isNotEmpty;
    final step = progress.merging
        ? 'summary_compacting_merge'.tr()
        : !retelling
        // Planning the first request: nothing to name yet.
        ? 'summary_generating'.tr()
        : 'summary_compacting_retell'.tr(
            namedArgs: {'n': '${progress.created + 1}', 'range': range ?? ''},
          );
    final style = TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(step, style: style),
              if (retelling)
                Text(
                  'summary_compacting_left_n'.plural(
                    progress.remainingMessages,
                  ),
                  style: style,
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        SummaryElapsedLabel(since: run.startedAt),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  final String text;

  const _Summary({required this.text});

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
  );
}
