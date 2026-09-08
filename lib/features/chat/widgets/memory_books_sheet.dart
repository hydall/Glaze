import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../memory/controllers/memory_book_controller.dart';
import '../../memory/utils/memory_swipe_filter.dart';
import 'memory_entry_editor_sheet.dart';
import 'memory_generation_settings_sheet.dart';

class MemoryBooksSheet extends ConsumerStatefulWidget {
  final String sessionId;
  final String charId;
  final List<ChatMessage> messages;

  const MemoryBooksSheet({
    super.key,
    required this.sessionId,
    required this.charId,
    this.messages = const [],
  });

  @override
  ConsumerState<MemoryBooksSheet> createState() => _MemoryBooksSheetState();
}

class _MemoryBooksSheetState extends ConsumerState<MemoryBooksSheet> {
  late final MemoryBookController _ctrl;
  Timer? _elapsedTimer;
  bool _hideUnselectedMemories = false;
  Map<String, String> _embeddingStatuses = {};

  @override
  void initState() {
    super.initState();
    _ctrl = MemoryBookController(ref, widget.sessionId, widget.charId);
    _load();
  }

  Future<void> _load() async {
    await _ctrl.load();
    if (mounted) {
      unawaited(_loadEmbeddingStatuses());
      setState(() {});
    }
  }

  Future<void> _loadEmbeddingStatuses() async {
    final repo = ref.read(embeddingRepoProvider);
    final book = _ctrl.book;
    if (book == null) return;
    final statuses = <String, String>{};
    for (final entry in book.entries) {
      final record = await repo.getByEntryId(entry.id);
      if (record == null) {
        statuses[entry.id] = 'none';
      } else if (record.errorJson != null) {
        statuses[entry.id] = 'error';
      } else if (repo.hasUsableVectors(record)) {
        statuses[entry.id] = 'indexed';
      } else {
        statuses[entry.id] = 'none';
      }
    }
    if (mounted) setState(() => _embeddingStatuses = statuses);
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _startElapsedTimer() {
    _elapsedTimer ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_ctrl.generatingDrafts.isNotEmpty && mounted) setState(() {});
    });
  }

  void _stopElapsedTimer() {
    if (_ctrl.generatingDrafts.isEmpty) {
      _elapsedTimer?.cancel();
      _elapsedTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // GlazeBottomSheet wraps `child` in a SingleChildScrollView, which gives
    // an UNBOUNDED height constraint. This sheet uses a Column with an
    // Expanded TabBarView, which needs a bounded height — without it the
    // RenderFlex collapses and only the drag handle shows. Pin the sheet to a
    // fraction of the screen so the tab content has a real height to lay out in.
    final screenH = MediaQuery.of(context).size.height;
    return SizedBox(height: screenH * 0.85, child: _buildBody(context));
  }

  Widget _buildBody(BuildContext context) {
    if (_ctrl.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final settings = _ctrl.globalSettings;
    final book = _ctrl.book!;
    final entries = book.entries;
    final pendingDrafts = book.pendingDrafts;
    final activeCount = entries.where((e) => e.status == 'active').length;
    final needsRebuildCount = entries
        .where((e) => e.status == 'needs_rebuild')
        .length;
    final draftsNeedingGen = _ctrl.draftsNeedingGeneration;
    final isGenerating = _ctrl.isGenerating;

    final scanDrafts = pendingDrafts
        .where((d) => d.source != 'studio_ledger')
        .toList();
    // Studio Ledger entries (`source == 'studio_ledger'`) are legacy and
    // excluded from the UI — they were removed from the injection pipeline.
    final curatedEntries = entries
        .where((e) => e.source != 'studio_ledger')
        .toList();

    // Swipe filter: when enabled, only show entries that were injected via
    // triggeredMemories for the current swipes, or entries whose source
    // message is currently visible.
    final selectedMemoryIds = MemorySwipeFilter.selectedSwipeMemoryIds(
      widget.messages,
    );
    final selectedSourceMessageIds =
        MemorySwipeFilter.selectedSwipeSourceMessageIds(widget.messages);
    final selectedSourceKeys = MemorySwipeFilter.selectedSwipeSourceKeys(
      widget.messages,
    );

    bool filterFn(MemoryEntry e) => MemorySwipeFilter.entryMatches(
      e,
      hideUnselected: _hideUnselectedMemories,
      selectedMemoryIds: selectedMemoryIds,
      selectedSourceMessageIds: selectedSourceMessageIds,
      selectedSourceKeys: selectedSourceKeys,
    );

    final filteredCurated = curatedEntries.where(filterFn).toList();
    return DefaultTabController(
      length: 2,
      child: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildOverview(settings),
                    const SizedBox(height: 12),
                    _buildSearchTypeSelector(settings),
                    const SizedBox(height: 12),
                    _buildStatusSummary(
                      activeCount,
                      needsRebuildCount,
                      pendingDrafts.length,
                    ),
                    const SizedBox(height: 12),
                    _buildActionButtons(),
                    if (draftsNeedingGen.isNotEmpty || isGenerating) ...[
                      const SizedBox(height: 12),
                      _buildBatchActions(draftsNeedingGen, isGenerating),
                    ],
                  ],
                ),
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedTabBarDelegate(
                TabBar(
                  tabs: [
                    Tab(
                      text: 'memory_books_tab_approved'.tr(
                        args: [filteredCurated.length.toString()],
                      ),
                    ),
                    Tab(
                      text: 'memory_books_tab_scan_drafts'.tr(
                        args: [scanDrafts.length.toString()],
                      ),
                    ),
                  ],
                  tabAlignment: TabAlignment.fill,
                ),
              ),
            ),
          ];
        },
        body: TabBarView(
          children: [
            _buildApprovedTab(filteredCurated),
            _buildScanDraftsTab(scanDrafts),
          ],
        ),
      ),
    );
  }

  Widget _buildApprovedTab(List<MemoryEntry> curatedEntries) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (curatedEntries.isEmpty)
            Text(
              'memory_books_empty_approved'.tr(),
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
            )
          else
            _buildApprovedSection(curatedEntries),
        ],
      ),
    );
  }

  Widget _buildScanDraftsTab(List<MemoryDraft> scanDrafts) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (scanDrafts.isEmpty)
            Text(
              'memory_books_empty_scan_drafts'.tr(),
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
            )
          else ...[
            _buildPendingDraftsSection(scanDrafts),
          ],
        ],
      ),
    );
  }

  // ─── Overview ────────────────────────────────────────────────────

  Widget _buildOverview(MemoryGlobalSettings settings) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'magic_memory_books'.tr(),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: context.cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${'memory_books_session'.tr()} ${widget.sessionId.substring(0, 8)}...',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: context.cs.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _ctrl.searchModelLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.cs.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _ctrl.settingsSummary,
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // ─── Search type ─────────────────────────────────────────────────

  Widget _buildSearchTypeSelector(MemoryGlobalSettings settings) {
    return GestureDetector(
      onTap: () async {
        await _ctrl.cycleSearchType();
        if (mounted) setState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'label_search_type'.tr(),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
            Row(
              children: [
                Text(
                  _ctrl.searchTypeLabel,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_drop_down,
                  size: 20,
                  color: context.cs.onSurfaceVariant,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── Status summary ──────────────────────────────────────────────

  Widget _buildStatusSummary(int active, int needsRebuild, int drafts) {
    return Row(
      children: [
        Expanded(
          child: _statusCard(
            '$active',
            'memory_books_status_active'.tr(),
            Colors.green,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _statusCard(
            '$needsRebuild',
            'memory_books_entry_needs_rebuild'.tr(),
            Colors.orange,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _statusCard(
            '$drafts',
            'memory_books_status_drafts'.tr(),
            Colors.amber,
          ),
        ),
      ],
    );
  }

  Widget _statusCard(String value, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // ─── Action buttons ──────────────────────────────────────────────

  Widget _buildActionButtons() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _openSettings,
                icon: Icon(
                  Icons.settings,
                  size: 16,
                  color: context.cs.onSurfaceVariant,
                ),
                label: Text(
                  'title_settings'.tr(),
                  style: TextStyle(color: context.cs.onSurface),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _scanChat,
                icon: Icon(
                  Icons.search,
                  size: 16,
                  color: context.cs.onSurfaceVariant,
                ),
                label: Text(
                  'memory_books_btn_scan_chat'.tr(),
                  style: TextStyle(color: context.cs.onSurface),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _addEntry,
                icon: const Icon(Icons.add, size: 16),
                label: Text('action_add'.tr()),
                style: FilledButton.styleFrom(
                  backgroundColor: context.cs.primary,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _ctrl.isReindexing ? null : _reindexAll,
                icon: Icon(
                  Icons.storage,
                  size: 16,
                  color: context.cs.onSurfaceVariant,
                ),
                label: Text(
                  _ctrl.isReindexing
                      ? 'btn_indexing'.tr()
                      : 'memory_books_btn_reindex'.tr(),
                  style: TextStyle(color: context.cs.onSurface),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _ctrl.isReindexing ? null : _deleteAllMemoryIndexes,
                icon: Icon(
                  Icons.delete_sweep,
                  size: 16,
                  color: Colors.redAccent.withValues(alpha: 0.7),
                ),
                label: Text(
                  'action_delete_indexes'.tr(),
                  style: TextStyle(color: context.cs.onSurfaceVariant),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: Colors.redAccent.withValues(alpha: 0.2),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _dedupMemories,
                icon: Icon(
                  Icons.auto_fix_high,
                  size: 16,
                  color: context.cs.onSurfaceVariant,
                ),
                label: Text(
                  'Dedup',
                  style: TextStyle(color: context.cs.onSurface),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilterChip(
                label: Text(
                  'Only selected swipes',
                  style: TextStyle(
                    fontSize: 12,
                    color: _hideUnselectedMemories
                        ? context.cs.primary
                        : context.cs.onSurfaceVariant,
                  ),
                ),
                selected: _hideUnselectedMemories,
                onSelected: (v) => setState(() => _hideUnselectedMemories = v),
                showCheckmark: false,
                avatar: Icon(
                  Icons.visibility_off,
                  size: 14,
                  color: _hideUnselectedMemories
                      ? context.cs.primary
                      : context.cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBatchActions(List<MemoryDraft> needsGen, bool isGenerating) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.cs.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isGenerating
                ? 'memory_books_badge_generating'.tr()
                : '${needsGen.length} ${'memory_books_needs_generation'.tr()}',
            style: TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: needsGen.isNotEmpty ? _batchGenerate : null,
            style: FilledButton.styleFrom(
              backgroundColor: context.cs.primary,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              isGenerating
                  ? 'memory_books_btn_generate_remaining'.tr()
                  : 'memory_books_btn_generate_batch'.tr(),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Pending Drafts section ──────────────────────────────────────

  Widget _buildPendingDraftsSection(List<MemoryDraft> drafts) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'memory_books_section_pending'.tr(),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: context.cs.onSurface,
              ),
            ),
            const Spacer(),
            if (drafts.length > 1)
              TextButton(
                onPressed: _deleteAllDrafts,
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                child: Text(
                  'memory_books_delete_all_pending'.tr(),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${drafts.length}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...drafts.map((draft) => _buildDraftCard(draft)),
      ],
    );
  }

  Widget _buildDraftCard(MemoryDraft draft) {
    final isGen = _ctrl.generatingDrafts[draft.id] == true;
    final needsGen =
        draft.content.isEmpty &&
        (draft.status == 'pending_generation' ||
            draft.status == 'needs_regeneration');
    final needsRegen = draft.status == 'needs_regeneration';
    final hasContent = draft.content.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isGen
            ? Colors.amber.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: isGen
            ? Border.all(color: Colors.amber.withValues(alpha: 0.4))
            : needsRegen
            ? Border.all(color: Colors.redAccent.withValues(alpha: 0.3))
            : Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      draft.title.isNotEmpty
                          ? draft.title
                          : 'memory_books_untitled_draft'.tr(),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: context.cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _draftStatusLabel(draft, isGen),
                      style: TextStyle(
                        fontSize: 12,
                        color: _draftStatusColor(draft, isGen),
                      ),
                    ),
                  ],
                ),
              ),
              _draftStatusBadge(draft, isGen),
            ],
          ),
          if (draft.content.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              draft.content.length > 180
                  ? '${draft.content.substring(0, 180)}...'
                  : draft.content,
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (draft.error != null && needsRegen) ...[
            const SizedBox(height: 4),
            Text(
              draft.error!,
              style: const TextStyle(fontSize: 11, color: Colors.redAccent),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (isGen)
                _actionBtn(
                  'memory_books_btn_stop'.tr(),
                  Colors.amber,
                  () => _cancelDraft(draft.id),
                )
              else if (needsGen || needsRegen)
                _actionBtn(
                  'memory_books_btn_generate'.tr(),
                  Colors.amber,
                  () => _generateDraft(draft.id),
                )
              else if (hasContent)
                _actionBtn(
                  'memory_books_btn_approve'.tr(),
                  Colors.green,
                  () => _approveDraft(draft.id),
                ),
              const SizedBox(width: 6),
              if (hasContent && !isGen)
                _actionBtn(
                  'action_edit'.tr(),
                  context.cs.primary,
                  () => _editDraft(draft),
                ),
              const SizedBox(width: 6),
              _actionBtn(
                'btn_delete'.tr(),
                Colors.redAccent,
                () => _deleteDraft(draft.id),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionBtn(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }

  String _draftStatusLabel(MemoryDraft draft, bool isGen) {
    if (isGen) {
      final start = _ctrl.genStartTimes[draft.id];
      if (start != null) {
        final elapsed =
            DateTime.now().difference(start).inMilliseconds / 1000.0;
        return "${'memory_books_generating_elapsed'.tr()} ${elapsed.toStringAsFixed(1)}s";
      }
      return 'memory_books_generating_elapsed'.tr();
    }
    if (draft.status == 'needs_regeneration') {
      return 'memory_books_badge_needs_regen'.tr();
    }
    if (draft.content.isEmpty && draft.status == 'pending_generation') {
      return 'memory_books_needs_generation'.tr();
    }
    if (draft.content.isNotEmpty) return 'memory_books_pending_approval'.tr();
    return draft.status;
  }

  Color _draftStatusColor(MemoryDraft draft, bool isGen) {
    if (isGen) return Colors.amber;
    if (draft.status == 'needs_regeneration') return Colors.redAccent;
    if (draft.content.isEmpty) return Colors.amber;
    return context.cs.onSurfaceVariant;
  }

  Widget _draftStatusBadge(MemoryDraft draft, bool isGen) {
    final (String label, Color color) = isGen
        ? ('memory_books_badge_generating'.tr(), Colors.amber)
        : draft.status == 'needs_regeneration'
        ? ('memory_books_badge_needs_regen'.tr(), Colors.redAccent)
        : draft.content.isEmpty && draft.status == 'pending_generation'
        ? ('memory_books_badge_needs_gen'.tr(), Colors.amber)
        : ('memory_books_badge_draft'.tr(), Colors.cyan);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  // ─── Approved section ────────────────────────────────────────────

  Widget _buildApprovedSection(List<MemoryEntry> entries) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'memory_books_section_approved'.tr(),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: context.cs.onSurface,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${entries.length}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (entries.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                'memory_books_no_entries'.tr(),
                style: TextStyle(
                  fontSize: 13,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          ...entries.map((entry) => _buildEntryCard(entry)),
      ],
    );
  }

  Widget _buildEntryCard(MemoryEntry entry) {
    final isActive = entry.status == 'active';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isActive
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(12),
        border: entry.status == 'needs_rebuild'
            ? Border.all(color: Colors.orange.withValues(alpha: 0.3))
            : Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title.isNotEmpty
                          ? entry.title
                          : 'memory_books_untitled_memory'.tr(),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isActive
                            ? context.cs.onSurface
                            : context.cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${entry.status == "needs_rebuild" ? "memory_books_entry_needs_rebuild".tr() : "memory_books_entry_active".tr()} • ${entry.messageIds.length} msgs • ${entry.keys.take(3).join(", ")}',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _entryStatusBadge(entry),
            ],
          ),
          if (entry.content.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              entry.content.length > 180
                  ? '${entry.content.substring(0, 180)}...'
                  : entry.content,
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _actionBtn(
                'action_edit'.tr(),
                context.cs.primary,
                () => _editEntry(entry),
              ),
              const SizedBox(width: 6),
              _actionBtn(
                'btn_delete'.tr(),
                Colors.redAccent,
                () => _deleteEntry(entry.id),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _entryStatusBadge(MemoryEntry entry) {
    final isActive = entry.status == 'active';
    final embStatus = _embeddingStatuses[entry.id];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (embStatus == 'indexed')
          _badge('idx', Colors.cyan)
        else if (embStatus == 'error')
          _badge('!', Colors.orange)
        else if (embStatus == 'none')
          _badge('○', Colors.grey),
        const SizedBox(width: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: (isActive ? Colors.green : Colors.orange).withValues(
              alpha: 0.1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            isActive ? 'ACTIVE' : 'REBUILD',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isActive ? Colors.green : Colors.orange,
            ),
          ),
        ),
      ],
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  // ─── Actions delegating to controller ────────────────────────────

  void _scanChat() async {
    final msg = await _ctrl.scanChat();
    if (msg != null && mounted) {
      setState(() {});
      GlazeToast.show(context, msg);
    }
  }

  void _generateDraft(String draftId) {
    _ctrl.generateDraft(
      draftId,
      onStart: () {
        if (mounted) {
          setState(() {});
          _startElapsedTimer();
        }
      },
      onComplete: () {
        if (mounted) {
          setState(() {});
          _stopElapsedTimer();
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {});
          _stopElapsedTimer();
          GlazeToast.show(context, "${'error_generation'.tr()}: $error");
        }
      },
    );
  }

  void _cancelDraft(String draftId) {
    _ctrl.cancelDraftGeneration(draftId);
    if (mounted) setState(() {});
  }

  void _batchGenerate() {
    _ctrl.batchGenerate(
      onStart: () {
        if (mounted) {
          setState(() {});
          _startElapsedTimer();
        }
      },
      onComplete: () {
        if (mounted) {
          setState(() {});
          _stopElapsedTimer();
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {});
          _stopElapsedTimer();
          GlazeToast.show(context, "${'error_generation'.tr()}: $error");
        }
      },
    );
  }

  void _approveDraft(String draftId) async {
    await _ctrl.approveDraft(draftId);
    if (mounted) setState(() {});
  }

  void _deleteDraft(String draftId) async {
    await _ctrl.deleteDraft(draftId);
    if (mounted) setState(() {});
  }

  void _deleteAllDrafts() async {
    await _ctrl.deleteAllDrafts();
    if (mounted) setState(() {});
  }

  void _deleteEntry(String entryId) async {
    await _ctrl.deleteEntry(entryId);
    if (mounted) setState(() {});
  }

  void _openSettings() async {
    final currentSettings = _ctrl.globalSettingsAsBookSettings();
    final newResult = await GlazeBottomSheet.show<MemorySettingsSheetResult>(
      context,
      title: 'memory_books_settings_title'.tr(),
      child: MemoryGenerationSettingsSheet(
        settings: currentSettings,
        sessionId: widget.sessionId,
      ),
    );
    if (newResult != null && mounted) {
      await _ctrl.updateSettings(newResult.settings, newResult.vectorThreshold);
      if (mounted) setState(() {});
    }
  }

  void _reindexAll() async {
    setState(() {});
    final msg = await _ctrl.reindexAll();
    if (mounted) {
      setState(() {});
      if (msg != null) {
        if (msg.startsWith('Reindex failed') || msg.startsWith('Set up')) {
          GlazeErrorDialog.show(context, msg);
        } else {
          GlazeToast.show(context, msg);
        }
      }
    }
  }

  void _deleteAllMemoryIndexes() async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'action_delete_indexes'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'action_delete_indexes_confirm'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (confirmed != true) return;
    await _ctrl.deleteAllMemoryIndexes();
    if (mounted) GlazeToast.show(context, 'export_success'.tr());
  }

  void _editEntry(MemoryEntry entry) async {
    final result = await GlazeBottomSheet.show<MemoryEntry>(
      context,
      title: entry.title.isNotEmpty ? entry.title : 'action_edit'.tr(),
      child: MemoryEntryEditorSheet(entry: entry),
    );
    if (result != null && mounted) {
      await _ctrl.editEntry(entry, result);
      if (mounted) setState(() {});
    }
  }

  void _addEntry() async {
    final entry = MemoryEntry(
      id: 'mem_${DateTime.now().millisecondsSinceEpoch}',
      status: 'active',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final result = await GlazeBottomSheet.show<MemoryEntry>(
      context,
      title: 'action_create_new'.tr(),
      child: MemoryEntryEditorSheet(entry: entry),
    );
    if (result != null && mounted) {
      await _ctrl.addEntry(result);
      if (mounted) setState(() {});
    }
  }

  void _editDraft(MemoryDraft draft) async {
    final entry = MemoryEntry(
      id: draft.id,
      title: draft.title,
      content: draft.content,
      keys: draft.keys,
      messageIds: draft.messageIds,
      status: 'active',
      createdAt: draft.createdAt,
    );
    final result = await GlazeBottomSheet.show<MemoryEntry>(
      context,
      title: 'action_edit'.tr(),
      child: MemoryEntryEditorSheet(entry: entry),
    );
    if (result != null && mounted) {
      await _ctrl.editDraft(draft, result);
      if (mounted) setState(() {});
    }
  }

  void _dedupMemories() async {
    Set<String>? entryIds;
    if (_hideUnselectedMemories) {
      entryIds = MemorySwipeFilter.selectedSwipeMemoryIds(widget.messages);
    }

    GlazeToast.show(context, 'Deduplicating memories...');

    final toastText = await _ctrl.runDedup(entryIds: entryIds);

    if (!mounted) return;
    GlazeToast.show(context, toastText);
  }
}

/// Pinned sliver header for the TabBar inside [MemoryBooksSheet]'s
/// NestedScrollView. Keeps the tab bar visible while the header scrolls away.
class _PinnedTabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;

  _PinnedTabBarDelegate(this.tabBar);

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.95),
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(_PinnedTabBarDelegate oldDelegate) =>
      tabBar != oldDelegate.tabBar;
}
