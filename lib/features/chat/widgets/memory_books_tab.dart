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
import '../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../../shared/widgets/tab_slide_switcher.dart';
import '../../memory/controllers/memory_book_controller.dart';
import 'memory/memory_books_toolbar.dart';
import 'memory/memory_draft_card.dart';
import 'memory/memory_entry_card.dart';
import 'memory/memory_tab_store.dart';
import 'memory_entry_editor_sheet.dart';
import 'memory_generation_settings_sheet.dart';

/// What an approved entry can be narrowed to. The counters that used to be
/// three read-only tiles are these chips: the number is still on screen, and
/// it now does something.
enum _EntryFilter { all, active, needsRebuild }

/// The same for drafts — the three states a draft is actually triaged by.
enum _DraftFilter { all, ready, needsGeneration, failed }

/// What the host sheet drives from its own chrome: the settings button in the
/// header and the extended FAB over the list. The tab owns the controller, so
/// it hands these out once it is mounted rather than the sheet reaching into
/// it.
class MemoryBooksActions {
  final VoidCallback openSettings;
  final VoidCallback scanChat;
  final VoidCallback addEntry;
  final VoidCallback reindex;
  final VoidCallback deleteIndexes;
  final VoidCallback? deleteAllDrafts;
  final bool isReindexing;
  final bool showIndexActions;

  const MemoryBooksActions({
    required this.openSettings,
    required this.scanChat,
    required this.addEntry,
    required this.reindex,
    required this.deleteIndexes,
    required this.deleteAllDrafts,
    required this.isReindexing,
    required this.showIndexActions,
  });
}

/// Memory Books tab of the Memory sheet — "Shelf" layout.
///
/// The tab strip and the search box are pinned above the list, so they stay
/// reachable while scrolling and stay off `TopEdgeBlur`'s raster path; the
/// configuration, the toolbar and the rows scroll under them. Expects a
/// bounded height from its host.
class MemoryBooksTab extends ConsumerStatefulWidget {
  final String sessionId;
  final String charId;
  final List<ChatMessage> messages;

  /// Published whenever the set changes, so the host sheet can render the
  /// header button and the FAB from it.
  final ValueChanged<MemoryBooksActions>? onActions;

  const MemoryBooksTab({
    super.key,
    required this.sessionId,
    required this.charId,
    this.messages = const [],
    this.onActions,
  });

  @override
  ConsumerState<MemoryBooksTab> createState() => _MemoryBooksTabState();
}

class _MemoryBooksTabState extends ConsumerState<MemoryBooksTab> {
  static const int _tabCount = 2;
  static const int _tabApproved = 0;
  static const MemoryTabStore _tabStore = MemoryTabStore.memoryBooks;

  late final MemoryBookController _ctrl;
  late final TextEditingController _searchCtrl;
  Map<String, String> _embeddingStatuses = {};
  int _tabIndex = _tabApproved;
  String _query = '';
  _EntryFilter _entryFilter = _EntryFilter.all;
  _DraftFilter _draftFilter = _DraftFilter.all;

  @override
  void initState() {
    super.initState();
    _ctrl = MemoryBookController(ref, widget.sessionId, widget.charId);
    _searchCtrl = TextEditingController();
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
    _searchCtrl.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  /// Switching sub-tabs also persists the choice, so reopening the sheet comes
  /// up on the list that was last in use.
  void _setTab(int index) {
    if (index == _tabIndex) return;
    setState(() => _tabIndex = index);
    unawaited(_tabStore.save(index));
  }

  // ─── Filtering ───────────────────────────────────────────────────

  /// Matches the title, the body and the keys — the three places a memory can
  /// be recognised from. Case-insensitive; an empty query matches everything.
  bool _matchesQuery(String title, String content, List<String> keys) {
    if (_query.isEmpty) return true;
    final needle = _query.toLowerCase();
    if (title.toLowerCase().contains(needle)) return true;
    if (content.toLowerCase().contains(needle)) return true;
    return keys.any((key) => key.toLowerCase().contains(needle));
  }

  bool _passesEntryFilter(MemoryEntry entry) => switch (_entryFilter) {
    _EntryFilter.all => true,
    _EntryFilter.active => entry.status == 'active',
    _EntryFilter.needsRebuild => entry.status == 'needs_rebuild',
  };

  bool _passesDraftFilter(MemoryDraft draft) => switch (_draftFilter) {
    _DraftFilter.all => true,
    _DraftFilter.ready => draft.content.isNotEmpty,
    _DraftFilter.needsGeneration =>
      draft.content.isEmpty && draft.status == 'pending_generation',
    _DraftFilter.failed => draft.status == 'needs_regeneration',
  };

  String _entryFilterLabel(_EntryFilter filter, List<MemoryEntry> entries) {
    final count = switch (filter) {
      _EntryFilter.all => entries.length,
      _EntryFilter.active => entries.where((e) => e.status == 'active').length,
      _EntryFilter.needsRebuild => entries
          .where((e) => e.status == 'needs_rebuild')
          .length,
    };
    final label = switch (filter) {
      _EntryFilter.all => 'memory_books_filter_all'.tr(),
      _EntryFilter.active => 'memory_books_filter_active'.tr(),
      _EntryFilter.needsRebuild => 'memory_books_filter_rebuild'.tr(),
    };
    return '$label $count';
  }

  String _draftFilterLabel(_DraftFilter filter, List<MemoryDraft> drafts) {
    final count = switch (filter) {
      _DraftFilter.all => drafts.length,
      _DraftFilter.ready => drafts.where((d) => d.content.isNotEmpty).length,
      _DraftFilter.needsGeneration => drafts
          .where(
            (d) => d.content.isEmpty && d.status == 'pending_generation',
          )
          .length,
      _DraftFilter.failed => drafts
          .where((d) => d.status == 'needs_regeneration')
          .length,
    };
    final label = switch (filter) {
      _DraftFilter.all => 'memory_books_filter_all'.tr(),
      _DraftFilter.ready => 'memory_books_filter_ready'.tr(),
      _DraftFilter.needsGeneration => 'memory_books_filter_drafts'.tr(),
      _DraftFilter.failed => 'memory_books_filter_failed'.tr(),
    };
    return '$label $count';
  }

  // ─── Build ───────────────────────────────────────────────────────

  /// Published after the frame, never during build: the host rebuilds on it.
  void _publishActions(int draftCount, bool vectorAvailable) {
    final publish = widget.onActions;
    if (publish == null) return;
    final actions = MemoryBooksActions(
      openSettings: _openSettings,
      scanChat: _scanChat,
      addEntry: _addEntry,
      reindex: _reindexAll,
      deleteIndexes: _deleteAllMemoryIndexes,
      deleteAllDrafts: draftCount > 1 ? _deleteAllDrafts : null,
      isReindexing: _ctrl.isReindexing,
      showIndexActions: vectorAvailable,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) publish(actions);
    });
  }

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
    // Vector affordances (reindex, index badges, the index filter) only make
    // sense while the active API preset has semantic search switched on.
    final vectorAvailable = ref.watch(vectorSearchAvailableProvider);
    _publishActions(scanDrafts.length, vectorAvailable);

    return Column(
      children: [
        // The host sheet reports its header height as MediaQuery top padding;
        // the pinned controls start below it so they do not sit under the
        // blurred strip the sheet paints over the top of its body.
        SizedBox(height: MediaQuery.paddingOf(context).top + 8),
        _buildPinnedControls(curatedEntries, scanDrafts),
        Expanded(
          child: SwipeTabSwitcher(
            index: _tabIndex,
            length: _tabCount,
            onChanged: _setTab,
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                0,
                4,
                0,
                // Clears the nav bar and the extended FAB the host floats
                // over the bottom of this list.
                MediaQuery.paddingOf(context).bottom + 88,
              ),
              children: [
                // Drafts only. On the approved tab there is nothing to
                // generate, so this was a panel about the other list.
                if (_tabIndex != _tabApproved &&
                    (draftsNeedingGen.isNotEmpty || isGenerating))
                  MemoryBatchPanel(
                    pendingCount: draftsNeedingGen.length,
                    isGenerating: isGenerating,
                    onGenerateBatch: _batchGenerate,
                  ),
                // Under the batch panel, not above it: the filter narrows the
                // list it sits on top of, and the panel is about the queue.
                _buildFilters(curatedEntries, scanDrafts),
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
          ),
        ),
      ],
    );
  }

  /// The strip and the search box, pinned above the scrolling body.
  ///
  /// The strip is [GlazeTabBarStyle.underline], not the default pill: the host
  /// sheet already carries a filled pill strip for Summary/Books directly
  /// above this one, and two identical controls stacked read as one broken
  /// control. Underline is the kit's answer for a strip that heads a surface
  /// it does not own.
  Widget _buildPinnedControls(
    List<MemoryEntry> entries,
    List<MemoryDraft> drafts,
  ) {
    // Search earns its row only once the list is long enough to need it;
    // below that it is a tall empty field above four rows you can already see.
    final showSearch =
        (_tabIndex == _tabApproved ? entries.length : drafts.length) > 6 ||
        _query.isNotEmpty;
    return Column(
      // The chip bar sizes to its content; a centring Column would inset it
      // from the left while every other row here is full width.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GlazeTabBar(
            style: GlazeTabBarStyle.underline,
            tabs: [
              GlazeTabItem(
                label: 'memory_books_tab_approved'.tr(
                  args: ['${entries.length}'],
                ),
                icon: Icons.check_circle_outline_rounded,
              ),
              GlazeTabItem(
                label: 'memory_books_tab_scan_drafts'.tr(
                  args: ['${drafts.length}'],
                ),
                icon: Icons.drafts_outlined,
              ),
            ],
            activeIndex: _tabIndex,
            onChanged: _setTab,
          ),
        ),
        if (showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: GlazeTextField(
              controller: _searchCtrl,
              hint: 'memory_books_search_hint'.tr(),
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
      ],
    );
  }

  /// The status filter, scrolling with the list rather than pinned: it belongs
  /// to the list it narrows, and under the batch panel rather than above it.
  Widget _buildFilters(List<MemoryEntry> entries, List<MemoryDraft> drafts) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: _tabIndex == _tabApproved
          ? GlazeFilterChipBar<_EntryFilter>(
              current: _entryFilter,
              options: _EntryFilter.values,
              labelBuilder: (filter) => _entryFilterLabel(filter, entries),
              onSelected: (filter) => setState(() => _entryFilter = filter),
            )
          : GlazeFilterChipBar<_DraftFilter>(
              current: _draftFilter,
              options: _DraftFilter.values,
              labelBuilder: (filter) => _draftFilterLabel(filter, drafts),
              onSelected: (filter) => setState(() => _draftFilter = filter),
            ),
    );
  }

  Widget _buildApprovedTab(List<MemoryEntry> entries) {
    final vectorAvailable = ref.watch(vectorSearchAvailableProvider);
    final visible = entries
        .where(
          (entry) =>
              _passesEntryFilter(entry) &&
              _matchesQuery(entry.title, entry.content, entry.keys),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (visible.isEmpty)
          _buildEmpty(
            entries.isEmpty
                ? 'memory_books_empty_approved'.tr()
                : 'memory_books_empty_filtered'.tr(),
          )
        else
          ...visible.map(
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
    final visible = drafts
        .where(
          (draft) =>
              _passesDraftFilter(draft) &&
              _matchesQuery(draft.title, draft.content, draft.keys),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (visible.isEmpty)
          _buildEmpty(
            drafts.isEmpty
                ? 'memory_books_empty_scan_drafts'.tr()
                : 'memory_books_empty_filtered'.tr(),
          )
        else
          ...visible.map(
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
        if (mounted) setState(() {});
      },
      onComplete: () {
        if (mounted) setState(() {});
      },
      onError: (error) {
        if (mounted) {
          setState(() {});
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
        if (mounted) setState(() {});
      },
      onComplete: () {
        if (mounted) setState(() {});
      },
      onError: (error) {
        if (mounted) {
          setState(() {});
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
    final newResult = await MemoryGenerationSettingsSheet.show(
      context,
      settings: currentSettings,
      sessionId: widget.sessionId,
    );
    if (newResult != null && mounted) {
      await _ctrl.updateSettings(newResult.settings, newResult.vectorThreshold);
      if (mounted) setState(() {});
    }
  }

  /// The outcome is a typed value, so the presentation is chosen structurally —
  /// this used to match the English prefixes of an already-translated string,
  /// which meant no locale but English ever reached the error dialog.
  void _reindexAll() async {
    setState(() {});
    final outcome = await _ctrl.reindexAll();
    if (!mounted) return;
    setState(() {});
    switch (outcome) {
      case ReindexNotReady():
        break;
      case ReindexNeedsEmbeddingApi():
        GlazeErrorDialog.show(
          context,
          'memory_books_setup_embedding_first'.tr(),
        );
      case ReindexFailed(:final error):
        GlazeErrorDialog.show(
          context,
          error,
          prefix: 'memory_books_reindex_failed_prefix'.tr(),
        );
      case ReindexDone(:final indexed, :final skipped, :final failed):
        GlazeToast.show(
          context,
          'memory_books_reindex_result'.tr(
            namedArgs: {
              'indexed': '$indexed',
              'skipped': '$skipped',
              'failed': '$failed',
            },
          ),
        );
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
    if (mounted) {
      setState(() => _embeddingStatuses = {});
      GlazeToast.show(context, 'memory_books_indexes_deleted'.tr());
    }
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
      ledgerRange: draft.ledgerRange,
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
