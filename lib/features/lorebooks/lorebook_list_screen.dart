import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../core/import/st_lorebook_importer.dart';
import '../../core/models/lorebook.dart';
import '../../core/services/file_export_service.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/time_helpers.dart';
import '../../core/state/lorebook_embedding_provider.dart';
import '../../core/state/lorebook_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/help_tip.dart';
import '../../shared/widgets/menu_group.dart';
import '../../shared/widgets/sheet_view.dart';
import 'embedding_settings_screen.dart';
import 'lorebook_connections_sheet.dart';
import 'lorebook_editor_screen.dart';
import 'widgets/lorebook_option_sheet.dart';

class LorebookListScreen extends ConsumerWidget {
  /// True when presented as a fullscreen route (`/tools/lorebooks`); false when
  /// hosted inside a modal bottom sheet (e.g. from the chat MagicDrawer). Drives
  /// both the [SheetView] expansion and the back behaviour.
  final bool startExpanded;

  const LorebookListScreen({super.key, this.startExpanded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lorebooksAsync = ref.watch(lorebooksProvider);

    return SheetView(
      startExpanded: startExpanded,
      showRouteBackground: false,
      shellBranchIndex: 2,
      titleWidget: Row(
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
      ),
      showBack: true,
      onBack: () {
        if (startExpanded) {
          closeExpandedToolScreen(context, ref);
        } else {
          Navigator.of(context).maybePop();
        }
      },
      floatingActionButton: FloatingActionButton(
        // Disable the Hero so this FAB doesn't collide with the editor's FAB
        // (default tags clash during the push transition → frozen route).
        heroTag: null,
        backgroundColor: context.cs.primary,
        child: const Icon(Icons.add, color: Colors.black),
        onPressed: () => _openLorebookMenu(context, ref),
      ),
      actions: [
        // Embedding settings are only reachable while the active API preset
        // has vector search switched on.
        if (ref.watch(vectorSearchAvailableProvider))
          SheetViewAction(
            icon: const Icon(Icons.search, size: 20),
            tooltip: 'lorebook_embedding_settings_tooltip'.tr(),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const EmbeddingSettingsScreen(),
              ),
            ),
          ),
      ],
      body: lorebooksAsync.when(
        data: (lorebooks) => Builder(
          builder: (context) => ListView(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 16).add(
              EdgeInsets.only(
                top: MediaQuery.paddingOf(context).top + 16,
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
            ),
            children: [
              const _GlobalSettingsSection(),
              if (lorebooks.isEmpty)
                _EmptyState(
                  onCreate: () => _createLorebook(context, ref),
                  onImport: () => _importSTLorebook(context, ref),
                )
              else ...[
                for (final lb in lorebooks)
                  _LorebookCard(
                    lorebook: lb,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => LorebookEditorScreen(lorebookId: lb.id),
                      ),
                    ),
                    onMore: () => _lorebookMenu(context, ref, lb),
                    onConnections: () =>
                        showLorebookConnections(context, lb.id),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: _AddButton(
                    label: 'btn_add'.tr(),
                    onTap: () => _openLorebookMenu(context, ref),
                  ),
                ),
              ],
            ],
          ),
        ),
        loading: () => const Center(child: GlazeSpinner()),
        error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
      ),
    );
  }

  // ── Create / import / export / delete ────────────────────────────────────

  void _openLorebookMenu(BuildContext context, WidgetRef ref) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'menu_lorebooks'.tr(),
      items: [
        BottomSheetItem(
          label: 'action_create_new'.tr(),
          icon: Icons.add,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _createLorebook(context, ref);
          },
        ),
        BottomSheetItem(
          label: 'action_import'.tr(),
          icon: Icons.upload_file,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _importSTLorebook(context, ref);
          },
        ),
      ],
    );
  }

  void _createLorebook(BuildContext context, WidgetRef ref) {
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
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LorebookEditorScreen(lorebookId: id),
              ),
            );
          });
        },
      ),
    );
  }

  Future<void> _importSTLorebook(BuildContext context, WidgetRef ref) async {
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
        GlazeErrorDialog.show(context, lastError, prefix: 'Import failed: ');
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
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LorebookEditorScreen(lorebookId: single.lorebook.id),
        ),
      );
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

  void _lorebookMenu(BuildContext context, WidgetRef ref, Lorebook lb) {
    GlazeBottomSheet.show<void>(
      context,
      title: lb.name,
      items: [
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
            _deleteLorebook(context, ref, lb);
          },
        ),
      ],
    );
  }

  Future<void> _exportLorebook(BuildContext context, Lorebook lb) async {
    try {
      final json = const JsonEncoder.withIndent(
        '  ',
      ).convert(_toSTLorebookJson(lb));
      final safeName = lb.name.trim().isEmpty ? 'lorebook' : lb.name.trim();
      await FileExportService.export(
        data: json,
        filename: '$safeName.json',
        subfolder: 'lorebooks',
      );
    } catch (e) {
      if (context.mounted) {
        GlazeErrorDialog.show(context, e, prefix: 'Export failed: ');
      }
    }
  }

  /// Minimal SillyTavern world-info shape: `{ entries: { "0": {...}, ... } }`.
  Map<String, dynamic> _toSTLorebookJson(Lorebook lb) {
    final entries = <String, dynamic>{};
    for (var i = 0; i < lb.entries.length; i++) {
      final e = lb.entries[i];
      entries['$i'] = {
        'uid': i,
        'key': e.keys,
        'keysecondary': e.secondaryKeys,
        'comment': e.comment,
        'content': e.content,
        'constant': e.constant,
        'selective': e.selectiveLogic != 4,
        'selectiveLogic': e.selectiveLogic,
        'order': e.order,
        'position': 0,
        'disable': !e.enabled,
        'probability': e.probability,
        'useProbability': true,
        'excludeRecursion': e.preventRecursion,
        'delayUntilRecursion': e.delayUntilRecursion,
        'group': e.group,
        'groupWeight': e.groupProminence,
        'sticky': e.sticky,
        'cooldown': e.cooldown,
        'delay': e.delay,
        'scanDepth': e.scanDepth,
        'caseSensitive': e.caseSensitive,
        'matchWholeWords': e.matchWholeWords,
        'useGroupScoring': e.useGroupScoring,
        'glazeMetadata': {
          'position': e.position,
          'vectorSearch': e.vectorSearch,
          'useKeywordSearch': e.useKeywordSearch,
          'ignoreBudget': e.ignoreBudget,
          'characterFilter': e.characterFilter == null
              ? null
              : {
                  'names': e.characterFilter!.names,
                  'isExclude': e.characterFilter!.isExclude,
                },
        },
      };
    }
    return {'name': lb.name, 'entries': entries};
  }

  void _deleteLorebook(BuildContext context, WidgetRef ref, Lorebook lb) {
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
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.cs.primary,
                  foregroundColor: Colors.black,
                ),
                onPressed: onCreate,
                child: Text('btn_create'.tr()),
              ),
              OutlinedButton(
                onPressed: onImport,
                child: Text('action_import'.tr()),
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        onTap: onTap,
        child: Padding(
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
        ),
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

// ── Inline collapsible global settings ───────────────────────────────────────

class _GlobalSettingsSection extends ConsumerStatefulWidget {
  const _GlobalSettingsSection();

  @override
  ConsumerState<_GlobalSettingsSection> createState() =>
      _GlobalSettingsSectionState();
}

class _GlobalSettingsSectionState
    extends ConsumerState<_GlobalSettingsSection> {
  bool _expanded = false;
  late final TextEditingController _scanDepthCtrl;
  late final TextEditingController _maxEntriesCtrl;
  late final TextEditingController _reserveCtrl;
  late final TextEditingController _topKCtrl;

  @override
  void initState() {
    super.initState();
    final s = ref.read(lorebookSettingsProvider);
    _scanDepthCtrl = TextEditingController(text: s.scanDepth.toString());
    _maxEntriesCtrl = TextEditingController(
      text: s.maxInjectedEntries.toString(),
    );
    _reserveCtrl = TextEditingController(text: s.reserveValue.toString());
    _topKCtrl = TextEditingController(text: s.vectorTopK.toString());
  }

  @override
  void dispose() {
    _scanDepthCtrl.dispose();
    _maxEntriesCtrl.dispose();
    _reserveCtrl.dispose();
    _topKCtrl.dispose();
    super.dispose();
  }

  void _update(LorebookGlobalSettings s) {
    ref.read(lorebookSettingsProvider.notifier).state = s;
    saveLorebookSettings(s);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(lorebookSettingsProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.cs.outlineVariant),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'section_global_settings'.tr(),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: context.cs.onSurface,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _buildItems(s),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildItems(LorebookGlobalSettings s) {
    // With semantic search off in the API there is nothing to search against,
    // so the search-type picker and every vector-only knob below it are
    // dropped and the screen behaves as keyword-only.
    final vectorAvailable = ref.watch(vectorSearchAvailableProvider);
    final isVector = vectorAvailable && s.searchType != 'keyword';
    return [
      if (vectorAvailable)
        MenuSelectorItem(
          label: 'label_search_type'.tr(),
          currentValue: switch (s.searchType) {
            'vector' => 'search_type_vector'.tr(),
            'both' => 'search_type_both'.tr(),
            _ => 'search_type_keys'.tr(),
          },
          onTap: () => showLorebookOptionSheet<String>(
            context,
            title: 'label_search_type'.tr(),
            current: s.searchType,
            options: [
              LorebookOption('keyword', 'search_type_keys'.tr()),
              LorebookOption('vector', 'search_type_vector'.tr()),
              LorebookOption('both', 'search_type_both'.tr()),
            ],
            onSelect: (v) => _update(s.copyWith(searchType: v)),
          ),
        ),
      MenuSelectorItem(
        label: 'label_key_search_mode'.tr(),
        currentValue: s.keySearchMode == 'glaze'
            ? 'match_whole_words_glaze'.tr()
            : 'match_whole_words_st'.tr(),
        onTap: () => showLorebookOptionSheet<String>(
          context,
          title: 'label_key_search_mode'.tr(),
          current: s.keySearchMode,
          options: [
            LorebookOption('tavern', 'match_whole_words_st'.tr()),
            LorebookOption('glaze', 'match_whole_words_glaze'.tr()),
          ],
          onSelect: (v) => _update(s.copyWith(keySearchMode: v)),
        ),
      ),
      _NumberItem(
        label: isVector
            ? 'label_vector_scan_depth'.tr()
            : 'label_scan_depth_lore'.tr(),
        controller: _scanDepthCtrl,
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null && n >= 1 && n <= 100) {
            _update(s.copyWith(scanDepth: n));
          }
        },
      ),
      _NumberItem(
        label: 'label_max_injected_entries'.tr(),
        controller: _maxEntriesCtrl,
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null && n >= 1 && n <= 100) {
            _update(s.copyWith(maxInjectedEntries: n));
          }
        },
      ),
      MenuSelectorItem(
        label: 'label_injection_position'.tr(),
        currentValue: switch (s.injectionPosition) {
          'worldInfoAfter' => 'pos_after_char'.tr(),
          'lorebooksMacro' => 'pos_lorebooks_macro'.tr(),
          _ => 'pos_before_char'.tr(),
        },
        onTap: () => showLorebookOptionSheet<String>(
          context,
          title: 'label_injection_position'.tr(),
          current: s.injectionPosition,
          options: [
            LorebookOption('worldInfoBefore', 'pos_before_char'.tr()),
            LorebookOption('worldInfoAfter', 'pos_after_char'.tr()),
            LorebookOption('lorebooksMacro', 'pos_lorebooks_macro'.tr()),
          ],
          onSelect: (v) => _update(s.copyWith(injectionPosition: v)),
        ),
      ),
      MenuSelectorItem(
        label: 'label_lorebook_reserve_mode'.tr(),
        currentValue: s.reserveMode == 'percent'
            ? 'lorebook_reserve_percent'.tr()
            : 'lorebook_reserve_absolute'.tr(),
        onTap: () => showLorebookOptionSheet<String>(
          context,
          title: 'label_lorebook_reserve_mode'.tr(),
          current: s.reserveMode,
          options: [
            LorebookOption('percent', 'lorebook_reserve_percent'.tr()),
            LorebookOption('tokens', 'lorebook_reserve_absolute'.tr()),
          ],
          onSelect: (v) => _update(s.copyWith(reserveMode: v)),
        ),
      ),
      _NumberItem(
        label: s.reserveMode == 'percent'
            ? 'label_lorebook_reserve_percent'.tr()
            : 'label_lorebook_reserve_tokens'.tr(),
        controller: _reserveCtrl,
        onChanged: (v) {
          final n = int.tryParse(v);
          final max = s.reserveMode == 'percent' ? 100 : 2147483647;
          if (n != null && n >= 0 && n <= max) {
            _update(s.copyWith(reserveValue: n));
          }
        },
      ),
      if (isVector) ...[
        MenuRangeItem(
          label: 'label_similarity_threshold'.tr(),
          value: s.vectorThreshold,
          min: 0,
          max: 1,
          divisions: 100,
          onChanged: (v) => _update(
            s.copyWith(vectorThreshold: double.parse(v.toStringAsFixed(2))),
          ),
        ),
        _NumberItem(
          label: 'label_top_k'.tr(),
          controller: _topKCtrl,
          onChanged: (v) {
            final n = int.tryParse(v);
            if (n != null && n >= 1 && n <= 50) {
              _update(s.copyWith(vectorTopK: n));
            }
          },
        ),
        if (s.searchType == 'both')
          MenuRangeItem(
            label: 'label_kw_vector_split'.tr(),
            value: s.keywordVectorSplit.toDouble(),
            min: 0,
            max: 100,
            divisions: 100,
            onChanged: (v) =>
                _update(s.copyWith(keywordVectorSplit: v.round())),
          ),
      ],
      MenuSwitchItem(
        label: 'label_recursive_scan'.tr(),
        value: s.recursiveScan,
        onChanged: (v) => _update(s.copyWith(recursiveScan: v)),
      ),
      MenuSwitchItem(
        label: 'label_case_sensitive'.tr(),
        value: s.caseSensitive,
        onChanged: (v) => _update(s.copyWith(caseSensitive: v)),
      ),
      MenuSwitchItem(
        label: 'label_match_whole_words'.tr(),
        value: s.matchWholeWords,
        onChanged: (v) => _update(s.copyWith(matchWholeWords: v)),
      ),
    ];
  }
}

/// Number row matching [MenuFieldItem] layout but with numeric keyboard.
class _NumberItem extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _NumberItem({
    required this.label,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MenuFieldItem(
      label: label,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: onChanged,
    );
  }
}
