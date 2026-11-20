import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/models/preset.dart';
import '../../shared/widgets/fullscreen_editor.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/list_controls.dart';
import '../../shared/widgets/menu_group.dart';

/// Edits one prompt block of an agent: name, role, text, stash, removal.
/// Every change is reported through [onChanged] as it happens.
Future<void> showAgentBlockEditor(
  BuildContext context, {
  required PresetBlock block,
  required bool stashed,
  required ValueChanged<PresetBlock> onChanged,
  required ValueChanged<bool> onStash,
  required VoidCallback onDelete,
}) => GlazeBottomSheet.show<void>(
  context,
  title: 'agents_block_edit'.tr(),
  child: _AgentBlockEditor(
    block: block,
    stashed: stashed,
    onChanged: onChanged,
    onStash: onStash,
    onDelete: onDelete,
  ),
);

class _AgentBlockEditor extends StatefulWidget {
  final PresetBlock block;
  final bool stashed;
  final ValueChanged<PresetBlock> onChanged;
  final ValueChanged<bool> onStash;
  final VoidCallback onDelete;

  const _AgentBlockEditor({
    required this.block,
    required this.stashed,
    required this.onChanged,
    required this.onStash,
    required this.onDelete,
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
            MenuItem(
              icon: widget.stashed
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
              label: widget.stashed
                  ? 'action_unstash'.tr()
                  : 'action_stash'.tr(),
              onTap: () {
                _close();
                widget.onStash(!widget.stashed);
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
