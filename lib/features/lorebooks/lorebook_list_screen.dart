import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../core/import/st_lorebook_importer.dart';
import '../../core/models/folder.dart';
import '../../core/models/lorebook.dart';
import '../../core/services/file_export_service.dart';
import '../../core/services/st_lorebook_exporter.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/time_helpers.dart';
import '../../core/state/folder_provider.dart';
import '../../core/state/lorebook_embedding_provider.dart';
import '../../core/state/lorebook_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/folder_section.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_fab.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_sheet.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/help_tip.dart';
import '../../shared/widgets/menu_group.dart';
import '../../shared/widgets/sheet_view.dart';
import 'embedding_settings_screen.dart';
import 'lorebook_connections_sheet.dart';
import 'lorebook_editor_screen.dart';
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

  void _openFolder(String id) => setState(() => _currentFolderId = id);

  void _leaveFolder() => setState(() => _currentFolderId = null);

  void _handleBack() {
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

  @override
  Widget build(BuildContext context) {
    final lorebooksAsync = ref.watch(lorebooksProvider);
    final folderId = _currentFolderId;

    return SheetView(
      startExpanded: widget.startExpanded,
      showRouteBackground: false,
      shellBranchIndex: 2,
      titleWidget: folderId == null
          ? Row(
              children: [
                Flexible(
                  child: Text(
                    'menu_lorebooks'.tr(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: context.cs.onSurface,
                    ),
                  ),
                ),
                const HelpTip(term: 'lorebook'),
              ],
            )
          : Text(
              _folderName(folderId) ?? 'menu_lorebooks'.tr(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.cs.onSurface,
              ),
            ),
      showBack: true,
      canPop: folderId == null,
      onBack: _handleBack,
      floatingActionButton: GlazeFab(
        label: 'action_add'.tr(),
        tooltip: 'action_create_new'.tr(),
        onTap: () => _openLorebookMenu(context),
      ),
      actions: [
        // Embedding settings are only reachable while the active API preset
        // has vector search switched on.
        if (ref.watch(vectorSearchAvailableProvider))
          SheetViewAction(
            icon: const Icon(Icons.search, size: 20),
            tooltip: 'lorebook_embedding_settings_tooltip'.tr(),
            // On desktop a window; a page would cover the whole app.
            onPressed: () => isDesktopLayout(context)
                ? showGlazeSheet<void>(
                    context: context,
                    useRootNavigator: true,
                    builder: (_) => const EmbeddingSettingsScreen(),
                  )
                : Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EmbeddingSettingsScreen(),
                    ),
                  ),
          ),
      ],
      body: lorebooksAsync.when(
        data: (all) {
          final memberships =
              ref.watch(folderMembershipsProvider(FolderDomain.lorebook)).value ??
              FolderMemberships.empty;
          final hasFolders =
              (ref.watch(foldersProvider(FolderDomain.lorebook)).value ??
                      const [])
                  .isNotEmpty;

          final List<Lorebook> lorebooks;
          if (folderId != null) {
            final ids = memberships.membersIn(folderId);
            lorebooks = all.where((lb) => ids.contains(lb.id)).toList();
          } else {
            lorebooks = all
                .where((lb) => memberships.foldersOf(lb.id).isEmpty)
                .toList();
          }

          return Builder(
            builder: (context) => ListView(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 16).add(
                EdgeInsets.only(
                  // A sidebar panel starts its rows right under the header.
                  top:
                      MediaQuery.paddingOf(context).top +
                      (inSidebarPanel(context) ? 0 : 16),
                  bottom: MediaQuery.paddingOf(context).bottom,
                ),
              ),
              children: [
                if (folderId == null) ...[
                  const LorebookGlobalSettingsSection(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: FolderSection(
                      domain: FolderDomain.lorebook,
                      onOpenFolder: _openFolder,
                      icon: Icons.menu_book_outlined,
                    ),
                  ),
                ],
                if (lorebooks.isEmpty && !(folderId == null && hasFolders))
                  _EmptyState(
                    onCreate: () => _createLorebook(context),
                    onImport: () => _importSTLorebook(context),
                  )
                else ...[
                  if (lorebooks.isEmpty && folderId != null)
                    const FolderEmptyState()
                  else
                    for (final lb in lorebooks)
                      _LorebookCard(
                        lorebook: lb,
                        onTap: () => openLorebookEditor(context, lb.id),
                        onMore: () => _lorebookMenu(context, lb),
                        onConnections: () =>
                            showLorebookConnections(context, lb.id),
                      ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      inSidebarPanel(context) ? 16 : 4,
                      16,
                      8,
                    ),
                    child: _AddButton(
                      label: 'btn_add'.tr(),
                      onTap: () => _openLorebookMenu(context),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
        loading: () => const Center(child: GlazeSpinner()),
        error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
      ),
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
            if (!context.mounted) return;
            openLorebookEditor(context, id);
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
      await openLorebookEditor(context, single.lorebook.id);
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
      final safeName =
          lb.name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
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

// ── Lorebook card ────────────────────────────────────────────────────────────

class _LorebookCard extends ConsumerWidget {
  final Lorebook lorebook;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final VoidCallback onConnections;

  const _LorebookCard({
    required this.lorebook,
    required this.onTap,
    required this.onMore,
    required this.onConnections,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activations = ref.watch(lorebookActivationsProvider);
    final charCount = activations.character.values
        .where((list) => list.contains(lorebook.id))
        .length;
    final chatCount = activations.chat.values
        .where((list) => list.contains(lorebook.id))
        .length;

    final scopeColor = lorebook.enabled
        ? Colors.green
        : charCount > 0
        ? Colors.purple
        : chatCount > 0
        ? Colors.orange
        : context.cs.onSurfaceVariant;

    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lorebook.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${lorebook.entries.length} ${'label_entries'.tr()}',
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                if (lorebook.enabled || charCount > 0 || chatCount > 0) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (lorebook.enabled)
                        _ConnBadge(
                          label: 'label_global'.tr(),
                          color: Colors.green,
                        ),
                      if (charCount > 0)
                        _ConnBadge(
                          label: '$charCount ${'header_characters'.tr()}',
                          color: Colors.purple,
                        ),
                      if (chatCount > 0)
                        _ConnBadge(
                          label: '$chatCount ${'tab_dialogs'.tr()}',
                          color: Colors.orange,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.link, size: 18, color: scopeColor),
            tooltip: 'header_connections'.tr(),
            onPressed: onConnections,
          ),
          IconButton(
            icon: Icon(
              Icons.more_vert,
              size: 20,
              color: context.cs.onSurfaceVariant,
            ),
            onPressed: onMore,
          ),
        ],
      ),
    );
    // In a sidebar panel the lorebook is a row of the list, edge to edge.
    if (inSidebarPanel(context)) {
      return FlatGroupSurface(
        child: InkWell(onTap: onTap, child: content),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        onTap: onTap,
        child: content,
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

// ── Add button (Vue ps-add-btn) ──────────────────────────────────────────────

class _AddButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _AddButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.cs.primary,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add, size: 20, color: Colors.black),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
