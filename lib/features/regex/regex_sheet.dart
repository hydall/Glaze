import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:easy_localization/easy_localization.dart';

import '../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../core/models/folder.dart';
import '../../core/models/preset.dart';
import '../../core/models/studio_regex.dart';
import '../../core/services/file_export_service.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/folder_provider.dart';
import '../../core/state/global_regex_provider.dart';
import '../../core/state/studio_feature_provider.dart';
import '../../core/state/studio_regex_provider.dart';
import '../../core/utils/id_generator.dart';
import '../presets/preset_list_provider.dart';
import '../studio/studio_injection_points.dart';
import 'regex_list_controls.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/folder_section.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_fab.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_text_field.dart';
import '../../shared/widgets/glaze_sheet.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/list_controls.dart';
import '../../shared/widgets/menu_group.dart';
import '../../shared/widgets/selection_bar.dart';
import '../../shared/widgets/sheet_view.dart';

/// Where a newly added script lands. [agent] is the Studio list, which takes
/// the place of [preset] while the Studio master switch is on — a chat preset
/// and an agentic preset are mutually exclusive, so only one of the two is ever
/// offered.
enum _RegexScope { preset, global, agent }

class RegexSheet extends ConsumerStatefulWidget {
  final bool startExpanded;

  /// When set, overrides the active-preset lookup so this sheet always edits
  /// the specified preset regardless of which preset is currently active.
  final String? presetId;

  const RegexSheet({super.key, this.startExpanded = false, this.presetId});

  @override
  ConsumerState<RegexSheet> createState() => _RegexSheetState();
}

class _RegexSheetState extends ConsumerState<RegexSheet> {
  String _view = 'list';
  bool _isForward = true;
  PresetRegex? _activeScript;
  bool _isPresetScript = false;
  bool _isStudioScript = false;
  Set<String> _activeStudioStages = const {};
  Timer? _saveTimer;

  /// Folder of global scripts currently browsed, or null at the top level.
  String? _globalFolderId;

  /// Scope picked in the control row's dropdown; null = every scope.
  _RegexScope? _scopeFilter;
  RegexListFilters _filters = const RegexListFilters();

  /// Dragging is armed from the chip next to the sort picker, not by the
  /// manual mode alone: while it is off a long press opens multi-select.
  bool _reorderArmed = false;

  /// Selected rows while multi-selecting, as [_selectionKey]s. Empty = not
  /// selecting.
  final Set<String> _selected = {};

  @override
  void deactivate() {
    // When shown as a modal bottom sheet (magic-drawer / preset editor) a
    // swipe- or barrier-dismiss never routes through _goBack, so a pending
    // debounced script edit would be lost — dispose() only cancels the timer,
    // and by then the captured ref is unmounted. Flush here while the widget is
    // still mounted (ref valid).
    if ((_saveTimer?.isActive ?? false) && _activeScript != null) {
      _saveTimer!.cancel();
      _saveActiveScript(_activeScript!);
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  // ── Navigation ──────────────────────────────────────────────────────────────

  void _selectScript(
    PresetRegex script, {
    required bool isPreset,
    bool isStudio = false,
    Set<String> studioStages = const {},
  }) {
    // On desktop the script opens in a window of its own beside the list,
    // rather than in its place.
    if (isDesktopLayout(context)) {
      openRegexEditorWindow(
        context,
        script.id,
        isStudio
            ? RegexScope.studio
            : isPreset
            ? RegexScope.preset
            : RegexScope.global,
        presetId: isPreset ? _effectivePresetId : null,
      );
      return;
    }
    setState(() {
      _isForward = true;
      _activeScript = script;
      _isPresetScript = isPreset;
      _isStudioScript = isStudio;
      _activeStudioStages = studioStages;
      _view = 'edit';
    });
  }

  void _goBack() {
    if (_view == 'edit') {
      _saveTimer?.cancel();
      final s = _activeScript;
      if (s != null) _saveActiveScript(s);
      setState(() {
        _isForward = false;
        _view = 'list';
        _activeScript = null;
        _isPresetScript = false;
        _isStudioScript = false;
        _activeStudioStages = const {};
      });
    }
  }

  void _goBackFromList() {
    if (widget.startExpanded) {
      closeExpandedToolScreen(context, ref);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// Header / gesture back: leaves the editor, then the selection, then an open
  /// folder, and only then closes the sheet.
  void _handleBack() {
    if (_view == 'edit') {
      _goBack();
      return;
    }
    // Selection and the folder view are both "inner" states: back leaves them
    // before it leaves the sheet.
    if (_selected.isNotEmpty) {
      _clearSelection();
      return;
    }
    if (_globalFolderId != null) {
      setState(() => _globalFolderId = null);
      return;
    }
    _goBackFromList();
  }

  String? get _effectivePresetId =>
      widget.presetId ?? ref.read(activePresetIdProvider);

  // ── Script changes ───────────────────────────────────────────────────────────

  void _onScriptChanged(PresetRegex updated) {
    setState(() => _activeScript = updated);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _saveActiveScript(updated);
    });
  }

  Future<void> _saveActiveScript(PresetRegex script) => _writeRegexScript(
    ref,
    script,
    _isStudioScript
        ? RegexScope.studio
        : _isPresetScript
        ? RegexScope.preset
        : RegexScope.global,
    presetId: _effectivePresetId,
    studioStages: _activeStudioStages,
  );

  Future<void> _setStudioStages(Set<String> stages) async {
    final script = _activeScript;
    if (script == null) return;
    setState(() => _activeStudioStages = stages);
    await ref
        .read(studioRegexProvider.notifier)
        .updateRegex(StudioRegex(script: script, stages: stages));
  }

  Future<void> _toggleScript(
    PresetRegex script,
    bool enabled, {
    required bool isPreset,
    bool isStudio = false,
    Set<String> studioStages = const {},
  }) async {
    final updated = script.copyWith(disabled: !enabled);
    if (isStudio) {
      await ref
          .read(studioRegexProvider.notifier)
          .updateRegex(StudioRegex(script: updated, stages: studioStages));
    } else if (isPreset) {
      final pid = _effectivePresetId;
      if (pid == null) return;
      final presets = ref.read(presetListProvider).value ?? [];
      final preset = presets.where((p) => p.id == pid).firstOrNull;
      if (preset == null) return;
      final updatedRegexes = preset.regexes
          .map((r) => r.id == script.id ? updated : r)
          .toList();
      await ref
          .read(presetListProvider.notifier)
          .updatePreset(preset.copyWith(regexes: updatedRegexes));
    } else {
      await ref.read(globalRegexProvider.notifier).updateRegex(updated);
    }
  }

  Future<void> _deleteScript(
    PresetRegex script,
    bool isPreset, {
    bool isStudio = false,
  }) async {
    if (isStudio) {
      await ref.read(studioRegexProvider.notifier).removeRegex(script.id);
    } else if (isPreset) {
      final pid = _effectivePresetId;
      if (pid == null) return;
      final presets = ref.read(presetListProvider).value ?? [];
      final preset = presets.where((p) => p.id == pid).firstOrNull;
      if (preset == null) return;
      final updatedRegexes = preset.regexes
          .where((r) => r.id != script.id)
          .toList();
      await ref
          .read(presetListProvider.notifier)
          .updatePreset(preset.copyWith(regexes: updatedRegexes));
    } else {
      await ref.read(globalRegexProvider.notifier).removeRegex(script.id);
      await ref
          .read(folderRepoProvider)
          .deleteMembersForMember(FolderDomain.regex, script.id);
    }
  }

  Future<PresetRegex?> _addPresetRegex() async {
    final pid = _effectivePresetId;
    if (pid == null) return null;
    final presets = ref.read(presetListProvider).value ?? [];
    final preset = presets.where((p) => p.id == pid).firstOrNull;
    if (preset == null) return null;
    final newScript = PresetRegex(
      id: generateId(),
      name: 'New Script',
      regex: '',
    );
    await ref
        .read(presetListProvider.notifier)
        .updatePreset(preset.copyWith(regexes: [...preset.regexes, newScript]));
    return newScript;
  }

  PresetRegex _addGlobalRegex() {
    final newScript = PresetRegex(
      id: generateId(),
      name: 'New Global Script',
      regex: '',
    );
    ref.read(globalRegexProvider.notifier).addRegex(newScript);
    return newScript;
  }

  PresetRegex _addStudioRegex() {
    final script = PresetRegex(
      id: generateId(),
      name: 'New Studio Script',
      regex: '',
      placement: const [1, 2],
      ephemerality: const [2],
    );
    ref
        .read(studioRegexProvider.notifier)
        .addRegex(StudioRegex(script: script, stages: const {'final'}));
    return script;
  }

  // ── Menus ────────────────────────────────────────────────────────────────────

  void _showScriptMenu(
    BuildContext context,
    PresetRegex script,
    bool isPreset, {
    bool isStudio = false,
  }) {
    GlazeBottomSheet.show<void>(
      context,
      title: script.name,
      items: [
        BottomSheetItem(
          icon: Icons.check_circle_outline_rounded,
          label: 'action_select'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _startSelection(
              _selectionKey(
                isStudio
                    ? _RegexScope.agent
                    : isPreset
                    ? _RegexScope.preset
                    : _RegexScope.global,
                script.id,
              ),
            );
          },
        ),
        if (!isPreset && !isStudio)
          BottomSheetItem(
            icon: Icons.create_new_folder_outlined,
            label: 'action_add_to_folder'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              showAddToFolderSheet(
                context,
                domain: FolderDomain.regex,
                targets: [script.id],
              );
            },
          ),
        BottomSheetItem(
          icon: Icons.download_outlined,
          label: 'action_export'.tr(),
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await _exportScript(context, script);
          },
        ),
        BottomSheetItem(
          icon: Icons.delete_outline,
          iconColor: const Color(0xFFFF4444),
          label: 'action_delete_msg'.tr(),
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _deleteScript(script, isPreset, isStudio: isStudio);
          },
        ),
      ],
    );
  }

  /// Whether this sheet shows the agent list in place of the chat preset's.
  ///
  /// The Studio master switch decides it — except when the sheet was opened to
  /// edit one named preset (the preset editor's own "Regex" row), where the
  /// caller has already said which preset's scripts it means.
  bool get _agentMode =>
      widget.presetId == null && ref.read(studioFeatureEnabledProvider);

  void _showAddMenu(BuildContext context) {
    // With Studio on there is no active chat preset, so the first destination
    // is the agent list instead of the preset's own scripts.
    final studioEnabled = _agentMode;
    GlazeBottomSheet.show<void>(
      context,
      title: 'menu_regex'.tr(),
      items: [
        BottomSheetItem(
          icon: studioEnabled
              ? Icons.smart_toy_outlined
              : Icons.label_outline,
          label: studioEnabled
              ? 'regex_add_to_agents'.tr()
              : 'regex_add_to_preset'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _showDestinationMenu(
              context,
              scope: studioEnabled ? _RegexScope.agent : _RegexScope.preset,
            );
          },
        ),
        BottomSheetItem(
          icon: Icons.public,
          label: 'regex_add_globally'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _showDestinationMenu(context, scope: _RegexScope.global);
          },
        ),
        BottomSheetItem(
          icon: Icons.create_new_folder_rounded,
          label: 'folder_new'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            showCreateFolderDialog(context, ref, FolderDomain.regex);
          },
        ),
      ],
    );
  }

  String _destinationTitle(_RegexScope scope) => switch (scope) {
    _RegexScope.agent => 'regex_studio_scripts'.tr(),
    _RegexScope.global => 'regex_global_scripts'.tr(),
    _RegexScope.preset => _targetPresetName(),
  };

  String _targetPresetName() {
    final pid = _effectivePresetId;
    final presets = ref.read(presetListProvider).value ?? [];
    final preset = pid != null
        ? presets.where((p) => p.id == pid).firstOrNull
        : presets.firstOrNull;
    return preset?.name ?? 'label_active_preset'.tr();
  }

  void _createInScope(_RegexScope scope) {
    switch (scope) {
      case _RegexScope.agent:
        _selectScript(
          _addStudioRegex(),
          isPreset: false,
          isStudio: true,
          studioStages: const {'final'},
        );
        break;
      case _RegexScope.global:
        _selectScript(_addGlobalRegex(), isPreset: false);
        break;
      case _RegexScope.preset:
        _addPresetRegex().then((created) {
          if (created != null && mounted) {
            _selectScript(created, isPreset: true);
          }
        });
        break;
    }
  }

  void _showDestinationMenu(
    BuildContext context, {
    required _RegexScope scope,
  }) {
    GlazeBottomSheet.show<void>(
      context,
      title: _destinationTitle(scope),
      items: [
        BottomSheetItem(
          icon: Icons.add,
          label: 'action_create_new'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _createInScope(scope);
          },
        ),
        BottomSheetItem(
          icon: Icons.upload_file_outlined,
          label: 'action_import'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _importRegex(context, scope: scope);
          },
        ),
      ],
    );
  }

  // ── Export / Import ──────────────────────────────────────────────────────────

  Future<void> _exportScript(BuildContext context, PresetRegex script) async {
    final json = const JsonEncoder.withIndent('  ').convert(script.toJson());
    final safe = script.name.replaceAll(RegExp(r'[^\w\-]'), '_');
    final filename = 'regex-$safe.json';
    try {
      final path = await FileExportService.export(
        data: json,
        filename: filename,
        subfolder: 'regexes',
      );
      if (path.isEmpty) return; // user cancelled the save dialog
      if (context.mounted) GlazeToast.show(context, 'export_success'.tr());
    } catch (e) {
      if (context.mounted) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: '${'settings_err_failed'.tr()} ',
        );
      }
    }
  }

  Future<void> _importRegex(
    BuildContext context, {
    required _RegexScope scope,
  }) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: Platform.isIOS ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isIOS ? null : ['json', 'zip'],
        allowMultiple: true,
        withData: true,
      );
    } catch (_) {}
    if (result == null || result.files.isEmpty) return;

    try {
      final List<dynamic> combinedRaw = [];
      for (final picked in result.files) {
        late Uint8List bytes;
        if (picked.bytes != null && picked.bytes!.isNotEmpty) {
          bytes = picked.bytes!;
        } else if (picked.path != null && picked.path!.isNotEmpty) {
          bytes = await File(picked.path!).readAsBytes();
        } else {
          continue;
        }
        if (picked.name.toLowerCase().endsWith('.zip')) {
          final archive = ZipDecoder().decodeBytes(bytes);
          for (final entry in archive) {
            if (!entry.isFile || !entry.name.toLowerCase().endsWith('.json')) {
              continue;
            }
            _appendFromJson(
              utf8.decode(entry.content as List<int>),
              combinedRaw,
            );
          }
        } else {
          _appendFromJson(utf8.decode(bytes), combinedRaw);
        }
      }

      if (combinedRaw.isEmpty) {
        if (context.mounted) GlazeToast.show(context, 'no_results'.tr());
        return;
      }

      if (scope == _RegexScope.global) {
        await ref
            .read(globalRegexProvider.notifier)
            .importFromJsBackup(combinedRaw);
        if (context.mounted) GlazeToast.show(context, 'import_success'.tr());
      } else if (scope == _RegexScope.agent) {
        // An imported file carries no Studio stages — an ST script has no such
        // notion. Land them on the Main Writer, the stage a new agent script
        // already defaults to, and let the user re-aim them from the editor.
        final imported = _normalizeRawRegexList(combinedRaw)
            .map(
              (script) => StudioRegex(script: script, stages: const {'final'}),
            )
            .toList();
        await ref.read(studioRegexProvider.notifier).addRegexes(imported);
        if (context.mounted) GlazeToast.show(context, 'import_success'.tr());
      } else {
        final pid = _effectivePresetId;
        if (pid == null) {
          if (context.mounted) {
            GlazeToast.show(context, 'label_active_preset'.tr());
          }
          return;
        }
        final presets = ref.read(presetListProvider).value ?? [];
        final preset = presets.where((p) => p.id == pid).firstOrNull;
        if (preset == null) {
          if (context.mounted) GlazeToast.show(context, 'no_results'.tr());
          return;
        }
        final newRegexes = _normalizeRawRegexList(combinedRaw);
        await ref
            .read(presetListProvider.notifier)
            .updatePreset(
              preset.copyWith(regexes: [...preset.regexes, ...newRegexes]),
            );
        if (context.mounted) {
          GlazeToast.show(context, 'import_success'.tr());
        }
      }
    } catch (e) {
      if (context.mounted) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: '${'settings_err_failed'.tr()} ',
        );
      }
    }
  }

  void _appendFromJson(String jsonStr, List<dynamic> out) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        out.addAll(decoded);
      } else if (decoded is Map<String, dynamic>) {
        out.add(decoded);
      }
    } catch (_) {}
  }

  List<PresetRegex> _normalizeRawRegexList(List<dynamic> rawList) {
    final result = <PresetRegex>[];
    for (final r in rawList) {
      if (r is! Map<String, dynamic>) continue;
      final m = normalizeJsGlobalRegex(Map<String, dynamic>.from(r));
      if (!m.containsKey('id')) m['id'] = generateId();
      if (r['isEnabled'] is bool) m['disabled'] = !(r['isEnabled'] as bool);
      try {
        result.add(PresetRegex.fromJson(m));
      } catch (_) {}
    }
    return result;
  }

  // ── Transition ───────────────────────────────────────────────────────────────

  Widget _buildTransition(Widget child, Animation<double> animation) {
    final dir = _isForward ? 1.0 : -1.0;
    final isEntering = _isForward
        ? child.key != const ValueKey('regex-list')
        : child.key == const ValueKey('regex-list');
    return SlideTransition(
      position: Tween<Offset>(
        begin: isEntering ? Offset(dir * 0.06, 0) : Offset(-dir * 0.06, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: FadeTransition(opacity: animation, child: child),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final presetsAsync = ref.watch(presetListProvider);
    final globalAsync = ref.watch(globalRegexProvider);
    final studioAsync = ref.watch(studioRegexProvider);
    final activePresetId = ref.watch(activePresetIdProvider);
    // The Studio master switch decides which kind of preset is in effect, and
    // the two are mutually exclusive — so the agent scripts do not sit in a tab
    // beside the chat preset's, they take its place. Watched here (rather than
    // read through [_agentMode]) so flipping the switch rebuilds the list.
    final studioEnabled =
        widget.presetId == null && ref.watch(studioFeatureEnabledProvider);

    final presets = presetsAsync.value ?? [];
    final effectivePresetId = widget.presetId ?? activePresetId;
    final activePreset = effectivePresetId != null
        ? presets.where((p) => p.id == effectivePresetId).firstOrNull
        : presets.firstOrNull;
    final presetRegexes = activePreset?.regexes ?? <PresetRegex>[];
    final globalRegexes = globalAsync.value ?? <PresetRegex>[];
    final studioRegexes = studioAsync.value ?? <StudioRegex>[];

    final isEdit = _view == 'edit';
    // On desktop the add action belongs in the sheet's header — drawn in the
    // sidebar panel's app bar, or the sheet window's title bar — instead of as
    // a floating chip over the list.
    final desktop = isDesktopLayout(context);
    final regexFolders = ref.watch(foldersProvider(FolderDomain.regex)).value;
    final globalFolderName = regexFolders
        ?.where((f) => f.id == _globalFolderId)
        .firstOrNull
        ?.name;
    final selecting = _selected.isNotEmpty;

    return SheetView(
      startExpanded: widget.startExpanded,
      showRouteBackground: false,
      title: isEdit
          ? 'regex_editor'.tr()
          : _globalFolderId != null
          ? (globalFolderName ?? 'menu_regex'.tr())
          : 'menu_regex'.tr(),
      showBack: isEdit || widget.startExpanded || _globalFolderId != null,
      actions: !isEdit && desktop
          ? [
              SheetViewAction(
                icon: const Icon(Icons.add),
                tooltip: 'action_add_script'.tr(),
                onPressed: () => _showAddMenu(context),
              ),
            ]
          : const [],
      // The scope dropdown, the filter button and the sort chip belong to the
      // header, as on the Presets list: pinned there they stay reachable at
      // any scroll offset. On desktop the selection takes their place.
      headerBottom: isEdit
          ? null
          : selecting && desktop
          ? GlazeSelectionBar(
              compact: true,
              count: _selected.length,
              onCancel: _clearSelection,
              onMore: () => _showSelectionActions(context),
            )
          : _buildControlsRow(context, studioEnabled: studioEnabled),
      // A back gesture unwinds the same chain the header's back button walks —
      // leave the editor, drop the selection, step out of the folder — and only
      // closes the sheet once none of those is left.
      canPop: !isEdit && _globalFolderId == null && !selecting,
      onBack: _handleBack,
      floating: isEdit || !selecting || desktop
          ? null
          : Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, _floatingBottom()),
                child: GlazeSelectionBar(
                  count: _selected.length,
                  onCancel: _clearSelection,
                  onMore: () => _showSelectionActions(context),
                ),
              ),
            ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        transitionBuilder: _buildTransition,
        child: isEdit && _activeScript != null
            ? _RegexEditView(
                key: ValueKey(_activeScript!.id),
                script: _activeScript!,
                onChanged: _onScriptChanged,
                studioStages: _isStudioScript ? _activeStudioStages : null,
                onStudioStagesChanged: _isStudioScript
                    ? _setStudioStages
                    : null,
              )
            : _buildListView(
                context,
                studioEnabled: studioEnabled,
                activePreset: activePreset,
                presetRegexes: presetRegexes,
                globalRegexes: globalRegexes,
                studioRegexes: studioRegexes,
              ),
      ),
      floatingActionButton: isEdit || desktop || selecting
          ? null
          : GlazeFab(
              label: 'action_add_script'.tr(),
              tooltip: 'action_add_script'.tr(),
              onTap: () => _showAddMenu(context),
            ),
    );
  }

  /// The selection bar floats above whichever chrome sits at the bottom: the
  /// shell nav bar when the screen is a route, the safe-area inset in a sheet.
  double _floatingBottom() {
    final navHeight = ref.watch(navHeightProvider);
    final inset = MediaQuery.paddingOf(context).bottom;
    return (navHeight > inset ? navHeight : inset) + 16;
  }

  // ── Controls row ─────────────────────────────────────────────────────────────

  /// The scope the dropdown is set to, with an agent/preset pick carried over
  /// to the one actually on screen when the Studio switch has flipped since.
  _RegexScope? _effectiveScope(bool studioEnabled) => switch (_scopeFilter) {
    _RegexScope.agent when !studioEnabled => _RegexScope.preset,
    _RegexScope.preset when studioEnabled => _RegexScope.agent,
    final scope => scope,
  };

  String _scopeLabel(_RegexScope? scope) => switch (scope) {
    null => 'preset_type_all'.tr(),
    _RegexScope.preset => 'regex_preset_scripts'.tr(),
    _RegexScope.agent => 'regex_studio_scripts'.tr(),
    _RegexScope.global => 'regex_global_scripts'.tr(),
  };

  IconData _scopeIcon(_RegexScope? scope) => switch (scope) {
    null => Icons.apps_rounded,
    _RegexScope.preset => Icons.description_outlined,
    _RegexScope.agent => Icons.smart_toy_outlined,
    _RegexScope.global => Icons.public,
  };

  /// Control row pinned to the header, laid out like the Presets list's: the
  /// scope dropdown on the left, the filter button and the sort chip on the
  /// right.
  Widget _buildControlsRow(BuildContext context, {required bool studioEnabled}) {
    final mode = ref.watch(regexSortProvider).value?.mode ?? PresetSortMode.manual;
    final scope = _effectiveScope(studioEnabled);
    return Row(
      children: [
        GlazeDropdownChip(
          label: _scopeLabel(scope),
          onTap: () => _showScopePicker(context, studioEnabled: studioEnabled),
        ),
        const Spacer(),
        GlazeFilterIconButton(
          count: _filters.activeCount,
          onTap: () => _showFilterSheet(context),
        ),
        const SizedBox(width: 8),
        PresetSortControls(
          mode: mode,
          armed: _reorderArmed,
          onToggleReorder: _toggleReorderArmed,
          onDisarm: () {
            if (_reorderArmed && mounted) setState(() => _reorderArmed = false);
          },
          onSelect: (mode) =>
              unawaited(ref.read(regexSortProvider.notifier).setMode(mode)),
        ),
      ],
    );
  }

  void _showScopePicker(BuildContext context, {required bool studioEnabled}) {
    final current = _effectiveScope(studioEnabled);
    showGlazePickerSheet(
      context,
      title: 'regex_filter_scope'.tr(),
      items: [
        for (final scope in <_RegexScope?>[
          null,
          studioEnabled ? _RegexScope.agent : _RegexScope.preset,
          _RegexScope.global,
        ])
          GlazePickerItem(
            label: _scopeLabel(scope),
            icon: _scopeIcon(scope),
            isActive: scope == current,
            value: scope,
          ),
      ],
      onSelect: (v) {
        if (mounted) setState(() => _scopeFilter = v as _RegexScope?);
      },
    );
  }

  void _showFilterSheet(BuildContext context) {
    showGlazeSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RegexFilterSheet(
        filters: _filters,
        onApply: (f) {
          if (mounted) setState(() => _filters = f);
        },
      ),
    );
  }

  /// Arms or disarms dragging. Arming clears any multi-select — the two modes
  /// claim the same long press, so only one of them can be on.
  void _toggleReorderArmed() {
    final armed = !_reorderArmed;
    setState(() {
      _reorderArmed = armed;
      if (armed) _selected.clear();
    });
    if (armed) GlazeToast.show(context, 'preset_drag_hint'.tr());
  }

  // ── List ─────────────────────────────────────────────────────────────────────

  Widget _buildListView(
    BuildContext context, {
    required bool studioEnabled,
    required Preset? activePreset,
    required List<PresetRegex> presetRegexes,
    required List<PresetRegex> globalRegexes,
    required List<StudioRegex> studioRegexes,
  }) {
    final memberships =
        ref.watch(folderMembershipsProvider(FolderDomain.regex)).value ??
        FolderMemberships.empty;
    final folders =
        ref.watch(foldersProvider(FolderDomain.regex)).value ?? const [];
    final sort =
        ref.watch(regexSortProvider).value ?? const PresetSortState();
    final reordering = sort.mode == PresetSortMode.manual && _reorderArmed;
    final globalFolderId = _globalFolderId;
    final scope = _effectiveScope(studioEnabled);
    bool shows(_RegexScope s) => scope == null || scope == s;

    final List<PresetRegex> globalPool;
    if (globalFolderId != null) {
      final ids = memberships.membersIn(globalFolderId);
      globalPool = globalRegexes.where((r) => ids.contains(r.id)).toList();
    } else {
      globalPool = globalRegexes
          .where((r) => memberships.foldersOf(r.id).isEmpty)
          .toList();
    }

    List<PresetRegex> visible(List<PresetRegex> scripts) =>
        sortRegexScripts(scripts.where(_filters.matches).toList(), sort);

    final stagesById = {
      for (final e in studioRegexes) e.script.id: e.stages,
    };

    final groups = <Widget>[];
    if (globalFolderId == null) {
      if (studioEnabled) {
        if (shows(_RegexScope.agent)) {
          groups.add(
            _buildGroup(
              context,
              scope: _RegexScope.agent,
              header: 'regex_studio_scripts'.tr(),
              description: 'regex_studio_description'.tr(),
              rows: visible([for (final e in studioRegexes) e.script]),
              fullIds: [for (final e in studioRegexes) e.script.id],
              stagesById: stagesById,
              reordering: reordering,
            ),
          );
        }
      } else if (shows(_RegexScope.preset) &&
          (presetRegexes.isNotEmpty || scope == _RegexScope.preset)) {
        groups.add(
          _buildGroup(
            context,
            scope: _RegexScope.preset,
            header: 'regex_preset_scripts'.tr(),
            leading: activePreset == null
                ? null
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: _PresetChip(
                      presetName: activePreset.name,
                      onTap: widget.presetId == null
                          ? () => context.go('/tools/presets')
                          : null,
                    ),
                  ),
            rows: visible(presetRegexes),
            fullIds: [for (final r in presetRegexes) r.id],
            reordering: reordering,
          ),
        );
      }
    }
    if (globalFolderId != null || shows(_RegexScope.global)) {
      groups.add(
        _buildGroup(
          context,
          scope: _RegexScope.global,
          header: 'regex_global_scripts'.tr(),
          rows: visible(globalPool),
          fullIds: [for (final r in globalRegexes) r.id],
          reordering: reordering,
        ),
      );
    }

    return Builder(
      key: const ValueKey('regex-list'),
      builder: (innerContext) {
        final flat = inSidebarPanel(innerContext);
        final list = ListView(
          key: PageStorageKey('regex_list_${globalFolderId ?? 'root'}'),
          // A sidebar panel starts its groups right under the header.
          padding: EdgeInsets.fromLTRB(0, flat ? 0 : 12, 0, 16).add(
            EdgeInsets.only(
              top: MediaQuery.paddingOf(innerContext).top,
              bottom: MediaQuery.paddingOf(innerContext).bottom,
            ),
          ),
          children: [
            // Folders sit above every group, as on the Presets list; a script
            // filed into one lives there instead of in the Global group.
            if (globalFolderId == null && folders.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(16, flat ? 12 : 0, 16, 4),
                child: FolderSection(
                  domain: FolderDomain.regex,
                  icon: Icons.code_rounded,
                  onOpenFolder: _openFolder,
                ),
              ),
            ...groups,
            const SizedBox(height: 80),
          ],
        );
        // Stepping into a folder and back swaps the whole list, so it
        // cross-fades instead of cutting.
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [
              for (final child in previous) IgnorePointer(child: child),
              ?current,
            ],
          ),
          child: KeyedSubtree(
            key: ValueKey(globalFolderId ?? '#root'),
            child: list,
          ),
        );
      },
    );
  }

  /// One group of scripts. While dragging is armed its rows sit in a
  /// reorderable list; a drop rewrites the order the scripts run in.
  Widget _buildGroup(
    BuildContext context, {
    required _RegexScope scope,
    required String header,
    String? description,
    Widget? leading,
    required List<PresetRegex> rows,
    required List<String> fullIds,
    Map<String, Set<String>> stagesById = const {},
    required bool reordering,
  }) {
    Widget row(PresetRegex script) => _buildRow(
      context,
      script,
      scope,
      stages: stagesById[script.id] ?? const {},
      reordering: reordering,
    );

    return MenuGroup(
      header: header,
      description: description,
      items: [
        ?leading,
        if (rows.isEmpty)
          const _EmptyState()
        else if (reordering && rows.length > 1)
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            buildDefaultDragHandles: false,
            itemCount: rows.length,
            onReorderItem: (oldIndex, newIndex) => unawaited(
              _reorder(
                scope,
                reanchorOrder(
                  fullIds,
                  [for (final r in rows) r.id],
                  oldIndex,
                  newIndex,
                ),
              ),
            ),
            itemBuilder: (_, i) => ReorderableDelayedDragStartListener(
              key: ValueKey('${scope.name}:${rows[i].id}'),
              index: i,
              child: row(rows[i]),
            ),
          )
        else
          ...rows.map(row),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    PresetRegex script,
    _RegexScope scope, {
    required Set<String> stages,
    required bool reordering,
  }) {
    final key = _selectionKey(scope, script.id);
    final isPreset = scope == _RegexScope.preset;
    final isStudio = scope == _RegexScope.agent;
    final selecting = _selected.isNotEmpty;
    return MenuScriptItem(
      key: ValueKey(key),
      name: script.name,
      subtitle: script.regex.isNotEmpty ? script.regex : null,
      enabled: !script.disabled,
      selected: selecting ? _selected.contains(key) : null,
      onToggle: (v) => _toggleScript(
        script,
        v,
        isPreset: isPreset,
        isStudio: isStudio,
        studioStages: stages,
      ),
      onTap: selecting
          ? () => _toggleSelected(key)
          : () => _selectScript(
              script,
              isPreset: isPreset,
              isStudio: isStudio,
              studioStages: stages,
            ),
      // While dragging is armed a long press lifts the row, so it can't also
      // open multi-select — that moves to the row menu.
      onLongPress: reordering ? null : () => _startSelection(key),
      onMore: () =>
          _showScriptMenu(context, script, isPreset, isStudio: isStudio),
    );
  }

  /// Writes [order] (ids) back as the run order of [scope]'s scripts.
  Future<void> _reorder(_RegexScope scope, List<String> order) async {
    List<T> arrange<T>(List<T> items, String Function(T) idOf) {
      final byId = {for (final item in items) idOf(item): item};
      return [for (final id in order) ?byId[id]];
    }

    switch (scope) {
      case _RegexScope.global:
        final current = ref.read(globalRegexProvider).value ?? const [];
        await ref
            .read(globalRegexProvider.notifier)
            .replaceAll(arrange(current, (r) => r.id));
      case _RegexScope.agent:
        final current = ref.read(studioRegexProvider).value ?? const [];
        await ref
            .read(studioRegexProvider.notifier)
            .replaceAll(arrange(current, (e) => e.script.id));
      case _RegexScope.preset:
        final preset = _effectivePreset();
        if (preset == null) return;
        await ref
            .read(presetListProvider.notifier)
            .updatePreset(
              preset.copyWith(regexes: arrange(preset.regexes, (r) => r.id)),
            );
    }
  }

  Preset? _effectivePreset() {
    final pid = _effectivePresetId;
    if (pid == null) return null;
    final presets = ref.read(presetListProvider).value ?? const <Preset>[];
    return presets.where((p) => p.id == pid).firstOrNull;
  }

  void _openFolder(String id) {
    setState(() {
      _selected.clear();
      _globalFolderId = id;
    });
  }

  // ── Multi-select ─────────────────────────────────────────────────────────────

  /// Scripts of different scopes live in different lists and their ids are
  /// generated independently, so a selection key carries the scope as well.
  static String _selectionKey(_RegexScope scope, String id) =>
      '${scope.name}:$id';

  /// Enters multi-select, disarming a drag left over from the manual mode so a
  /// long press cannot mean both things at once.
  void _startSelection(String key) {
    setState(() {
      _reorderArmed = false;
      _selected
        ..clear()
        ..add(key);
    });
  }

  void _toggleSelected(String key) {
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  /// The selected scripts, grouped by where they live. Keys whose script went
  /// away while the list was open are skipped.
  ({List<PresetRegex> global, List<PresetRegex> preset, List<String> studio})
  _selectedScripts() {
    final global = [
      for (final r in ref.read(globalRegexProvider).value ?? const <PresetRegex>[])
        if (_selected.contains(_selectionKey(_RegexScope.global, r.id))) r,
    ];
    final preset = [
      for (final r in _effectivePreset()?.regexes ?? const <PresetRegex>[])
        if (_selected.contains(_selectionKey(_RegexScope.preset, r.id))) r,
    ];
    final studio = [
      for (final e in ref.read(studioRegexProvider).value ?? const <StudioRegex>[])
        if (_selected.contains(_selectionKey(_RegexScope.agent, e.script.id)))
          e.script.id,
    ];
    return (global: global, preset: preset, studio: studio);
  }

  void _showSelectionActions(BuildContext context) {
    final picked = _selectedScripts();
    final folderId = _globalFolderId;
    GlazeBottomSheet.show<void>(
      context,
      title: '${_selected.length} ${'selected_count'.tr()}',
      items: [
        BottomSheetItem(
          icon: Icons.toggle_on_outlined,
          label: 'regex_enable_selected'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            unawaited(_setSelectedEnabled(true));
          },
        ),
        BottomSheetItem(
          icon: Icons.toggle_off_outlined,
          label: 'regex_disable_selected'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            unawaited(_setSelectedEnabled(false));
          },
        ),
        BottomSheetItem(
          icon: Icons.share_rounded,
          label: 'action_export'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            unawaited(_exportSelected(context));
          },
        ),
        // Folders hold global scripts only; a preset's scripts travel with it.
        if (picked.global.isNotEmpty)
          BottomSheetItem(
            icon: Icons.create_new_folder_outlined,
            label: 'action_add_to_folder'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              showAddToFolderSheet(
                context,
                domain: FolderDomain.regex,
                targets: [for (final r in picked.global) r.id],
                onDone: () {
                  if (mounted) _clearSelection();
                },
              );
            },
          ),
        if (folderId != null)
          BottomSheetItem(
            icon: Icons.folder_off_outlined,
            label: 'action_remove_from_folder'.tr(),
            onTap: () async {
              Navigator.of(context, rootNavigator: true).pop();
              final repo = ref.read(folderRepoProvider);
              for (final r in picked.global) {
                await repo.removeMember(folderId, r.id);
              }
              if (mounted) _clearSelection();
            },
          ),
        BottomSheetItem(
          icon: Icons.delete_rounded,
          label: 'action_delete'.tr(),
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _confirmDeleteSelected(context);
          },
        ),
      ],
    );
  }

  /// Turns every selected script on or off, one write per list.
  Future<void> _setSelectedEnabled(bool enabled) async {
    bool picked(_RegexScope scope, String id) =>
        _selected.contains(_selectionKey(scope, id));
    PresetRegex apply(PresetRegex r) => r.copyWith(disabled: !enabled);

    final global = ref.read(globalRegexProvider).value ?? const <PresetRegex>[];
    if (global.any((r) => picked(_RegexScope.global, r.id))) {
      await ref.read(globalRegexProvider.notifier).replaceAll([
        for (final r in global) picked(_RegexScope.global, r.id) ? apply(r) : r,
      ]);
    }
    final studio = ref.read(studioRegexProvider).value ?? const <StudioRegex>[];
    if (studio.any((e) => picked(_RegexScope.agent, e.script.id))) {
      await ref.read(studioRegexProvider.notifier).replaceAll([
        for (final e in studio)
          picked(_RegexScope.agent, e.script.id)
              ? StudioRegex(script: apply(e.script), stages: e.stages)
              : e,
      ]);
    }
    final preset = _effectivePreset();
    if (preset != null &&
        preset.regexes.any((r) => picked(_RegexScope.preset, r.id))) {
      await ref
          .read(presetListProvider.notifier)
          .updatePreset(
            preset.copyWith(
              regexes: [
                for (final r in preset.regexes)
                  picked(_RegexScope.preset, r.id) ? apply(r) : r,
              ],
            ),
          );
    }
    if (mounted) _clearSelection();
  }

  /// Saves the selected scripts as one JSON array — the shape the import
  /// already reads back.
  Future<void> _exportSelected(BuildContext context) async {
    final picked = _selectedScripts();
    final studio = ref.read(studioRegexProvider).value ?? const <StudioRegex>[];
    final scripts = [
      ...picked.preset,
      for (final e in studio)
        if (picked.studio.contains(e.script.id)) e.script,
      ...picked.global,
    ];
    if (scripts.isEmpty) return;
    try {
      final path = await FileExportService.export(
        data: const JsonEncoder.withIndent(
          '  ',
        ).convert([for (final s in scripts) s.toJson()]),
        filename: 'regex-scripts.json',
        subfolder: 'regexes',
      );
      if (path.isEmpty) return; // user cancelled the save dialog
      if (!context.mounted) return;
      _clearSelection();
      GlazeToast.show(context, 'export_success'.tr());
    } catch (e) {
      if (context.mounted) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: '${'settings_err_failed'.tr()} ',
        );
      }
    }
  }

  void _confirmDeleteSelected(BuildContext context) {
    final count = _selected.length;
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_delete'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'regex_delete_many_confirm'.plural(count),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await _deleteSelected();
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

  Future<void> _deleteSelected() async {
    final picked = _selectedScripts();
    _clearSelection();
    if (picked.global.isNotEmpty) {
      final gone = {for (final r in picked.global) r.id};
      final global = ref.read(globalRegexProvider).value ?? const <PresetRegex>[];
      await ref.read(globalRegexProvider.notifier).replaceAll([
        for (final r in global)
          if (!gone.contains(r.id)) r,
      ]);
      final repo = ref.read(folderRepoProvider);
      for (final id in gone) {
        await repo.deleteMembersForMember(FolderDomain.regex, id);
      }
    }
    if (picked.studio.isNotEmpty) {
      final studio = ref.read(studioRegexProvider).value ?? const <StudioRegex>[];
      await ref.read(studioRegexProvider.notifier).replaceAll([
        for (final e in studio)
          if (!picked.studio.contains(e.script.id)) e,
      ]);
    }
    final preset = _effectivePreset();
    if (preset != null && picked.preset.isNotEmpty) {
      final gone = {for (final r in picked.preset) r.id};
      await ref
          .read(presetListProvider.notifier)
          .updatePreset(
            preset.copyWith(
              regexes: [
                for (final r in preset.regexes)
                  if (!gone.contains(r.id)) r,
              ],
            ),
          );
    }
  }
}

// ── List UI widgets ────────────────────────────────────────────────────────────

class _PresetChip extends StatelessWidget {
  final String presetName;
  final VoidCallback? onTap;
  const _PresetChip({required this.presetName, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          decoration: BoxDecoration(
            color: context.cs.primary.withValues(alpha: 0.12),
            border: Border.all(
              color: context.cs.primary.withValues(alpha: 0.25),
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.description_outlined,
                size: 14,
                color: context.cs.primary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  presetName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.cs.primary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: context.cs.primary.withValues(alpha: 0.7),
                ),
              ],
            ],
          ),
        ),
      )),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text(
          'no_results'.tr(),
          style: TextStyle(color: context.cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

// ── Where a script lives ───────────────────────────────────────────────────────

/// Where a regex script lives, which decides where its edits are written.
enum RegexScope { global, preset, studio }

/// Writes [script] back where it lives: the global list, preset [presetId]'s
/// scripts, or Studio's (with its [studioStages]).
Future<void> _writeRegexScript(
  WidgetRef ref,
  PresetRegex script,
  RegexScope scope, {
  String? presetId,
  Set<String> studioStages = const {},
}) async {
  switch (scope) {
    case RegexScope.studio:
      await ref
          .read(studioRegexProvider.notifier)
          .updateRegex(StudioRegex(script: script, stages: studioStages));
    case RegexScope.preset:
      if (presetId == null) return;
      final presets = ref.read(presetListProvider).value ?? [];
      final preset = presets.where((p) => p.id == presetId).firstOrNull;
      if (preset == null) return;
      final updated = preset.regexes
          .map((r) => r.id == script.id ? script : r)
          .toList();
      await ref
          .read(presetListProvider.notifier)
          .updatePreset(preset.copyWith(regexes: updated));
    case RegexScope.global:
      await ref.read(globalRegexProvider.notifier).updateRegex(script);
  }
}

// ── Desktop window ─────────────────────────────────────────────────────────────

/// Opens script [scriptId]'s editor in a desktop floating window of its own
/// (opening one already open brings it to the front).
void openRegexEditorWindow(
  BuildContext context,
  String scriptId,
  RegexScope scope, {
  String? presetId,
}) {
  floatOnDesktop(
    context,
    Uri(
      path: 'regex-editor',
      queryParameters: {
        'id': scriptId,
        'scope': scope.name,
        'preset': ?presetId,
      },
    ).toString(),
  );
}

/// A regex script's editor in a desktop floating window (`regex-editor`). It
/// reads the script from where it lives and writes edits back there, so it
/// needs nothing from the list it was opened from.
class RegexEditorWindow extends ConsumerStatefulWidget {
  final String scriptId;
  final RegexScope scope;
  final String? presetId;

  const RegexEditorWindow({
    super.key,
    required this.scriptId,
    required this.scope,
    this.presetId,
  });

  @override
  ConsumerState<RegexEditorWindow> createState() => _RegexEditorWindowState();
}

class _RegexEditorWindowState extends ConsumerState<RegexEditorWindow> {
  /// The script as last edited here; null until it has been found.
  PresetRegex? _script;
  Set<String> _stages = const {};
  Timer? _saveTimer;

  /// The script where it lives, watched until it shows up — a script created a
  /// moment ago may not be in its list yet when the window opens.
  ({PresetRegex script, Set<String> stages})? _find() {
    final id = widget.scriptId;
    switch (widget.scope) {
      case RegexScope.global:
        final script = ref
            .watch(globalRegexProvider)
            .value
            ?.where((r) => r.id == id)
            .firstOrNull;
        return script == null ? null : (script: script, stages: const {});
      case RegexScope.preset:
        final preset = ref
            .watch(presetListProvider)
            .value
            ?.where((p) => p.id == widget.presetId)
            .firstOrNull;
        final script = preset?.regexes.where((r) => r.id == id).firstOrNull;
        return script == null ? null : (script: script, stages: const {});
      case RegexScope.studio:
        final entry = ref
            .watch(studioRegexProvider)
            .value
            ?.where((r) => r.script.id == id)
            .firstOrNull;
        return entry == null
            ? null
            : (script: entry.script, stages: entry.stages);
    }
  }

  void _onChanged(PresetRegex updated) {
    _script = updated;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  void _save() {
    final script = _script;
    if (script == null || !mounted) return;
    _writeRegexScript(
      ref,
      script,
      widget.scope,
      presetId: widget.presetId,
      studioStages: _stages,
    );
  }

  Future<void> _setStages(Set<String> stages) async {
    setState(() => _stages = stages);
    final script = _script;
    if (script == null) return;
    await ref
        .read(studioRegexProvider.notifier)
        .updateRegex(StudioRegex(script: script, stages: stages));
  }

  @override
  void deactivate() {
    // Closing the window must not drop the last edit still waiting on the
    // debounce; ref is still usable here, unlike in dispose().
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      _save();
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_script == null) {
      final found = _find();
      if (found == null) return const Center(child: GlazeSpinner());
      _script = found.script;
      _stages = found.stages;
    }
    final studio = widget.scope == RegexScope.studio;
    return SheetView(
      title: 'regex_editor'.tr(),
      showRouteBackground: false,
      body: _RegexEditView(
        key: ValueKey(widget.scriptId),
        script: _script!,
        onChanged: _onChanged,
        studioStages: studio ? _stages : null,
        onStudioStagesChanged: studio ? _setStages : null,
      ),
    );
  }
}

// ── Edit view ──────────────────────────────────────────────────────────────────

class _RegexEditView extends StatefulWidget {
  final PresetRegex script;
  final ValueChanged<PresetRegex> onChanged;
  final Set<String>? studioStages;
  final ValueChanged<Set<String>>? onStudioStagesChanged;

  const _RegexEditView({
    super.key,
    required this.script,
    required this.onChanged,
    this.studioStages,
    this.onStudioStagesChanged,
  });

  @override
  State<_RegexEditView> createState() => _RegexEditViewState();
}

class _RegexEditViewState extends State<_RegexEditView> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _regexCtrl;
  late final TextEditingController _replacementCtrl;
  late final TextEditingController _trimOutCtrl;
  late final TextEditingController _minDepthCtrl;
  late final TextEditingController _maxDepthCtrl;

  @override
  void initState() {
    super.initState();
    final s = widget.script;
    _nameCtrl = TextEditingController(text: s.name);
    _regexCtrl = TextEditingController(text: s.regex);
    _replacementCtrl = TextEditingController(text: s.replacement);
    _trimOutCtrl = TextEditingController(text: s.trimOut);
    _minDepthCtrl = TextEditingController(text: s.minDepth?.toString() ?? '');
    _maxDepthCtrl = TextEditingController(text: s.maxDepth?.toString() ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _regexCtrl.dispose();
    _replacementCtrl.dispose();
    _trimOutCtrl.dispose();
    _minDepthCtrl.dispose();
    _maxDepthCtrl.dispose();
    super.dispose();
  }

  void _update(PresetRegex updated) => widget.onChanged(updated);

  void _openMacroSelector() {
    final options = [
      ('0', "regex_macro_none".tr()),
      ('1', 'regex_macro_raw'.tr()),
      ('2', 'regex_macro_escaped'.tr()),
    ];
    GlazeBottomSheet.show<void>(
      context,
      title: 'regex_macros_find'.tr(),
      items: options.map((o) {
        return BottomSheetItem(
          label: o.$2,
          icon: widget.script.macroRules == o.$1 ? Icons.check : null,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _update(widget.script.copyWith(macroRules: o.$1));
          },
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.script;

    return ListView(
      padding: EdgeInsets.fromLTRB(0, inSidebarPanel(context) ? 0 : 20, 0, 80)
          .add(
            EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top,
              bottom: MediaQuery.paddingOf(context).bottom,
            ),
          ),
      children: [
        if (widget.studioStages != null)
          MenuGroup(
            header: 'regex_studio_stages'.tr(),
            description: 'regex_studio_stages_description'.tr(),
            items: studioRegexStages.map((stage) {
              return _CheckboxOption(
                key: ValueKey('studio-regex-stage-$stage'),
                label: studioInjectionPointLabel(stage),
                value: widget.studioStages!.contains(stage),
                onChanged: (enabled) {
                  final stages = Set<String>.from(widget.studioStages!);
                  enabled ? stages.add(stage) : stages.remove(stage);
                  widget.onStudioStagesChanged?.call(stages);
                },
              );
            }).toList(),
          ),
        MenuGroup(
          header: 'regex_script_settings'.tr(),
          items: [
            MenuFieldItem(
              label: 'regex_script_name'.tr(),
              controller: _nameCtrl,
              onChanged: (v) => _update(s.copyWith(name: v)),
            ),
            MenuFieldItem(
              label: 'regex_find'.tr(),
              controller: _regexCtrl,
              onChanged: (v) => _update(s.copyWith(regex: v)),
            ),
            MenuFieldItem(
              label: 'regex_replace_with'.tr(),
              controller: _replacementCtrl,
              onChanged: (v) => _update(s.copyWith(replacement: v)),
              maxLines: 3,
            ),
            MenuFieldItem(
              label: 'regex_trim_out'.tr(),
              controller: _trimOutCtrl,
              onChanged: (v) => _update(s.copyWith(trimOut: v)),
              maxLines: 2,
            ),
          ],
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 500;
            final col1 = _buildCol1(context, s);
            final col2 = _buildCol2(context, s);
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: col1),
                  Expanded(child: col2),
                ],
              );
            }
            return Column(children: [col1, col2]);
          },
        ),
      ],
    );
  }

  Widget _buildCol1(BuildContext context, PresetRegex s) {
    final placements = [
      (1, 'regex_user_input'.tr()),
      (2, 'regex_ai_output'.tr()),
      (3, 'regex_slash_commands'.tr()),
      (5, 'regex_world_info'.tr()),
      (6, 'regex_reasoning'.tr()),
    ];
    return Column(
      children: [
        MenuGroup(
          header: 'regex_affects'.tr(),
          items: placements.map((opt) {
            return _CheckboxOption(
              label: opt.$2,
              value: s.placement.contains(opt.$1),
              onChanged: (v) {
                final list = List<int>.from(s.placement);
                v ? list.add(opt.$1) : list.remove(opt.$1);
                _update(s.copyWith(placement: list));
              },
            );
          }).toList(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: _DepthInput(
                  label: 'regex_min_depth'.tr(),
                  controller: _minDepthCtrl,
                  onChanged: (v) => _update(s.copyWith(minDepth: v)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _DepthInput(
                  label: 'regex_max_depth'.tr(),
                  controller: _maxDepthCtrl,
                  onChanged: (v) => _update(s.copyWith(maxDepth: v)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCol2(BuildContext context, PresetRegex s) {
    final ephemeralities = [
      (1, 'regex_alter_display'.tr()),
      (2, 'regex_alter_prompt'.tr()),
    ];
    final macroLabel = switch (s.macroRules) {
      '1' => 'regex_macro_raw'.tr(),
      '2' => 'regex_macro_escaped'.tr(),
      _ => "regex_macro_none".tr(),
    };
    return Column(
      children: [
        MenuGroup(
          header: 'regex_other_options'.tr(),
          items: [
            _CheckboxOption(
              label: 'regex_run_on_edit'.tr(),
              value: s.runOnEdit,
              onChanged: (v) => _update(s.copyWith(runOnEdit: v)),
            ),
            _CheckboxOption(
              key: const Key('regex_memory_book_retrieval'),
              label: 'regex_memory_book_retrieval'.tr(),
              value: s.memoryBookRetrieval,
              onChanged: (v) => _update(s.copyWith(memoryBookRetrieval: v)),
            ),
          ],
        ),
        MenuGroup(
          header: 'regex_macros_find'.tr(),
          items: [
            MenuSelectorItem(
              label: 'Substitution',
              currentValue: macroLabel,
              onTap: _openMacroSelector,
            ),
          ],
        ),
        MenuGroup(
          header: 'regex_ephemerality'.tr(),
          items: ephemeralities.map((opt) {
            return _CheckboxOption(
              label: opt.$2,
              value: s.ephemerality.contains(opt.$1),
              onChanged: (v) {
                final list = List<int>.from(s.ephemerality);
                v ? list.add(opt.$1) : list.remove(opt.$1);
                _update(s.copyWith(ephemerality: list));
              },
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ── Edit sub-widgets ────────────────────────────────────────────────────────────

class _CheckboxOption extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _CheckboxOption({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MenuSwitchItem(label: label, value: value, onChanged: onChanged);
  }
}

class _DepthInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final ValueChanged<int?> onChanged;

  const _DepthInput({
    required this.label,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: context.cs.outlineVariant),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            GlazeTextField(
              controller: controller,
              keyboardType: TextInputType.number,
              onChanged: (v) => onChanged(int.tryParse(v)),
              hint: 'regex_unlimited_placeholder'.tr(),
              isDense: true,
            ),
          ],
        ),
      ),
    );
  }
}
