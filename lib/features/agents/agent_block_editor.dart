import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/models/preset.dart';
import '../../shared/widgets/fullscreen_editor.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/list_controls.dart';
import '../../shared/widgets/menu_group.dart';

/// Edits one prompt block of an agent: name, role, text, order, removal.
/// Every change is reported through [onChanged] as it happens.
Future<void> showAgentBlockEditor(
  BuildContext context, {
  required PresetBlock block,
  required bool canMoveUp,
  required bool canMoveDown,
  required ValueChanged<PresetBlock> onChanged,
  required VoidCallback onDelete,
  required ValueChanged<int> onMove,
}) => GlazeBottomSheet.show<void>(
  context,
  title: 'agents_block_edit'.tr(),
  child: _AgentBlockEditor(
    block: block,
    canMoveUp: canMoveUp,
    canMoveDown: canMoveDown,
    onChanged: onChanged,
    onDelete: onDelete,
    onMove: onMove,
  ),
);

class _AgentBlockEditor extends StatefulWidget {
  final PresetBlock block;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<PresetBlock> onChanged;
  final VoidCallback onDelete;
  final ValueChanged<int> onMove;

  const _AgentBlockEditor({
    required this.block,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onChanged,
    required this.onDelete,
    required this.onMove,
  });

  @override
  State<_AgentBlockEditor> createState() => _AgentBlockEditorState();
}

class _AgentBlockEditorState extends State<_AgentBlockEditor> {
  late PresetBlock _block = widget.block;
  late final _name = TextEditingController(text: _block.name);
  late final _content = TextEditingController(text: _block.content);

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  void _set(PresetBlock next) {
    setState(() => _block = next);
    widget.onChanged(next);
  }

  void _close() => Navigator.of(context, rootNavigator: true).pop();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MenuGroup(
          items: [
            MenuFieldItem(
              label: 'agents_block_name'.tr(),
              controller: _name,
              onChanged: (v) => _set(_block.copyWith(name: v)),
            ),
            MenuSelectorItem(
              label: 'agents_block_role'.tr(),
              currentValue: _block.role,
              onTap: () => showGlazePickerSheet(
                context,
                title: 'agents_block_role'.tr(),
                items: [
                  for (final role in const ['system', 'user', 'assistant'])
                    GlazePickerItem(
                      label: role,
                      isActive: role == _block.role,
                      value: role,
                    ),
                ],
                onSelect: (v) => _set(_block.copyWith(role: v as String)),
              ),
            ),
            MenuSwitchItem(
              label: 'agents_block_enabled'.tr(),
              value: _block.enabled,
              onChanged: (v) => _set(_block.copyWith(enabled: v)),
            ),
            MenuFieldItem(
              label: 'agents_block_content'.tr(),
              controller: _content,
              maxLines: 12,
              minLines: 4,
              onChanged: (v) => _set(_block.copyWith(content: v)),
              onExpand: () => FullscreenEditorScreen.show(
                context,
                title: _block.name,
                initialValue: _content.text,
                onChanged: (v) {
                  _content.text = v;
                  _set(_block.copyWith(content: v));
                },
              ),
            ),
          ],
        ),
        MenuGroup(
          items: [
            if (widget.canMoveUp)
              MenuItem(
                icon: Icons.arrow_upward,
                label: 'agents_block_move_up'.tr(),
                onTap: () {
                  _close();
                  widget.onMove(-1);
                },
              ),
            if (widget.canMoveDown)
              MenuItem(
                icon: Icons.arrow_downward,
                label: 'agents_block_move_down'.tr(),
                onTap: () {
                  _close();
                  widget.onMove(1);
                },
              ),
            MenuItem(
              icon: Icons.delete_outline,
              label: 'agents_block_delete'.tr(),
              onTap: () {
                _close();
                widget.onDelete();
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
