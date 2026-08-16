import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/models/ledger_prompt_injection_mode.dart';
import '../../../core/models/ledger_prompt_injection_policy.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/models/studio_preset_block_groups.dart';
import '../../../core/models/studio_preset_block_reorder.dart';
import '../../../shared/theme/app_colors.dart';
import '../studio_injection_points.dart';
import '../studio_preset_stats.dart';
import 'studio_agent_row.dart';
import 'studio_block_row.dart';

/// The id of the Post Clean block that drives the Fact Checker pass. Surfaced
/// as its own row rather than buried among the generic Post Clean blocks.
const _kCleanerAuditBlockId = 'cleaner_audit';

/// The agentic preset's whole block list: every injection point rendered at
/// once, one section per stage, in the pipeline order given by [sections].
///
/// A section reads top to bottom as the stage itself: its header, the agents
/// that run there, then the blocks addressed to them. Each section is
/// collapsible — tapping its header folds the agents and blocks underneath, so
/// a phone-sized screen is not one giant list.
///
/// It is a single [ReorderableListView] rather than one list per section, so a
/// block can be dragged across a section header — the section a row lands in
/// becomes its injection point, and [onReorder] reports the resulting
/// placements. Only block rows carry a drag handle; headers, agents and the
/// post-processing setting never move.
class StudioBlockSectionList extends StatefulWidget {
  /// The preset being edited — its blocks fill the sections, and its
  /// `agentEnabled` map drives the agent switches.
  final StudioPreset preset;

  /// `(injectionPoint, label)` pairs, rendered top to bottom.
  final List<(String, String)> sections;

  final ValueChanged<List<StudioPresetRowPlacement>> onReorder;
  final ValueChanged<StudioPresetBlock> onEdit;
  final void Function(StudioPresetBlock block, bool enabled) onToggle;
  final void Function(StudioPresetBlockGroup group, String blockId)
  onSelectExclusive;
  final void Function(StudioPresetBlockGroup group, bool enabled) onToggleGroup;
  final ValueChanged<StudioPresetBlock> onDelete;
  final ValueChanged<StudioPresetBlockGroup> onDeleteGroup;
  final void Function(String blockId, StudioPresetBlockGroup group)
  onMoveToGroup;
  final void Function(String blockId, String injectionPoint) onMoveToSection;
  final void Function(String specId, bool enabled) onToggleAgent;
  final ValueChanged<LedgerPromptInjectionMode> onLedgerPromptInjectionChanged;

  const StudioBlockSectionList({
    super.key,
    required this.preset,
    required this.sections,
    required this.onReorder,
    required this.onEdit,
    required this.onToggle,
    required this.onSelectExclusive,
    required this.onToggleGroup,
    required this.onDelete,
    required this.onDeleteGroup,
    required this.onMoveToGroup,
    required this.onMoveToSection,
    required this.onToggleAgent,
    required this.onLedgerPromptInjectionChanged,
  });

  @override
  State<StudioBlockSectionList> createState() => _StudioBlockSectionListState();
}

class _StudioBlockSectionListState extends State<StudioBlockSectionList> {
  /// Per-section expanded state, keyed by injection point. Defaults to expanded
  /// so the editor opens showing everything (no regression for desktop); the
  /// user folds what they are not editing.
  final Map<String, bool> _expanded = {};

  bool _isExpanded(String point) => _expanded[point] ?? true;

  void _toggle(String point) {
    setState(() => _expanded[point] = !_isExpanded(point));
  }

  /// Flattens the sections into the list's items: a header per stage, the
  /// agents that run there (each followed by its own settings, where it has
  /// any), then the grouped block rows or an empty placeholder. Collapsed
  /// sections emit only their header.
  List<_StudioListRow> _rows() {
    final rows = <_StudioListRow>[];
    for (final (point, label) in widget.sections) {
      final allSectionBlocks =
          widget.preset.blocks.where((b) => b.injectionPoint == point).toList()
            ..sort((a, b) => a.order.compareTo(b.order));
      rows.add(
        _StudioListRow.header(
          point,
          label: label,
          count: allSectionBlocks.length,
          expanded: _isExpanded(point),
          onToggle: () => _toggle(point),
        ),
      );
      if (!_isExpanded(point)) continue;

      // The Fact Checker is a Post Clean block with its own surfaced row, so
      // pull it out before grouping the rest.
      final StudioPresetBlock? factChecker = (point == 'cleaner')
          ? allSectionBlocks
                .where((b) => b.id == _kCleanerAuditBlockId)
                .firstOrNull
          : null;
      final sectionBlocks = factChecker == null
          ? allSectionBlocks
          : allSectionBlocks
                .where((b) => b.id != _kCleanerAuditBlockId)
                .toList();

      for (final spec in studioAgentsForInjectionPoint(point)) {
        rows.add(_StudioListRow.agent(point, spec));
        if (point == 'ledger' && spec.id == 'ledger') {
          rows.add(_StudioListRow.ledgerPromptInjection(point));
        }
        // The post-processing context setting controls how many trailing
        // messages a post-processing agent is handed. It only applies to the
        // Post Clean agent — the Ledger always pulls its own fixed window of
        // recent history, so the setting is not surfaced under it.
        if (spec.phase == 'post_processing' &&
            spec.id != 'ledger' &&
            studioAgentEnabled(widget.preset, spec)) {
          rows.add(_StudioListRow.postContext(point));
        }
      }
      if (factChecker != null) {
        rows.add(_StudioListRow.factChecker(point, factChecker));
      }
      final entries = groupStudioPresetBlocks(sectionBlocks);
      if (entries.isEmpty) {
        rows.add(_StudioListRow.placeholder(point));
        continue;
      }
      for (final entry in entries) {
        rows.add(_StudioListRow.block(point, entry));
      }
    }
    return rows;
  }

  void _handleReorder(int oldIndex, int newIndex) {
    final rows = _rows();
    if (oldIndex < 0 || oldIndex >= rows.length) return;
    // Only block rows have a drag handle; guard anyway so a stray reorder can
    // never rewrite the list from a header, agent or settings row.
    if (rows[oldIndex].entry == null) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = [...rows];
    moved.insert(newIndex, moved.removeAt(oldIndex));

    // Walk the reordered list and hand each row the section it now sits under.
    // A row dropped above the very first header belongs to that first section.
    var current = widget.sections.first.$1;
    final placements = <StudioPresetRowPlacement>[];
    for (final row in moved) {
      if (row.isHeader) {
        current = row.point;
        continue;
      }
      final entry = row.entry;
      if (entry == null) {
        continue; // agent, settings, fact checker or placeholder
      }
      placements.add(
        StudioPresetRowPlacement(entry: entry, injectionPoint: current),
      );
    }
    widget.onReorder(placements);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: rows.length,
      // TODO: migrate to onReorderItem (newIndex semantics differ — see Flutter changelog).
      // ignore: deprecated_member_use
      onReorder: _handleReorder,
      itemBuilder: (context, i) => _buildRow(context, rows, i),
    );
  }

  Widget _buildRow(BuildContext context, List<_StudioListRow> rows, int i) {
    final row = rows[i];
    if (row.isHeader) {
      return DragTarget<String>(
        key: ValueKey('studio_section_${row.point}'),
        onAcceptWithDetails: (details) =>
            widget.onMoveToSection(details.data, row.point),
        builder: (context, candidates, _) => ColoredBox(
          color: candidates.isEmpty
              ? Colors.transparent
              : context.cs.primary.withValues(alpha: 0.08),
          child: StudioBlockSectionHeader(
            label: row.label!,
            count: row.count,
            expanded: row.expanded,
            onToggle: row.onToggle!,
            isFirst: i == 0,
          ),
        ),
      );
    }
    // The row before a header (or at the very end) drops its rule: the next
    // section header draws one, and the "Add Block" row closes the card.
    final isLast = i == rows.length - 1 || rows[i + 1].isHeader;
    if (row.spec case final spec?) {
      return StudioAgentRow(
        key: ValueKey('studio_agent_${row.point}_${spec.id}'),
        spec: spec,
        enabled: studioAgentEnabled(widget.preset, spec),
        onToggle: (v) => widget.onToggleAgent(spec.id, v),
        isLast: isLast,
      );
    }
    if (row.isPostContext) {
      return StudioPostContextSetting(
        key: ValueKey('studio_post_context_${row.point}'),
        isLast: isLast,
      );
    }
    if (row.isLedgerPromptInjection) {
      return _StudioLedgerPromptInjectionSetting(
        key: const ValueKey('studio_ledger_prompt_injection'),
        value: deriveLedgerPromptInjectionPolicy(widget.preset).effectiveMode,
        onChanged: widget.onLedgerPromptInjectionChanged,
      );
    }
    if (row.isFactChecker) {
      final block = row.factCheckerBlock!;
      return StudioFactCheckerRow(
        key: ValueKey('studio_fact_checker_${block.id}'),
        block: block,
        isLast: isLast,
        onEdit: () => widget.onEdit(block),
        onToggle: (v) => widget.onToggle(block, v),
      );
    }
    final entry = row.entry;
    if (entry == null) {
      return Padding(
        key: ValueKey('studio_section_empty_${row.point}'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text(
          'studio_section_empty'.tr(),
          style: TextStyle(
            fontSize: 13,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }
    if (entry.header != null) {
      return StudioBlockGroupRow(
        key: ValueKey('studio_group_${entry.header!.id}'),
        group: entry,
        preset: widget.preset,
        dragIndex: i,
        isLast: isLast,
        onSelectExclusive: (id) => widget.onSelectExclusive(entry, id),
        onToggleGroup: (enabled) => widget.onToggleGroup(entry, enabled),
        onToggle: widget.onToggle,
        onEdit: widget.onEdit,
        onDelete: widget.onDelete,
        onDeleteGroup: widget.onDeleteGroup,
        onMoveBlock: widget.onMoveToGroup,
      );
    }
    final block = entry.standalone!;
    return StudioBlockRow(
      key: ValueKey('studio_block_${block.id}'),
      block: block,
      preset: widget.preset,
      dragIndex: i,
      isLast: isLast,
      onEdit: () => widget.onEdit(block),
      onToggle: (v) => widget.onToggle(block, v),
      onLongPress: () => widget.onDelete(block),
      moveDragData: block.id,
    );
  }
}

/// One item of the flat list: a section header, one of the section's agents,
/// the post-processing setting, the Fact Checker row, the empty placeholder,
/// or a draggable block row. Only the last carries an [entry] and can be
/// dragged.
class _StudioListRow {
  final String point;
  final String? label;
  final int count;
  final bool expanded;
  final VoidCallback? onToggle;
  final StudioPresetBlockGroup? entry;
  final StudioControllerSpec? spec;
  final bool isPostContext;
  final bool isFactChecker;
  final bool isLedgerPromptInjection;
  final StudioPresetBlock? factCheckerBlock;

  const _StudioListRow.header(
    this.point, {
    required this.label,
    required this.count,
    required this.expanded,
    required this.onToggle,
  }) : entry = null,
       spec = null,
       isPostContext = false,
       isFactChecker = false,
       isLedgerPromptInjection = false,
       factCheckerBlock = null;

  const _StudioListRow.agent(this.point, this.spec)
    : label = null,
      count = 0,
      expanded = false,
      onToggle = null,
      entry = null,
      isPostContext = false,
      isFactChecker = false,
      isLedgerPromptInjection = false,
      factCheckerBlock = null;

  const _StudioListRow.postContext(this.point)
    : label = null,
      count = 0,
      expanded = false,
      onToggle = null,
      entry = null,
      spec = null,
      isPostContext = true,
      isFactChecker = false,
      isLedgerPromptInjection = false,
      factCheckerBlock = null;

  const _StudioListRow.ledgerPromptInjection(this.point)
    : label = null,
      count = 0,
      expanded = false,
      onToggle = null,
      entry = null,
      spec = null,
      isPostContext = false,
      isFactChecker = false,
      isLedgerPromptInjection = true,
      factCheckerBlock = null;

  const _StudioListRow.factChecker(this.point, this.factCheckerBlock)
    : label = null,
      count = 0,
      expanded = false,
      onToggle = null,
      entry = null,
      spec = null,
      isPostContext = false,
      isFactChecker = true,
      isLedgerPromptInjection = false;

  const _StudioListRow.placeholder(this.point)
    : label = null,
      count = 0,
      expanded = false,
      onToggle = null,
      entry = null,
      spec = null,
      isPostContext = false,
      isFactChecker = false,
      isLedgerPromptInjection = false,
      factCheckerBlock = null;

  const _StudioListRow.block(this.point, this.entry)
    : label = null,
      count = 0,
      expanded = false,
      onToggle = null,
      spec = null,
      isPostContext = false,
      isFactChecker = false,
      isLedgerPromptInjection = false,
      factCheckerBlock = null;

  bool get isHeader => label != null;
}

class _StudioLedgerPromptInjectionSetting extends StatelessWidget {
  const _StudioLedgerPromptInjectionSetting({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final LedgerPromptInjectionMode value;
  final ValueChanged<LedgerPromptInjectionMode> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: DropdownButtonFormField<LedgerPromptInjectionMode>(
      initialValue: value == LedgerPromptInjectionMode.gapFiller
          ? LedgerPromptInjectionMode.gapFiller
          : LedgerPromptInjectionMode.legacy,
      decoration: InputDecoration(
        labelText: 'studio_ledger_prompt_injection'.tr(),
        helperText: value == LedgerPromptInjectionMode.gapFiller
            ? 'studio_ledger_prompt_injection_gap_filler_desc'.tr()
            : 'studio_ledger_prompt_injection_legacy_desc'.tr(),
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
      items: [
        DropdownMenuItem(
          value: LedgerPromptInjectionMode.gapFiller,
          child: Text('studio_ledger_prompt_injection_gap_filler'.tr()),
        ),
        DropdownMenuItem(
          value: LedgerPromptInjectionMode.legacy,
          child: Text('studio_ledger_prompt_injection_legacy'.tr()),
        ),
      ],
      onChanged: (next) {
        if (next != null) onChanged(next);
      },
    ),
  );
}
