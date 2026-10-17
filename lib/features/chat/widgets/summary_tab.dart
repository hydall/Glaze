import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/summary_block.dart';
import '../../../core/state/summary_providers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/fullscreen_editor.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../../../shared/widgets/glaze_expansion_tile.dart';
import '../chat_provider.dart';
import '../services/summary_generation_service.dart';
import 'memory/memory_books_controls.dart';

const Color _kOrange = Color(0xFFFF9800);

/// Summary tab of the Memory sheet.
///
/// The summary is a chain of blocks (see [SummaryBlock]): each retells a run
/// of old messages and is sent in their place. The tab lists the active
/// chain in story order, the archive of merged-away blocks below it, and the
/// actions that change the chain — compact now, merge a selection, add a note.
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
  Future<void> _run(Future<void> Function(ChatSession session) action) async {
    final session = _session;
    if (session == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(session);
    } catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Object _describe(Object error) {
    if (error is! SummaryChainException) return error;
    return switch (error.reason) {
      'busy' => 'summary_error_busy'.tr(),
      'not_shorter' => 'summary_error_not_shorter'.tr(),
      'not_adjacent' => 'summary_error_not_adjacent'.tr(),
      'mixed_levels' => 'summary_error_mixed_levels'.tr(),
      'select_two' => 'summary_error_select_two'.tr(),
      _ => 'summary_error_changed'.tr(),
    };
  }

  SummaryGenerationService get _generator =>
      ref.read(summaryGenerationServiceProvider);

  Future<void> _compact() => _run((session) async {
    final result = await _generator.compact(
      charId: widget.charId,
      session: session,
      force: true,
    );
    if (!result.changed && mounted) {
      setState(() => _error = 'summary_nothing_to_compact'.tr());
    }
  });

  Future<void> _mergeSelected() => _run((session) async {
    await _generator.mergeSelected(session: session, blockIds: {..._selected});
    _selected.clear();
  });

  Future<void> _addNote() async {
    var text = '';
    await FullscreenEditorScreen.show(
      context,
      title: 'summary_note_add'.tr(),
      initialValue: '',
      hintText: 'summary_note_hint'.tr(),
      onChanged: (value) => text = value,
    );
    if (text.trim().isEmpty) return;
    await _run(
      (session) => _generator.addNote(session: session, content: text),
    );
  }

  Future<void> _edit(SummaryBlock block) async {
    var text = block.content;
    await FullscreenEditorScreen.show(
      context,
      title: _title(block),
      initialValue: block.content,
      onChanged: (value) => text = value,
    );
    if (text.trim() == block.content.trim()) return;
    await _run(
      (session) => _generator.editBlock(
        session: session,
        blockId: block.id,
        content: text,
      ),
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

  static String _title(SummaryBlock block) => block.isNote
      ? 'summary_note'.tr()
      : 'summary_block_level'.tr(args: ['${block.level}']);

  @override
  Widget build(BuildContext context) {
    // Auto-compaction writes from the background; follow it.
    ref.listen(summaryRevisionProvider, (_, _) => _load());
    final messages =
        ref.watch(chatProvider(widget.charId)).value?.session?.messages ??
        const <ChatMessage>[];
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
                      _BlockCard(
                        block: block,
                        title: _title(block),
                        stale: SummaryChain.isStale(block, byId),
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
                            _BlockCard(block: block, title: _title(block)),
                        ],
                      ),
                    ],
                    if (_blocks.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      GlazeActionButton(
                        icon: Icons.delete_sweep_outlined,
                        label: 'summary_clear'.tr(),
                        tone: GlazeActionTone.destructive,
                        onTap: _busy ? null : _clear,
                      ),
                    ],
                  ],
                ),
        ),
        _buildActionBar(context),
      ],
    );
  }

  Widget _buildActionBar(BuildContext context) {
    final error = _error;
    final canMerge = _selected.length >= 2;
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
              onTap: _mergeSelected,
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: GlazeActionButton(
                  icon: Icons.compress_rounded,
                  label: _busy
                      ? 'summary_generating'.tr()
                      : 'summary_compact_now'.tr(),
                  tone: canMerge
                      ? GlazeActionTone.neutral
                      : GlazeActionTone.primary,
                  expand: true,
                  busy: _busy && !canMerge,
                  onTap: _compact,
                ),
              ),
              const SizedBox(width: 8),
              GlazeActionButton(
                icon: Icons.note_add_outlined,
                label: 'summary_note_add'.tr(),
                onTap: _busy ? null : _addNote,
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

class _Summary extends StatelessWidget {
  final String text;

  const _Summary({required this.text});

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
  );
}

/// One block. Archived blocks are shown read-only: no selection, no menu.
class _BlockCard extends StatelessWidget {
  final SummaryBlock block;
  final String title;
  final bool stale;
  final bool selected;
  final VoidCallback? onToggleSelected;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _BlockCard({
    required this.block,
    required this.title,
    this.stale = false,
    this.selected = false,
    this.onToggleSelected,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final subtitle = [
      if (!block.isNote) 'memory_messages_n'.plural(block.messageIds.length),
      'summary_tokens_n'.tr(args: ['${block.tokens}']),
      if (block.sourceTokens > 0)
        'summary_from_tokens_n'.tr(args: ['${block.sourceTokens}']),
    ].join(' • ');
    return MemoryRow(
      accent: stale
          ? _kOrange
          : selected
          ? cs.primary
          : null,
      onTap: onEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (onToggleSelected != null) ...[
                InkResponse(
                  onTap: onToggleSelected,
                  radius: 18,
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (stale)
                MemoryStatusIcon(
                  icon: Icons.build_circle_outlined,
                  label: 'summary_block_stale'.tr(),
                  color: _kOrange,
                ),
              if (onEdit != null && onDelete != null)
                MemoryRowMenuButton(
                  title: title,
                  itemsBuilder: (menuContext) => [
                    BottomSheetItem(
                      icon: Icons.edit_outlined,
                      label: 'action_edit'.tr(),
                      onTap: () {
                        Navigator.of(menuContext, rootNavigator: true).pop();
                        onEdit!();
                      },
                    ),
                    BottomSheetItem(
                      icon: Icons.delete_outline,
                      label: 'btn_delete'.tr(),
                      isDestructive: true,
                      onTap: () {
                        Navigator.of(menuContext, rootNavigator: true).pop();
                        onDelete!();
                      },
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            stale ? 'summary_block_stale'.tr() : subtitle,
            style: TextStyle(
              fontSize: 11,
              color: stale
                  ? _kOrange
                  : cs.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            block.content,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
