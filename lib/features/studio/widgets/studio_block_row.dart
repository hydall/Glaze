import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/models/studio_preset_block_groups.dart';
import '../../../shared/theme/app_colors.dart';
import '../../presets/widgets/preset_block_row.dart';

/// Short, badge-sized name of a controller spec (`Continuity Controller` →
/// `Continuity`). An unknown id is echoed back rather than resolved through
/// [StudioControllerOntology.byId], which falls back to the last spec and would
/// silently mislabel a stale id as the Ledger.
String studioAgentShortName(String specId) {
  for (final spec in StudioControllerOntology.specs) {
    if (spec.id != specId) continue;
    return spec.name.replaceFirst(RegExp(r'\s+(Controller|Agent)$'), '').trim();
  }
  return specId;
}

/// Token estimate for one block, through the same tokenizer
/// `studioPresetTokenEstimate` sums — so the row pills add up to the
/// dashboard's total.
int _blockTokens(StudioPresetBlock block) => estimateTokens(block.content);

/// One row of the agentic preset's block list — the [PresetBlockRow] layout
/// (drag handle, role icon, badges, name + token pill, edit, switch) applied to
/// a [StudioPresetBlock].
class StudioBlockRow extends StatelessWidget {
  final StudioPresetBlock block;

  /// The preset that owns [block]. Used to resolve controller macro and
  /// alternative badges. Null suppresses the badge.
  final StudioPreset? preset;

  /// Index inside the enclosing [ReorderableListView]. Null renders a plain
  /// spacer instead of a drag handle (nested rows inside a group).
  final int? dragIndex;
  final bool isLast;

  /// Extra left inset for nested rows.
  final double indent;

  final VoidCallback onEdit;

  /// Null hides the switch (used by exclusive groups, which pass
  /// [trailing] instead).
  final ValueChanged<bool>? onToggle;

  /// Replaces the switch entirely (e.g. an exclusive group's radio glyph).
  final Widget? trailing;

  final VoidCallback? onLongPress;
  final String? moveDragData;

  const StudioBlockRow({
    super.key,
    required this.block,
    required this.onEdit,
    this.preset,
    this.dragIndex,
    this.isLast = false,
    this.indent = 0,
    this.onToggle,
    this.trailing,
    this.onLongPress,
    this.moveDragData,
  });

  @override
  Widget build(BuildContext context) {
    final title = block.title.isNotEmpty ? block.title : block.id;
    final tokens = _blockTokens(block);
    final modeLabel = _modeLabel();
    final targetLabel =
        block.injectionPoint == 'specificAgent' &&
            (block.targetAgentId ?? '').isNotEmpty
        ? '→ ${studioAgentShortName(block.targetAgentId!)}'
        : null;
    final controllerBadge = _controllerBadge();

    final Widget trailingWidget;
    if (trailing != null) {
      trailingWidget = trailing!;
    } else if (onToggle != null) {
      trailingWidget = Transform.scale(
        scale: 0.8,
        alignment: Alignment.centerRight,
        child: Switch(
          value: block.enabled,
          onChanged: block.locked ? null : onToggle,
          activeThumbColor: context.cs.primary,
        ),
      );
    } else {
      trailingWidget = const SizedBox(width: 40);
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: const Color(0x33808080),
            width: isLast ? 0 : 1,
          ),
        ),
      ),
      child: Opacity(
        opacity: block.enabled ? 1.0 : 0.5,
        child: InkWell(
          onTap: onEdit,
          onLongPress: onLongPress,
          child: Row(
            children: [
              if (dragIndex != null)
                ReorderableDragStartListener(
                  index: dragIndex!,
                  child: SizedBox(
                    width: 30,
                    height: 44,
                    child: Center(
                      child: Text(
                        '≡',
                        style: TextStyle(
                          fontSize: 20,
                          color: context.cs.onSurfaceVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              else
                SizedBox(width: 30.0 + indent, height: 44),
              _moveHandle(
                context,
                Icon(
                  presetBlockRoleIcon(block.role),
                  size: 16,
                  color: context.cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(width: 8),
              if (block.locked) ...[
                StudioBlockBadge(
                  label: 'studio_badge_locked'.tr(),
                  muted: true,
                ),
                const SizedBox(width: 6),
              ],
              if (modeLabel != null) ...[
                StudioBlockBadge(label: modeLabel),
                const SizedBox(width: 6),
              ],
              if (targetLabel != null) ...[
                StudioBlockBadge(label: targetLabel),
                const SizedBox(width: 6),
              ],
              if (controllerBadge != null) ...[
                StudioBlockBadge(
                  label: controllerBadge,
                  accent: true,
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: context.cs.onSurface,
                          ),
                        ),
                      ),
                      if (tokens > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '$tokens',
                            style: TextStyle(
                              fontSize: 11,
                              color: context.cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 36,
                height: 44,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onEdit,
                    child: Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: trailingWidget,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _moveHandle(BuildContext context, Widget child) {
    final data = moveDragData;
    if (data == null) return child;
    return LongPressDraggable<String>(
      data: data,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: context.cs.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: context.cs.primary),
          ),
          child: Text(
            block.title.isEmpty ? block.id : block.title,
            style: TextStyle(color: context.cs.onSurface),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.25, child: child),
      child: Tooltip(message: 'studio_move_block'.tr(), child: child),
    );
  }

  /// What the block emits (§5 "Режим"). `direct` is the default and stays
  /// unbadged so the common case reads clean.
  String? _modeLabel() {
    return switch (block.mode) {
      'pregenBrief' => 'studio_badge_brief'.tr(),
      'agentResponse' =>
        block.sourceAgentId.isEmpty
            ? 'studio_badge_agent'.tr()
            : '← ${studioAgentShortName(block.sourceAgentId)}',
      _ => null,
    };
  }

  /// Badge for blocks linked to a controller — either the macro block itself
  /// ("Controller: X") or an alternative block it replaces ("Alt: X").
  String? _controllerBadge() {
    final p = preset;
    if (p == null) return null;
    final macroSpecId = controllerSpecIdForMacroBlock(block);
    if (macroSpecId != null) {
      return 'Controller: ${studioAgentShortName(macroSpecId)}';
    }
    final altSpecId = controllerSpecIdForAlternativeBlock(p, block.id);
    if (altSpecId != null) {
      return 'Alt: ${studioAgentShortName(altSpecId)}';
    }
    return null;
  }
}

// ─── StudioBlockSectionHeader ─────────────────────────────────────────────────

/// Label above one injection point's blocks. The whole preset is rendered at
/// once, split into these sections in pipeline order, so the header is what
/// tells the reader which stage the rows underneath are addressed to. Tapping
/// the header folds the section's agents and blocks so a phone-sized screen is
/// not one giant list.
class StudioBlockSectionHeader extends StatelessWidget {
  final String label;
  final int count;

  /// Whether the section's rows are currently shown.
  final bool expanded;

  /// Toggles the section's expanded state.
  final VoidCallback onToggle;

  /// The first header follows the agents section's own divider, so it drops
  /// its rule to avoid two hairlines a gap apart.
  final bool isFirst;

  const StudioBlockSectionHeader({
    super.key,
    required this.label,
    required this.count,
    required this.expanded,
    required this.onToggle,
    this.isFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: isFirst
              ? BorderSide.none
              : const BorderSide(color: Color(0x33808080), width: 1),
        ),
      ),
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.expand_more,
                  size: 20,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── StudioFactCheckerRow ─────────────────────────────────────────────────────

/// Surfaces the `cleaner_audit` Post Clean block as a distinct, prominently
/// labelled Fact Checker row instead of burying it among the generic Post Clean
/// blocks. Its toggle is the block's `enabled` flag; tapping opens the block
/// editor so the audit prompt itself can be edited.
class StudioFactCheckerRow extends StatelessWidget {
  final StudioPresetBlock block;
  final bool isLast;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;

  const StudioFactCheckerRow({
    super.key,
    required this.block,
    required this.isLast,
    required this.onEdit,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: const Color(0x33808080),
            width: isLast ? 0 : 1,
          ),
        ),
      ),
      child: Opacity(
        opacity: block.enabled ? 1.0 : 0.5,
        child: InkWell(
          onTap: onEdit,
          child: Row(
            children: [
              const SizedBox(width: 30, height: 48),
              Icon(
                Icons.fact_check_outlined,
                size: 18,
                color: context.cs.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'studio_fact_checker'.tr(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: context.cs.onSurface,
                        ),
                      ),
                      Text(
                        'studio_fact_checker_desc'.tr(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 36,
                height: 48,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onEdit,
                    child: Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Transform.scale(
                  scale: 0.8,
                  alignment: Alignment.centerRight,
                  child: Switch(
                    value: block.enabled,
                    onChanged: onToggle,
                    activeThumbColor: context.cs.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── StudioBlockBadge ─────────────────────────────────────────────────────────

/// Compact pill used for a block's mode / routing hints, matching the plain
/// preset row's `System` / `↩ Last User` badges.
class StudioBlockBadge extends StatelessWidget {
  final String label;

  /// Muted badges use the neutral white tint instead of the accent colour.
  final bool muted;

  /// Accent badges use the secondary colour — used for controller/alternative
  /// badges to distinguish them from structural badges.
  final bool accent;

  const StudioBlockBadge({
    super.key,
    required this.label,
    this.muted = false,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent ? context.cs.secondary : context.cs.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: muted
            ? Colors.white.withValues(alpha: 0.08)
            : color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      // Agent names are long enough to squeeze the block title off the row, so
      // a badge never grows past a third of a phone's width.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 130),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: muted ? Colors.white.withValues(alpha: 0.4) : color,
          ),
        ),
      ),
    );
  }
}

// ─── StudioBlockGroupRow ──────────────────────────────────────────────────────

/// A `━`-headed section of the preset rendered as one draggable row that
/// expands into its child blocks. Exclusive groups (Point-of-View, Tense…)
/// swap the children's switches for radio glyphs so only one stays enabled.
class StudioBlockGroupRow extends StatefulWidget {
  final StudioPresetBlockGroup group;
  final int dragIndex;
  final bool isLast;
  final ValueChanged<String> onSelectExclusive;
  final void Function(StudioPresetBlock block, bool enabled) onToggle;
  final ValueChanged<StudioPresetBlock> onEdit;
  final ValueChanged<StudioPresetBlock> onDelete;
  final ValueChanged<StudioPresetBlockGroup> onDeleteGroup;
  final void Function(String blockId, StudioPresetBlockGroup group) onMoveBlock;
  final ValueChanged<bool> onToggleGroup;

  /// The preset that owns the group's blocks. Passed down to child
  /// [StudioBlockRow]s for controller/alternative badge resolution.
  final StudioPreset? preset;

  const StudioBlockGroupRow({
    super.key,
    required this.group,
    required this.dragIndex,
    required this.isLast,
    required this.onSelectExclusive,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onDeleteGroup,
    required this.onMoveBlock,
    required this.onToggleGroup,
    this.preset,
  });

  @override
  State<StudioBlockGroupRow> createState() => _StudioBlockGroupRowState();
}

class _StudioBlockGroupRowState extends State<StudioBlockGroupRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final header = group.header!;
    final title = header.title
        .replaceFirst(RegExp(r'^━[^\p{L}\p{N}]*', unicode: true), '')
        .trim();
    final enabledCount = group.children.where((b) => b.enabled).length;
    final selected = group.children.where((b) => b.enabled).firstOrNull;
    final subtitle = group.exclusive
        ? (selected == null
              ? 'studio_group_none'.tr()
              : (selected.title.isEmpty ? selected.id : selected.title))
        : 'studio_group_enabled'.tr(
            args: ['$enabledCount', '${group.children.length}'],
          );

    final openingBoundary = group.openingBoundary;
    final closingBoundary = group.closingBoundary;

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          !group.children.any((block) => block.id == details.data),
      onAcceptWithDetails: (details) => widget.onMoveBlock(details.data, group),
      builder: (context, candidates, _) => Container(
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? null
              : context.cs.primary.withValues(alpha: 0.08),
          border: Border(
            bottom: BorderSide(
              color: const Color(0x33808080),
              width: widget.isLast ? 0 : 1,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              onLongPress: () => widget.onDeleteGroup(group),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: widget.dragIndex,
                    child: SizedBox(
                      width: 30,
                      height: 44,
                      child: Center(
                        child: Text(
                          '≡',
                          style: TextStyle(
                            fontSize: 20,
                            color: context.cs.onSurfaceVariant.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Icon(
                    Icons.folder_outlined,
                    size: 16,
                    color: context.cs.primary.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 8),
                  if (group.exclusive) ...[
                    StudioBlockBadge(label: 'studio_badge_pick_one'.tr()),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title.isEmpty ? header.id : title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: context.cs.onSurface,
                            ),
                          ),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    value: header.enabled,
                    onChanged: widget.onToggleGroup,
                  ),
                  SizedBox(
                    width: 36,
                    height: 44,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => widget.onDeleteGroup(group),
                        borderRadius: BorderRadius.circular(20),
                        child: Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.expand_more,
                        size: 20,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_expanded && openingBoundary != null)
              StudioBlockRow(
                key: ValueKey('studio_block_${openingBoundary.id}'),
                block: openingBoundary,
                preset: widget.preset,
                indent: 16,
                isLast: group.children.isEmpty && closingBoundary == null,
                onEdit: () => widget.onEdit(openingBoundary),
              ),
            if (_expanded)
              StudioBlockRow(
                key: ValueKey('studio_group_prompt_${header.id}'),
                block: header.copyWith(
                  title: 'studio_group_header_prompt'.tr(),
                ),
                preset: widget.preset,
                indent: 16,
                isLast: group.children.isEmpty && closingBoundary == null,
                onEdit: () => widget.onEdit(header),
              ),
            if (_expanded)
              for (var i = 0; i < group.children.length; i++)
                StudioBlockRow(
                  key: ValueKey('studio_block_${group.children[i].id}'),
                  block: group.children[i],
                  preset: widget.preset,
                  moveDragData: group.children[i].id,
                  indent: 16,
                  isLast:
                      i == group.children.length - 1 && closingBoundary == null,
                  onEdit: () => widget.onEdit(group.children[i]),
                  onToggle:
                      group.exclusive &&
                          !isIndependentStudioGroupChild(
                            group,
                            group.children[i],
                          )
                      ? null
                      : (v) => widget.onToggle(group.children[i], v),
                  trailing:
                      group.exclusive &&
                          !isIndependentStudioGroupChild(
                            group,
                            group.children[i],
                          )
                      ? _radio(context, group.children[i])
                      : null,
                  onLongPress: () => widget.onDelete(group.children[i]),
                ),
            if (_expanded && closingBoundary != null)
              StudioBlockRow(
                key: ValueKey('studio_block_${closingBoundary.id}'),
                block: closingBoundary,
                preset: widget.preset,
                indent: 16,
                isLast: true,
                onEdit: () => widget.onEdit(closingBoundary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _radio(BuildContext context, StudioPresetBlock block) {
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      onPressed: block.enabled
          ? null
          : () => widget.onSelectExclusive(block.id),
      icon: Icon(
        block.enabled ? Icons.radio_button_checked : Icons.radio_button_off,
        size: 20,
        color: block.enabled ? context.cs.primary : context.cs.onSurfaceVariant,
      ),
    );
  }
}
