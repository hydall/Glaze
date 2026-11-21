import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../core/import/st_lorebook_importer.dart';
import '../../core/models/folder.dart';
import '../../core/models/lorebook.dart';
import '../../core/services/file_export_service.dart';
import '../../core/services/st_lorebook_exporter.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/time_helpers.dart';
import '../../core/state/folder_provider.dart';
import '../../core/state/lorebook_provider.dart';
import '../../shared/state/preset_sort.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/folder_section.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_list_item.dart';
import '../../shared/widgets/glaze_list_screen.dart';
import '../../shared/widgets/glaze_sheet.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/help_tip.dart';
import '../../shared/widgets/sheet_view.dart';
import 'lorebook_connections_sheet.dart';
import 'lorebook_editor_screen.dart';
import 'lorebook_list_controls.dart';
import 'widgets/lorebook_global_settings_section.dart';

class LorebookListScreen extends ConsumerStatefulWidget {
  /// True when presented as a fullscreen route (`/tools/lorebooks`); false when
  /// hosted inside a modal bottom sheet (e.g. from the chat MagicDrawer). Drives
  /// both the [SheetView] expansion and the back behaviour.
  final bool startExpanded;

  const LorebookListScreen({super.key, this.startExpanded = false});

  @override
  ConsumerState<LorebookListScreen> createState() => _LorebookListScreenState();
}

class _LorebookListScreenState extends ConsumerState<LorebookListScreen> {
  /// Folder currently being browsed, or null at the top level.
  String? _currentFolderId;

  /// The lorebook whose editor is open in the list's place, as the Presets
  /// list opens its editor: inside the same sheet, never as a page over it.
  String? _editingId;
  GlobalKey<LorebookEditorScreenState> _editorKey = GlobalKey();
  LorebookEditorChrome _editorChrome = const LorebookEditorChrome();

  LorebookListFilters _filters = const LorebookListFilters();

  /// Dragging is armed from the toggle next to the sort chip, not by the
  /// manual mode alone: while it is off a long press still selects.
  bool _reorderArmed = false;

  /// Selected lorebook ids while multi-selecting. Empty = not selecting.
  final Set<String> _selected = {};

  /// Search by name: the magnifier swaps the title for a field, the way the
  /// Chats and Characters tabs search. A query looks through every lorebook,
  /// whatever folder it is in.
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchExpanded = false;
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _openFolder(String id) => setState(() {
    _selected.clear();
    _currentFolderId = id;
  });

  void _leaveFolder() => setState(() {
    _selected.clear();
    _currentFolderId = null;
  });

  void _openEditor(String id) {
    setState(() {
      _selected.clear();
      _editingId = id;
      _editorChrome = const LorebookEditorChrome();
      // A fresh key, so the editor loads this lorebook instead of keeping the
      // last one's state.
      _editorKey = GlobalKey<LorebookEditorScreenState>();
    });
  }

  void _closeEditor() => setState(() => _editingId = null);

  void _openSearch() {
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  void _closeSearch() {
    _searchCtrl.clear();
    setState(() {
      _searchExpanded = false;
      _searchQuery = '';
    });
  }

  /// Unwinds one level per press — the editor, the selection, the search, the
  /// folder — and only then leaves the screen.
  void _handleBack() {
    if (_editingId != null) {
      final handled = _editorKey.currentState?.handleBack() ?? false;
      if (!handled) _closeEditor();
      return;
    }
    if (_selected.isNotEmpty) {
      setState(_selected.clear);
      return;
    }
    if (_searchExpanded) {
      _closeSearch();
      return;
    }
    if (_currentFolderId != null) {
      _leaveFolder();
      return;
    }
    if (widget.startExpanded) {
      closeExpandedToolScreen(context, ref);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  String? _folderName(String id) {
    final folders = ref.watch(foldersProvider(FolderDomain.lorebook)).value;
    return folders?.where((f) => f.id == id).firstOrNull?.name;
  }

  // ── Selection / reorder ────────────────────────────────────────────────────

  /// Enters multi-select, disarming a drag so a long press cannot mean both.
  void _startSelection(String id) => setState(() {
    _reorderArmed = false;
    _selected.add(id);
  });

  void _toggleSelected(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _toggleReorderArmed() {
    final armed = !_reorderArmed;
    setState(() {
      _reorderArmed = armed;
      if (armed) _selected.clear();
    });
    if (armed) showGlazeDragHint(context);
  }

  void _onManualReorder(
    List<Lorebook> visible,
    List<Lorebook> all,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex == newIndex) return;
    final sort =
        ref.read(lorebookSortProvider).value ?? const PresetSortState();
    final order = manualOrderAfterDrag(
      all: all,
      visible: visible,
      oldIndex: oldIndex,
      newIndex: newIndex,
      state: sort,
      idOf: (lb) => lb.id,
      nameOf: (lb) => lb.name,
      createdAtOf: (lb) => lb.updatedAt,
    );
    unawaited(ref.read(lorebookSortProvider.notifier).setManualOrder(order));
  }

  LorebookUse _useOf(Lorebook lb, LorebookActivations activations) =>
      LorebookUse(
        global: lb.enabled,
        characters: activations.character.values
            .where((list) => list.contains(lb.id))
            .length,
        chats: activations.chat.values
            .where((list) => list.contains(lb.id))
            .length,
      );

  // ── Build ──────────────────────────────────────────────────────────────────

  Widget _titleText(String text, {bool help = false}) => Row(
    children: [
      Flexible(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: context.cs.onSurface,
          ),
        ),
      ),
      if (help) const HelpTip(term: 'lorebook'),
    ],
  );

  Widget _buildSearchField() {
    return TextField(
      controller: _searchCtrl,
      focusNode: _searchFocus,
      autofocus: true,
      onChanged: (v) => setState(() => _searchQuery = v),
      textInputAction: TextInputAction.search,
      cursorColor: context.cs.primary,
      style: TextStyle(color: context.cs.onSurface, fontSize: 16),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: 'lorebook_search_hint'.tr(),
        hintStyle: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editingId = _editingId;
    final editing = editingId != null;
    final folderId = _currentFolderId;
    final sort =
        ref.watch(lorebookSortProvider).value ?? const PresetSortState();

    final Widget? titleWidget;
    if (editing) {
      titleWidget = _editorChrome.titleWidget;
    } else if (_searchExpanded) {
      titleWidget = _buildSearchField();
    } else if (folderId != null) {
      titleWidget = _titleText(_folderName(folderId) ?? 'menu_lorebooks'.tr());
    } else {
      titleWidget = _titleText('menu_lorebooks'.tr(), help: true);
    }

    return GlazeListScreen(
      startExpanded: widget.startExpanded,
      shellBranchIndex: 2,
      title: editing ? _editorChrome.title : null,
      titleWidget: titleWidget,
      canPop:
          !editing && _selected.isEmpty && !_searchExpanded && folderId == null,
      onBack: _handleBack,
      addLabel: 'action_add'.tr(),
      onAdd: () => _openLorebookMenu(context),
      actions: [
        SheetViewAction(
          icon: Icon(
            _searchExpanded ? Icons.close_rounded : Icons.search,
            size: 20,
          ),
          tooltip: (_searchExpanded ? 'btn_close' : 'lorebook_search_tooltip')
              .tr(),
          onPressed: _searchExpanded ? _closeSearch : _openSearch,
        ),
      ],
      controls: GlazeListControls(
        filterCount: _filters.activeCount,
        onFilter: () => _showFilterSheet(context),
        sort: GlazeListSort(
          mode: sort.mode,
          armed: _reorderArmed,
          onToggleReorder: _toggleReorderArmed,
          onSelect: (mode) =>
              unawaited(ref.read(lorebookSortProvider.notifier).setMode(mode)),
          onDisarm: () {
            if (_reorderArmed) setState(() => _reorderArmed = false);
          },
        ),
      ),
      selection: _selected.isEmpty
          ? null
          : GlazeListSelection(
              count: _selected.length,
              onCancel: () => setState(_selected.clear),
              onMore: () => _showSelectionActions(context),
            ),
      editing: editing,
      editorActions: _editorChrome.actions,
      editorHeaderBottom: _editorChrome.headerBottom,
      editorFab: _editorChrome.fab,
      innerBack: editing ? _editorChrome.innerBack : null,
      body: editing
          ? LorebookEditorScreen(
              key: _editorKey,
              lorebookId: editingId,
              onChrome: (chrome) => setState(() => _editorChrome = chrome),
              onClose: _closeEditor,
            )
          : ref
                .watch(lorebooksProvider)
                .when(
                  skipLoadingOnReload: true,
                  data: (all) => Builder(
                    builder: (context) => _buildList(context, all, sort),
                  ),
                  loading: () => const Center(child: GlazeSpinner()),
                  error: (e, _) =>
                      Center(child: Text('${'title_error'.tr()}: $e')),
                ),
    );
  }

  Widget _buildList(
    BuildContext context,
    List<Lorebook> all,
    PresetSortState sort,
  ) {
    final folderId = _currentFolderId;
    final memberships =
        ref.watch(folderMembershipsProvider(FolderDomain.lorebook)).value ??
        FolderMemberships.empty;
    final hasFolders =
        (ref.watch(foldersProvider(FolderDomain.lorebook)).value ?? const [])
            .isNotEmpty;
    final activations = ref.watch(lorebookActivationsProvider);

    final query = _searchQuery.trim().toLowerCase();
    final searching = query.isNotEmpty;
    var lorebooks = all;
    if (searching) {
      lorebooks = all
          .where((lb) => lb.name.toLowerCase().contains(query))
          .toList();
    } else if (folderId != null) {
      final ids = memberships.membersIn(folderId);
      lorebooks = all.where((lb) => ids.contains(lb.id)).toList();
    } else {
      // A lorebook filed into a folder lives there, not twice.
      lorebooks = all
          .where((lb) => memberships.foldersOf(lb.id).isEmpty)
          .toList();
    }
    final uses = {for (final lb in all) lb.id: _useOf(lb, activations)};
    lorebooks = lorebooks
        .where((lb) => _filters.matches(uses[lb.id]!))
        .toList();
    lorebooks = sortLorebooks(lorebooks, sort);

    final reordering = sort.mode == PresetSortMode.manual && _reorderArmed;
    final selecting = _selected.isNotEmpty;

    final header = <Widget>[
      // A search shows only its hits: no settings or folders above.
      if (folderId == null && !searching) ...[
        const LorebookGlobalSettingsSection(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FolderSection(
            domain: FolderDomain.lorebook,
            onOpenFolder: _openFolder,
            icon: Icons.menu_book_outlined,
          ),
        ),
      ],
      if (lorebooks.isEmpty)
        if (searching || _filters.isActive)
          GlazeListEmptyNote(label: 'search_no_results'.tr())
        else if (folderId != null)
          const FolderEmptyState()
        else if (!hasFolders)
          _EmptyState(
            onCreate: () => _createLorebook(context),
            onImport: () => _importSTLorebook(context),
          ),
    ];

    return GlazeListBody(
      levelKey: 'lorebooks_${folderId ?? '#root'}_$searching',
      headerPadding: 0,
      header: header,
      itemCount: lorebooks.length,
      itemKey: (i) => lorebooks[i].id,
      onReorder: reordering
          ? (oldIndex, newIndex) =>
                _onManualReorder(lorebooks, all, oldIndex, newIndex)
          : null,
      dragByLongPress: true,
      itemBuilder: (context, i) {
        final lb = lorebooks[i];
        return _LorebookRow(
          lorebook: lb,
          use: uses[lb.id]!,
          selecting: selecting,
          selected: _selected.contains(lb.id),
          onTap: selecting
              ? () => _toggleSelected(lb.id)
              : () => _openEditor(lb.id),
          // While dragging is armed a long press lifts the row instead.
          onLongPress: reordering || selecting
              ? null
              : () => _startSelection(lb.id),
          onMore: () => _lorebookMenu(context, lb),
          onConnections: () => showLorebookConnections(context, lb.id),
        );
      },
    );
  }

  // ── Filters ────────────────────────────────────────────────────────────────

  void _showFilterSheet(BuildContext context) {
    showGlazeSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LorebookFilterSheet(
        filters: _filters,
        onApply: (f) {
          if (mounted) setState(() => _filters = f);
        },
      ),
    );
  }

  // ── Selection actions ──────────────────────────────────────────────────────

  void _showSelectionActions(BuildContext context) {
    final folderId = _currentFolderId;
    final ids = _selected.toList();
    GlazeBottomSheet.show<void>(
      context,
      title: '${ids.length} ${'selected_count'.tr()}',
      items: [
        BottomSheetItem(
          icon: Icons.create_new_folder_outlined,
          label: 'action_add_to_folder'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            showAddToFolderSheet(
              context,
              domain: FolderDomain.lorebook,
              targets: ids,
              onDone: () {
                if (mounted) setState(_selected.clear);
              },
            );
          },
        ),
        if (folderId != null)
          BottomSheetItem(
            icon: Icons.folder_off_outlined,
            label: 'action_remove_from_folder'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              final repo = ref.read(folderRepoProvider);
              for (final id in ids) {
                unawaited(repo.removeMember(folderId, id));
              }
              setState(_selected.clear);
            },
          ),
        BottomSheetItem(
          icon: Icons.delete_rounded,
          label: 'action_delete'.tr(),
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _confirmDeleteSelected(context, ids);
          },
        ),
      ],
    );
  }

  void _confirmDeleteSelected(BuildContext context, List<String> ids) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_delete'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'lorebook_delete_selected_confirm'.tr(
          args: ['${ids.length}'],
        ),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(_selected.clear);
            final folders = ref.read(folderRepoProvider);
            final notifier = ref.read(lorebooksProvider.notifier);
            for (final id in ids) {
              unawaited(notifier.deleteLorebook(id));
              unawaited(
                folders.deleteMembersForMember(FolderDomain.lorebook, id),
              );
            }
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  // ── Create / import / export / delete ────────────────────────────────────

  void _openLorebookMenu(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'menu_lorebooks'.tr(),
      items: [
        BottomSheetItem(
          label: 'action_create_new'.tr(),
          icon: Icons.add,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _createLorebook(context);
          },
        ),
        BottomSheetItem(
          label: 'action_import'.tr(),
          icon: Icons.upload_file,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _importSTLorebook(context);
          },
        ),
        BottomSheetItem(
          icon: Icons.create_new_folder_rounded,
          label: 'folder_new'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            showCreateFolderDialog(context, ref, FolderDomain.lorebook);
          },
        ),
      ],
    );
  }

  void _createLorebook(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'new_lorebook'.tr(),
      input: BottomSheetInput(
        placeholder: 'placeholder_name'.tr(),
        confirmLabel: 'btn_create'.tr(),
        onConfirm: (name) {
          Navigator.of(context, rootNavigator: true).pop();
          final id = generateId();
          final lorebook = Lorebook(
            id: id,
            name: name.trim().isEmpty ? 'new_lorebook'.tr() : name.trim(),
            entries: [],
            updatedAt: currentTimestampSeconds(),
          );
          ref.read(lorebooksProvider.notifier).addLorebook(lorebook).then((_) {
            if (mounted) _openEditor(id);
          });
        },
      ),
    );
  }

  Future<void> _importSTLorebook(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'lorebook_import_st_dialog_title'.tr(),
      allowMultiple: true,
      // Not `withData: true`: that loads every picked file into memory before
      // the picker returns, which a large multi-select does not survive. Each
      // book is read from disk when its turn comes instead.
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;

    final notifier = ref.read(lorebooksProvider.notifier);
    // Books are written in chunks (one transaction and one list refresh per
    // chunk) instead of one `addLorebook` — and therefore one full reload of
    // the lorebook list — per file.
    const chunkSize = 20;
    final pending = <Lorebook>[];
    STLorebookImportResult? firstImported;
    var importedCount = 0;
    Object? lastError;

    Future<void> flush() async {
      if (pending.isEmpty) return;
      await notifier.putAll(List<Lorebook>.of(pending));
      pending.clear();
    }

    for (final file in result.files) {
      try {
        final STLorebookImportResult importResult;
        final filePath = file.path;
        final bytes = file.bytes;
        if (filePath != null && filePath.isNotEmpty) {
          importResult = await importSTLorebookFromFile(
            filePath,
            nameOverride: file.name,
          );
        } else if (bytes != null && bytes.isNotEmpty) {
          importResult = importSTLorebook(
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
            nameOverride: file.name,
          );
        } else {
          continue;
        }
        pending.add(importResult.lorebook);
        firstImported ??= importResult;
        importedCount++;
        if (pending.length >= chunkSize) await flush();
      } catch (e) {
        lastError = e;
      }
      // Hand the frame back between files so the list keeps painting.
      await Future<void>.delayed(Duration.zero);
    }

    try {
      await flush();
    } catch (e) {
      lastError = e;
      importedCount -= pending.length;
    }

    if (!context.mounted) return;

    if (importedCount <= 0 || firstImported == null) {
      if (lastError != null) {
        GlazeErrorDialog.show(
          context,
          lastError,
          prefix: 'error_import_failed_prefix'.tr(),
        );
      }
      return;
    }

    // A single picked file keeps the original flow: toast + open the editor.
    if (result.files.length == 1) {
      final single = firstImported;
      GlazeToast.show(
        context,
        'lorebook_imported'.tr(
          args: [single.lorebook.name, single.entryCount.toString()],
        ),
      );
      _openEditor(single.lorebook.id);
      return;
    }

    final failed = result.files.length - importedCount;
    final summary = StringBuffer(
      '${'import_success'.tr()}: $importedCount '
      '${'count_lorebooks'.plural(importedCount)}',
    );
    if (failed > 0) {
      summary.write(
        ' — ${'import_failed_count'.tr(args: [failed.toString()])}',
      );
    }
    GlazeToast.show(context, summary.toString());
  }

  void _lorebookMenu(BuildContext context, Lorebook lb) {
    GlazeBottomSheet.show<void>(
      context,
      title: lb.name,
      items: [
        BottomSheetItem(
          label: 'action_add_to_folder'.tr(),
          icon: Icons.create_new_folder_outlined,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            showAddToFolderSheet(
              context,
              domain: FolderDomain.lorebook,
              targets: [lb.id],
            );
          },
        ),
        BottomSheetItem(
          label: 'action_export'.tr(),
          icon: Icons.download_outlined,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _exportLorebook(context, lb);
          },
        ),
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _deleteLorebook(context, lb);
          },
        ),
      ],
    );
  }

  Future<void> _exportLorebook(BuildContext context, Lorebook lb) async {
    try {
      final json = const JsonEncoder.withIndent(
        '  ',
      ).convert(glazeLorebookToSTJson(lb));
      final safeName = lb.name
          .trim()
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .trim();
      final path = await FileExportService.export(
        data: json,
        filename: '${safeName.isEmpty ? 'lorebook' : safeName}.json',
        subfolder: 'lorebooks',
      );
      if (path.isEmpty) return; // user cancelled the save dialog
    } catch (e) {
      if (context.mounted) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: 'error_export_failed_prefix'.tr(),
        );
      }
    }
  }

  void _deleteLorebook(BuildContext context, Lorebook lb) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'confirm_delete_lorebook'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'lorebook_confirm_delete_desc'.tr(args: [lb.name]),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () {
            ref.read(lorebooksProvider.notifier).deleteLorebook(lb.id);
            ref
                .read(folderRepoProvider)
                .deleteMembersForMember(FolderDomain.lorebook, lb.id);
            Navigator.of(context, rootNavigator: true).pop();
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }
}

// ── Empty state ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onImport;

  const _EmptyState({required this.onCreate, required this.onImport});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 48, 40, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 64,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 20),
          Text(
            'no_lorebooks'.tr(),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'empty_lorebooks_desc'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          // Wrap, not Row: the two labels are translated, and in a narrow
          // column (the desktop right sidebar, or a small window) a Row
          // overflowed instead of stacking them.
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              GlazeActionButton(
                icon: Icons.add,
                label: 'btn_create'.tr(),
                tone: GlazeActionTone.primary,
                onTap: onCreate,
              ),
              GlazeActionButton(
                icon: Icons.upload_file,
                label: 'action_import'.tr(),
                tone: GlazeActionTone.neutral,
                onTap: onImport,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Lorebook row ─────────────────────────────────────────────────────────────

class _LorebookRow extends StatelessWidget {
  final Lorebook lorebook;
  final LorebookUse use;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onMore;
  final VoidCallback onConnections;

  const _LorebookRow({
    required this.lorebook,
    required this.use,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onMore,
    required this.onConnections,
  });

  @override
  Widget build(BuildContext context) {
    final scopeColor = use.global
        ? Colors.green
        : use.characters > 0
        ? Colors.purple
        : use.chats > 0
        ? Colors.orange
        : context.cs.onSurfaceVariant;

    return GlazeListItem(
      // A lorebook in use is outlined in the accent, as an active regex is.
      accent: use.unused ? null : context.cs.primary,
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      trailing: selecting
          ? GlazeSelectionCheck(selected: selected)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.link, size: 18, color: scopeColor),
                  tooltip: 'header_connections'.tr(),
                  onPressed: onConnections,
                ),
                GlazeListMenuButton(onTap: onMore),
              ],
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            lorebook.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${lorebook.entries.length} ${'label_entries'.tr()}',
            style: TextStyle(
              fontSize: 11.5,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          if (!use.unused) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (use.global)
                  _ConnBadge(label: 'label_global'.tr(), color: Colors.green),
                if (use.characters > 0)
                  _ConnBadge(
                    label: '${use.characters} ${'header_characters'.tr()}',
                    color: Colors.purple,
                  ),
                if (use.chats > 0)
                  _ConnBadge(
                    label: '${use.chats} ${'tab_dialogs'.tr()}',
                    color: Colors.orange,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ConnBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _ConnBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
