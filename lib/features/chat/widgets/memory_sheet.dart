import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/summary_providers.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../chat_provider.dart';
import 'memory/memory_books_controls.dart';
import 'memory/memory_books_toolbar.dart';
import 'memory/memory_tab_store.dart';
import 'memory_books_tab.dart';
import 'summary_tab.dart';

/// Tabs of the Memory sheet, in display order.
enum MemoryTab { summary, books }

/// Single home for everything session memory: the chat summary and the memory
/// books, behind one segmented control. Replaces the two separate Quick Access
/// entries that used to open them.
class MemorySheet extends ConsumerStatefulWidget {
  final String charId;

  /// Tab to open on. When null the sheet restores the tab it was closed on
  /// (see [MemoryTabStore]).
  final MemoryTab? initialTab;

  const MemorySheet({super.key, required this.charId, this.initialTab});

  @override
  ConsumerState<MemorySheet> createState() => _MemorySheetState();
}

class _MemorySheetState extends ConsumerState<MemorySheet> {
  static const MemoryTabStore _tabStore = MemoryTabStore.memorySheet;

  /// Null until the remembered tab has been read back. The body shows a
  /// spinner until then rather than opening on Summary and jumping — which
  /// would also mount a tab the user never asked for.
  MemoryTab? _tab;

  /// Tabs the user has actually opened. Both stay mounted afterwards so
  /// switching back does not re-run their loads, but the untouched one is
  /// never built — the books tab queries an embedding status per entry on
  /// first build.
  final Set<MemoryTab> _visited = {};

  /// Published by [MemoryBooksTab] once it is mounted. The books tab owns the
  /// controller, so the sheet's own chrome — the header settings button and
  /// the FAB — is driven from what the tab hands out rather than from the
  /// sheet reaching into it.
  MemoryBooksActions? _booksActions;

  @override
  void initState() {
    super.initState();
    final forced = widget.initialTab;
    if (forced != null) {
      _tab = forced;
      _visited.add(forced);
    } else {
      unawaited(_restoreTab());
    }
  }

  Future<void> _restoreTab() async {
    final index = await _tabStore.load(MemoryTab.values.length);
    if (!mounted) return;
    final tab = MemoryTab.values[index];
    setState(() {
      _tab = tab;
      _visited.add(tab);
    });
  }

  void _select(MemoryTab tab) {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      _visited.add(tab);
    });
    unawaited(_tabStore.save(tab.index));
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(chatProvider(widget.charId)).value?.session;
    final tab = _tab;

    return SheetView(
      title: 'memory_sheet_title'.tr(),
      showBack: true,
      headerBottom: GlazeTabBar(
        tabs: [
          GlazeTabItem(
            label: 'magic_summary'.tr(),
            icon: Icons.subject_rounded,
          ),
          GlazeTabItem(
            label: 'magic_memory_books'.tr(),
            icon: Icons.auto_stories_outlined,
          ),
        ],
        // Before the stored tab resolves the strip still has to show a
        // selection; it is replaced a frame later if the remembered tab differs.
        activeIndex: (tab ?? MemoryTab.summary).index,
        onChanged: (index) => _select(MemoryTab.values[index]),
      ),
      actions: [
        if (tab == MemoryTab.summary && session != null)
          _summaryToggle(session.id),
        if (tab == MemoryTab.books && _booksActions != null)
          SheetViewAction(
            // The chat input bar's round glass button, not a bare icon: this
            // is the one control the books tab keeps in the chrome, and it
            // should read as a button.
            icon: MemoryCircleButton(
              icon: Icons.tune_rounded,
              label: 'memory_books_settings_title'.tr(),
              onTap: _booksActions!.openSettings,
            ),
            onPressed: _booksActions!.openSettings,
          ),
      ],
      floatingActionButton: tab == MemoryTab.books && _booksActions != null
          ? MemoryBooksActionsFab(
              onScanChat: _booksActions!.scanChat,
              onAddEntry: _booksActions!.addEntry,
              isReindexing: _booksActions!.isReindexing,
              onReindex: _booksActions!.reindex,
              onDeleteIndexes: _booksActions!.deleteIndexes,
              showIndexActions: _booksActions!.showIndexActions,
              onDeleteAllDrafts: _booksActions!.deleteAllDrafts,
            )
          : null,
      body: session == null || tab == null
          ? const Center(child: GlazeSpinner())
          : IndexedStack(
              index: tab.index,
              sizing: StackFit.expand,
              children: [
                _visited.contains(MemoryTab.summary)
                    ? SummaryTab(charId: widget.charId)
                    : const SizedBox.shrink(),
                _visited.contains(MemoryTab.books)
                    ? MemoryBooksTab(
                        key: ValueKey(session.id),
                        sessionId: session.id,
                        charId: widget.charId,
                        messages: session.messages,
                        onActions: (actions) {
                          if (!mounted) return;
                          setState(() => _booksActions = actions);
                        },
                      )
                    : const SizedBox.shrink(),
              ],
            ),
    );
  }

  /// Master switch for summary injection. Writes through
  /// [syncSummaryEnabled], which also flips the `summary` block in every
  /// preset so the toggle is not silently overridden by the active preset.
  SheetViewAction _summaryToggle(String sessionId) {
    final enabled = ref.watch(summaryEnabledProvider(sessionId)).value ?? true;
    void setEnabled(bool value) =>
        syncSummaryEnabled(ref, charId: widget.charId, enabled: value);
    return SheetViewAction(
      icon: Switch(
        value: enabled,
        onChanged: setEnabled,
        activeThumbColor: Theme.of(context).colorScheme.primary,
      ),
      onPressed: () => setEnabled(!enabled),
    );
  }
}

Future<void> showMemorySheet(
  BuildContext context,
  String charId, {
  MemoryTab? initialTab,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => MemorySheet(charId: charId, initialTab: initialTab),
  );
}
