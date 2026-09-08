import 'package:flutter/material.dart';

import '../../../core/models/studio_config.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../../../shared/widgets/sheet_view.dart';

/// Dialog for editing a single [StudioPresetBlock].
///
/// Shows editable fields for: title, role, content, enabled, order, section,
/// and kind. Returns the updated block (or null if cancelled).
class StudioBlockEditorDialog extends StatefulWidget {
  final StudioPresetBlock block;
  final bool isNew;

  const StudioBlockEditorDialog({
    super.key,
    required this.block,
    this.isNew = false,
  });

  @override
  State<StudioBlockEditorDialog> createState() =>
      _StudioBlockEditorDialogState();
}

class _StudioBlockEditorDialogState extends State<StudioBlockEditorDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _contentCtrl;
  late String _role;
  late String _section;
  late String _kind;
  late bool _enabled;

  static const _roles = ['system', 'user', 'assistant'];
  static const _sections = [
    'pregen',
    'final',
    'cleaner',
    'ledger',
    'build',
    'brief_parser',
  ];
  static const _kinds = [
    'custom_text',
    'slot',
    'instruction',
    'agent_instruction',
    'tracker_instruction',
    'previous_agents',
    'user_persona',
    'char_card',
    'scenario',
    'char_personality',
    'example_dialogue',
    'authors_note',
    'static_context',
    'chat_history',
    'memory',
    'dynamic_context',
  ];

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.block.title);
    _contentCtrl = TextEditingController(text: widget.block.content);
    _role = widget.block.role;
    _section = widget.block.section;
    _kind = widget.block.kind;
    _enabled = widget.block.enabled;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: widget.isNew ? 'New Block' : 'Edit Block',
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check, size: 22),
          tooltip: 'Save',
          onPressed: _save,
        ),
      ],
      body: Material(
        type: MaterialType.transparency,
        child: ListView(
          children: [
            const SizedBox(height: 8),
            GlazeTextField(controller: _titleCtrl, label: 'Title'),
            const SizedBox(height: 16),
            _FieldLabel('Section'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _section,
              isExpanded: true,
              items: _sections
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _section = v ?? _section),
            ),
            const SizedBox(height: 16),
            _FieldLabel('Kind'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              isExpanded: true,
              items: _kinds
                  .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                  .toList(),
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            const SizedBox(height: 16),
            _FieldLabel('Role'),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                segments: _roles
                    .map((r) => ButtonSegment(value: r, label: Text(r)))
                    .toList(),
                selected: {_role},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _role = s.first),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: Text(
                widget.block.locked ? 'Enabled (required)' : 'Enabled',
              ),
              value: _enabled,
              onChanged: widget.block.locked
                  ? null
                  : (v) => setState(() => _enabled = v),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 8),
            GlazeTextField(
              controller: _contentCtrl,
              maxLines: 12,
              label: 'Content (macro templates supported)',
              hint: 'Use {{description}}, {{persona}}, {{memory}}, etc.',
            ),
            const SizedBox(height: 12),
            Text(
              'Studio final-agent briefs: either enable the '
              '"Previous Studio agents" block, or place these macros in '
              'custom final blocks: {{studio_agent_briefs}}, '
              '{{studio_continuity_brief}}, {{studio_agency_brief}}, '
              '{{studio_narrative_brief}}, {{studio_dialogue_brief}}, '
              '{{studio_guard_brief}}, {{studio_world_brief}}, '
              '{{studio_meta_brief}}, {{studio_beauty_brief}}. If any '
              'Studio brief macro is present, the Previous Studio agents '
              'block is skipped to avoid duplicates.',
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  void _save() {
    final updated = widget.block.copyWith(
      title: _titleCtrl.text,
      content: _contentCtrl.text,
      role: _role,
      section: _section,
      kind: _kind,
      enabled: _enabled,
    );
    Navigator.of(context).pop(updated);
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: context.cs.onSurfaceVariant,
      ),
    );
  }
}
