import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../../shared/widgets/tab_slide_switcher.dart';
import '../../memory/controllers/memory_book_controller.dart';
import 'memory/memory_books_controls.dart';
import 'memory/memory_books_overview.dart';
import 'memory/memory_books_toolbar.dart';
import 'memory/memory_draft_card.dart';
import 'memory/memory_entry_card.dart';
import 'memory/memory_tab_store.dart';
import 'memory_entry_editor_sheet.dart';
import 'memory_generation_settings_sheet.dart';

const Color _kDanger = Color(0xFFFF5252);

/// Memory Books tab of the Memory sheet.
///
/// Built entirely from Glaze surfaces — [GlazeTabBar] for the
/// approved/drafts segmented control, [GlassSurface] tiles and [MenuGroup]
/// rows for the controls — replacing the Material
/// `DefaultTabController` / `TabBar` / `NestedScrollView` / `OutlinedButton`
/// stack this used to be. Expects a bounded height from its host.
class MemoryBooksTab extends ConsumerStatefulWidget {
  final String sessionId;
  final String charId;
  final List<ChatMessage> messages;

  const MemoryBooksTab({
    super.key,
    required this.sessionId,
    required this.charId,
    this.messages = const [],
  });

  @override
  ConsumerState<MemoryBooksTab> createState() => _MemoryBooksTabState();
}

class _MemoryBooksTabState extends ConsumerState<MemoryBooksTab> {
  static const int _tabCount = 2;
  static const int _tabApproved = 0;
  static const MemoryTabStore _tabStore = MemoryTabStore.memoryBooks;

  late final MemoryBookController _ctrl;
  Timer? _elapsedTimer;
  Map<String, String> _embeddingStatuses = {};
  int _tabIndex = _tabApproved;

  @override
  void initState() {
    super.initState();
    _ctrl = MemoryBookController(ref, widget.sessionId, widget.charId);
    _load();
  }

  Future<void> _load() async {
    // Both reads are independent, so the prefs round-trip runs alongside the
    // book load instead of delaying it.
    final bookLoad = _ctrl.load();
    final storedTab = await _tabStore.load(_tabCount);
    await bookLoad;
    if (!mounted) return;
    unawaited(_loadEmbeddingStatuses());
    setState(() => _tabIndex = storedTab);
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

  /// Switching sub-tabs also persists the choice, so reopening the sheet comes
  /// up on the list that was last in use.
  void _setTab(int index) {
    if (index == _tabIndex) return;
    setState(() => _tabIndex = index);
    unawaited(_tabStore.save(index));
  }

  // ─── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final book = _ctrl.book;
    final loading = _ctrl.loading || book == null;
    if (loading) return const Center(child: GlazeSpinner());

    // Studio Ledger entries (`source == 'studio_ledger'`) are legacy and
    // excluded from the UI — they were removed from the injection pipeline.
    final curatedEntries = book.entries
        .where((e) => e.source != 'studio_ledger')
        .toList();
    final scanDrafts = book.pendingDrafts
        .where((d) => d.source != 'studio_ledger')
        .toList();

    final draftsNeedingGen = _ctrl.draftsNeedingGeneration;
    final isGenerating = _ctrl.isGenerating;
    // Vector affordances (retrieval mode, reindex, index badges) only make
    // sense while the active API preset has semantic search switched on.
    final vectorAvailable = ref.watch(vectorSearchAvailableProvider);

    return SwipeTabSwitcher(
      index: _tabIndex,
      length: _tabCount,
      onChanged: _setTab,
      child: ListView(
        // The host sheet reports its header height as MediaQuery top padding;
        // without consuming it the overview card hides behind the sheet header.
        padding: EdgeInsets.fromLTRB(
          0,
          MediaQuery.paddingOf(context).top + 12,
          0,
          MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          MemoryBooksOverview(
            sessionId: widget.sessionId,
            modelLabel: _ctrl.searchModelLabel,
            settingsSummary: _ctrl.settingsSummary,
            searchTypeLabel: _ctrl.searchTypeLabel,
            onCycleSearchType: _cycleSearchType,
            showSearchType: vectorAvailable,
            activeCount: book.entries.where((e) => e.status == 'active').length,
            needsRebuildCount: book.entries
                .where((e) => e.status == 'needs_rebuild')
                .length,
            draftCount: book.pendingDrafts.length,
          ),
          MemoryBooksToolbar(
            onOpenSettings: _openSettings,
            onScanChat: _scanChat,
            onAddEntry: _addEntry,
            isReindexing: _ctrl.isReindexing,
            onReindex: _reindexAll,
            onDeleteIndexes: _deleteAllMemoryIndexes,
            showIndexActions: vectorAvailable,
          ),
          if (draftsNeedingGen.isNotEmpty || isGenerating)
            MemoryBatchPanel(
              pendingCount: draftsNeedingGen.length,
              isGenerating: isGenerating,
              onGenerateBatch: _batchGenerate,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: GlazeTabBar(
              tabs: [
                GlazeTabItem(
                  label: 'memory_books_tab_approved'.tr(
                    args: ['${curatedEntries.length}'],
                  ),
                  icon: Icons.check_circle_outline_rounded,
                ),
                GlazeTabItem(
                  label: 'memory_books_tab_scan_drafts'.tr(
                    args: ['${scanDrafts.length}'],
                  ),
                  icon: Icons.drafts_outlined,
                ),
              ],
              activeIndex: _tabIndex,
              onChanged: _setTab,
            ),
          ),
          TabSlideSwitcher(
            index: _tabIndex,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _tabIndex == _tabApproved
                  ? _buildApprovedTab(curatedEntries)
                  : _buildDraftsTab(scanDrafts),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApprovedTab(List<MemoryEntry> entries) {
    final vectorAvailable = ref.watch(vectorSearchAvailableProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MemorySectionHeader(
          title: 'memory_books_section_approved'.tr(),
          count: entries.length,
        ),
        if (entries.isEmpty)
          _buildEmpty('memory_books_empty_approved'.tr())
        else
          ...entries.map(
            (entry) => MemoryEntryCard(
              key: ValueKey(entry.id),
              entry: entry,
              // No index badge while semantic search is off in the API —
              // there is nothing to be indexed against.
              embeddingStatus: vectorAvailable
                  ? _embeddingStatuses[entry.id]
                  : null,
              onEdit: () => _editEntry(entry),
              onDelete: () => _deleteEntry(entry.id),
            ),
          ),
      ],
    );
  }

  Widget _buildDraftsTab(List<MemoryDraft> drafts) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MemorySectionHeader(
          title: 'memory_books_section_pending'.tr(),
          count: drafts.length,
          action: drafts.length > 1
              ? MemoryActionChip(
                  label: 'memory_books_delete_all_pending'.tr(),
                  color: _kDanger,
                  onTap: _deleteAllDrafts,
                )
              : null,
        ),
        if (drafts.isEmpty)
          _buildEmpty('memory_books_empty_scan_drafts'.tr())
        else
          ...drafts.map(
            (draft) => MemoryDraftCard(
              key: ValueKey(draft.id),
              draft: draft,
              isGenerating: _ctrl.generatingDrafts[draft.id] == true,
              generatingSince: _ctrl.genStartTimes[draft.id],
              onGenerate: () => _generateDraft(draft.id),
              onRegenerate: () => _generateDraft(draft.id),
              onCancel: () => _cancelDraft(draft.id),
              onApprove: () => _approveDraft(draft.id),
              onEdit: () => _editDraft(draft),
              onDelete: () => _deleteDraft(draft.id),
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty(String message) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: context.cs.outlineVariant),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  // ─── Actions delegating to controller ────────────────────────────

  void _cycleSearchType() async {
    await _ctrl.cycleSearchType();
    if (mounted) setState(() {});
  }

  void _scanChat() async {
    final msg = await _ctrl.scanChat();
    if (msg != null && mounted) {
      setState(() {});
      GlazeToast.show(context, msg);
    }
  }

  void _generateDraft(String draftId) {
    final drafts = _ctrl.book?.pendingDrafts ?? const <MemoryDraft>[];
    final draftIndex = drafts.indexWhere((draft) => draft.id == draftId);
    final isRegeneration =
        draftIndex >= 0 && drafts[draftIndex].content.isNotEmpty;
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
          final label = isRegeneration
              ? 'memory_books_regeneration_failed'.tr()
              : 'error_generation'.tr();
          GlazeToast.show(context, '$label: $error');
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
      keyParagraphs: draft.keyParagraphs,
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
}
