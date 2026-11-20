import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/agents/agent_templates.dart';
import '../../core/models/agent_definition.dart';
import '../../core/services/file_export_service.dart';
import '../../core/state/agent_providers.dart';
import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/confirm_delete_sheet.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_sheet.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_switch.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/menu_group.dart';
import '../../shared/widgets/sheet_view.dart';
import 'agent_bindings_sheet.dart';
import 'agent_editor.dart';
import 'agent_labels.dart';

/// Opens the agent library as a sheet over the current screen.
Future<void> showAgentsSheet(BuildContext context) => showGlazeSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (_) => const AgentsScreen(),
);

/// The agent library: every agent grouped by when it runs, with its global
/// switch, its bindings and an editor. Reached from Tools (`/tools/agents`)
/// and from the chat's agents sheet.
class AgentsScreen extends ConsumerStatefulWidget {
  final bool startExpanded;

  const AgentsScreen({super.key, this.startExpanded = false});

  @override
  ConsumerState<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends ConsumerState<AgentsScreen> {
  String? _editingId;
  final _editorKey = GlobalKey<AgentEditorBodyState>();

  void _goBack() {
    if (_editingId != null) {
      _editorKey.currentState?.flush();
      setState(() => _editingId = null);
      return;
    }
    if (ModalRoute.of(context) is ModalBottomSheetRoute) {
      Navigator.of(context).maybePop();
    } else {
      closeExpandedToolScreen(context, ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(agentLibraryProvider);
    final editing = _editingId == null
        ? null
        : library.value?.where((a) => a.id == _editingId).firstOrNull;
    return SheetView(
      startExpanded: widget.startExpanded,
      showRouteBackground: false,
      title: editing?.displayName ?? 'agents_title'.tr(),
      showBack: true,
      onBack: _goBack,
      canPop: _editingId == null,
      actions: _editingId == null
          ? [
              SheetViewAction(
                icon: const Icon(Icons.add),
                tooltip: 'agents_new'.tr(),
                onPressed: () => _showAddMenu(context),
              ),
            ]
          : const [],
      body: editing != null
          ? AgentEditorBody(key: _editorKey, agent: editing)
          : library.when(
              skipLoadingOnReload: true,
              loading: () => const Center(child: GlazeSpinner()),
              error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
              data: (agents) =>
                  Builder(builder: (context) => _buildList(context, agents)),
            ),
    );
  }

  Widget _buildList(BuildContext context, List<AgentDefinition> agents) {
    final groups = <String, List<AgentDefinition>>{
      for (final phase in AgentPhase.all) phase: [],
    };
    for (final agent in agents) {
      (groups[agent.phase] ?? groups[AgentPhase.preGeneration]!).add(agent);
    }
    return ListView(
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 8,
        bottom: MediaQuery.paddingOf(context).bottom + 24,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'agents_intro'.tr(),
            style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
          ),
        ),
        if (agents.isEmpty)
          MenuGroup(
            header: 'agents_from_template'.tr(),
            items: [
              for (final template in agentTemplates)
                MenuItem(
                  icon: agentPhaseIcon(template.build().phase),
                  label: template.nameKey.tr(),
                  subtitle: template.descriptionKey.tr(),
                  onTap: () => _createFromTemplate(template),
                ),
            ],
          ),
        for (final phase in AgentPhase.all)
          if (groups[phase]!.isNotEmpty)
            MenuGroup(
              header: agentPhaseLabel(phase),
              description: agentPhaseHint(phase),
              headerIcon: agentPhaseIcon(phase),
              items: [
                for (final agent in groups[phase]!) _agentRow(context, agent),
              ],
            ),
      ],
    );
  }

  Widget _agentRow(BuildContext context, AgentDefinition agent) {
    final subtitle = [
      agentResultLabel(agent.resultType),
      if (agent.description.trim().isNotEmpty) agent.description.trim(),
    ].join(' · ');
    return MenuItem(
      icon: agentPhaseIcon(agent.phase),
      label: agent.displayName,
      subtitle: subtitle,
      onTap: () => setState(() => _editingId = agent.id),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlazeSwitch(
            value: agent.enabledGlobally,
            onChanged: (value) => ref
                .read(agentLibraryProvider.notifier)
                .save(agent.copyWith(enabledGlobally: value)),
          ),
          const SizedBox(width: 4),
          InkResponse(
            radius: 20,
            onTap: () => _showAgentMenu(context, agent),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                Icons.more_vert,
                size: 20,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddMenu(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'agents_title'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.add_circle_outline,
          label: 'agents_new'.tr(),
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            final agent = await ref
                .read(agentLibraryProvider.notifier)
                .create(name: 'agents_new'.tr());
            if (mounted) setState(() => _editingId = agent.id);
          },
        ),
        BottomSheetItem(
          icon: Icons.auto_awesome_outlined,
          label: 'agents_from_template'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _showTemplates(context);
          },
        ),
        BottomSheetItem(
          icon: Icons.file_upload_outlined,
          label: 'agents_import'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _import();
          },
        ),
      ],
    );
  }

  void _showTemplates(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'agents_from_template'.tr(),
      items: [
        for (final template in agentTemplates)
          BottomSheetItem(
            icon: agentPhaseIcon(template.build().phase),
            label: template.nameKey.tr(),
            hint: template.descriptionKey.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _createFromTemplate(template);
            },
          ),
      ],
    );
  }

  Future<void> _createFromTemplate(AgentTemplate template) async {
    final agent = await ref
        .read(agentLibraryProvider.notifier)
        .createFromTemplate(
          template,
          name: template.nameKey.tr(),
          description: template.descriptionKey.tr(),
        );
    if (mounted) setState(() => _editingId = agent.id);
  }

  void _showAgentMenu(BuildContext context, AgentDefinition agent) {
    GlazeBottomSheet.show<void>(
      context,
      title: agent.displayName,
      items: [
        BottomSheetItem(
          icon: Icons.edit_outlined,
          label: 'agents_edit'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => _editingId = agent.id);
          },
        ),
        BottomSheetItem(
          icon: Icons.link,
          label: 'agents_bindings'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            showAgentBindingsSheet(context, agent.id);
          },
        ),
        BottomSheetItem(
          icon: Icons.copy_outlined,
          label: 'agents_duplicate'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref.read(agentLibraryProvider.notifier).duplicate(agent);
          },
        ),
        BottomSheetItem(
          icon: Icons.file_download_outlined,
          label: 'agents_export'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _export(agent);
          },
        ),
        BottomSheetItem(
          icon: Icons.delete_outline,
          label: 'agents_delete'.tr(),
          isDestructive: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            final ok = await confirmDeleteSheet(
              context,
              title: 'agents_delete_title'.tr(),
              description: 'agents_delete_confirm'.tr(
                args: [agent.displayName],
              ),
            );
            if (ok) {
              await ref.read(agentLibraryProvider.notifier).delete(agent.id);
            }
          },
        ),
      ],
    );
  }

  Future<void> _export(AgentDefinition agent) async {
    final safeName = agent.displayName
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .trim();
    try {
      final path = await FileExportService.export(
        data: AgentLibraryNotifier.exportJson(agent),
        filename: '${safeName.isEmpty ? 'agent' : safeName}.glazeagent.json',
        subfolder: 'agents',
      );
      if (path.isEmpty || !mounted) return;
      GlazeToast.show(context, 'agents_exported'.tr(args: [agent.displayName]));
    } catch (error) {
      if (mounted) GlazeToast.show(context, '$error');
    }
  }

  Future<void> _import() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: Platform.isIOS ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isIOS ? null : ['json'],
        withData: true,
      );
    } catch (_) {}
    if (!mounted || result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    try {
      final raw = picked.bytes != null && picked.bytes!.isNotEmpty
          ? utf8.decode(picked.bytes!)
          : await File(picked.path!).readAsString();
      final agent = await ref
          .read(agentLibraryProvider.notifier)
          .importJson(raw);
      if (!mounted) return;
      GlazeToast.show(context, 'agents_imported'.tr(args: [agent.displayName]));
    } catch (_) {
      if (mounted) GlazeToast.show(context, 'agents_import_failed'.tr());
    }
  }
}
