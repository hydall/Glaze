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

import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../core/models/preset.dart';
import '../../core/models/studio_regex.dart';
import '../../core/services/file_export_service.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/global_regex_provider.dart';
import '../../core/state/studio_feature_provider.dart';
import '../../core/state/studio_regex_provider.dart';
import '../../core/utils/id_generator.dart';
import '../presets/preset_list_provider.dart';
import '../studio/studio_injection_points.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/menu_group.dart';
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

  Future<void> _saveActiveScript(PresetRegex script) async {
    if (_isStudioScript) {
      await ref
          .read(studioRegexProvider.notifier)
          .updateRegex(
            StudioRegex(script: script, stages: _activeStudioStages),
          );
    } else if (_isPresetScript) {
      final pid = _effectivePresetId;
      if (pid == null) return;
      final presets = ref.read(presetListProvider).value ?? [];
      final preset = presets.where((p) => p.id == pid).firstOrNull;
      if (preset == null) return;
      final updated = preset.regexes
          .map((r) => r.id == script.id ? script : r)
          .toList();
      await ref
          .read(presetListProvider.notifier)
          .updatePreset(preset.copyWith(regexes: updated));
    } else {
      await ref.read(globalRegexProvider.notifier).updateRegex(script);
    }
  }

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

    return SheetView(
      startExpanded: widget.startExpanded,
      showRouteBackground: false,
      title: isEdit ? 'regex_editor'.tr() : 'menu_regex'.tr(),
      showBack: isEdit || widget.startExpanded,
      onBack: isEdit ? _goBack : _goBackFromList,
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
      floatingActionButton: isEdit
          ? null
          : FloatingActionButton.small(
              onPressed: () => _showAddMenu(context),
              backgroundColor: context.cs.primary,
              foregroundColor: Colors.black,
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildListView(
    BuildContext context, {
    required bool studioEnabled,
    required Preset? activePreset,
    required List<PresetRegex> presetRegexes,
    required List<PresetRegex> globalRegexes,
    required List<StudioRegex> studioRegexes,
  }) {
    return Builder(
      key: const ValueKey('regex-list'),
      builder: (innerContext) => ListView(
        key: const PageStorageKey('regex_list'),
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 16).add(
          EdgeInsets.only(
            top: MediaQuery.paddingOf(innerContext).top,
            bottom: MediaQuery.paddingOf(innerContext).bottom,
          ),
        ),
        children: [
          if (studioEnabled)
            _buildAgentGroup(innerContext, studioRegexes)
          else if (presetRegexes.isNotEmpty)
            _buildPresetGroup(innerContext, activePreset, presetRegexes),
          MenuGroup(
            header: 'regex_global_scripts'.tr(),
            items: [
              if (globalRegexes.isEmpty)
                const _EmptyState()
              else
                ...globalRegexes.map(
                  (r) => MenuScriptItem(
                    name: r.name,
                    subtitle: r.regex.isNotEmpty ? r.regex : null,
                    enabled: !r.disabled,
                    onToggle: (v) => _toggleScript(r, v, isPreset: false),
                    onTap: () => _selectScript(r, isPreset: false),
                    onMore: () => _showScriptMenu(innerContext, r, false),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildAgentGroup(BuildContext context, List<StudioRegex> entries) {
    return MenuGroup(
      header: 'regex_studio_scripts'.tr(),
      description: 'regex_studio_description'.tr(),
      items: [
        if (entries.isEmpty)
          const _EmptyState()
        else
          ...entries.map((entry) {
            final script = entry.script;
            return MenuScriptItem(
              name: script.name,
              subtitle: script.regex.isNotEmpty ? script.regex : null,
              enabled: !script.disabled,
              onToggle: (enabled) => _toggleScript(
                script,
                enabled,
                isPreset: false,
                isStudio: true,
                studioStages: entry.stages,
              ),
              onTap: () => _selectScript(
                script,
                isPreset: false,
                isStudio: true,
                studioStages: entry.stages,
              ),
              onMore: () =>
                  _showScriptMenu(context, script, false, isStudio: true),
            );
          }),
      ],
    );
  }

  Widget _buildPresetGroup(
    BuildContext context,
    Preset? activePreset,
    List<PresetRegex> presetRegexes,
  ) {
    return MenuGroup(
      header: 'regex_preset_scripts'.tr(),
      items: [
        if (activePreset != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: _PresetChip(
              presetName: activePreset.name,
              onTap: widget.presetId == null
                  ? () => context.go('/tools/presets')
                  : null,
            ),
          ),
        ...presetRegexes.map(
          (r) => MenuScriptItem(
            name: r.name,
            subtitle: r.regex.isNotEmpty ? r.regex : null,
            enabled: !r.disabled,
            onToggle: (v) => _toggleScript(r, v, isPreset: true),
            onTap: () => _selectScript(r, isPreset: true),
            onMore: () => _showScriptMenu(context, r, true),
          ),
        ),
      ],
    );
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
      child: GestureDetector(
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
      ),
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
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 80).add(
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
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                activeColor: context.cs.primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: context.cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
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
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: TextStyle(fontSize: 15, color: context.cs.onSurface),
              onChanged: (v) => onChanged(int.tryParse(v)),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: 'regex_unlimited_placeholder'.tr(),
                hintStyle: TextStyle(
                  color: context.cs.onSurfaceVariant.withValues(alpha: 0.4),
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
