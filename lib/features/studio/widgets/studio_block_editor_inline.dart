import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/models/studio_config.dart';
import '../../../shared/shell/nav_bar_suppression_provider.dart';
import '../../../shared/widgets/generic_editor.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../studio_injection_points.dart';

/// Inline block editor built on the shared [GenericEditor] (the same engine the
/// plain preset block editor uses), so editing an agentic block feels identical
/// to editing a plain one. Fields follow STUDIO_UX_ANALYSIS §5. The two agent
/// dropdowns mean opposite directions, so they are labelled `←`/`→`.
///
/// While it is open the shell's bottom nav bar is hidden: the editor is a
/// full-height form whose content field would otherwise run under the bar.
class StudioBlockEditorInline extends StatelessWidget {
  final StudioPresetBlock block;
  final ValueChanged<StudioPresetBlock> onChanged;
  final VoidCallback onDelete;
  final bool headerPrompt;

  const StudioBlockEditorInline({
    super.key,
    required this.block,
    required this.onChanged,
    required this.onDelete,
    this.headerPrompt = false,
  });

  /// Agent dropdown options — the pre-gen controllers (they produce briefs and
  /// receive specific-agent blocks). The final and post-processing agents are
  /// excluded.
  static List<Map<String, dynamic>> get agentOptions => [
    for (final spec in StudioControllerOntology.specs)
      if (!spec.isFinal && spec.phase != 'post_processing')
        {'label': spec.name, 'value': spec.id},
  ];

  @override
  Widget build(BuildContext context) {
    final fields = <GenericEditorField>[
      GenericEditorField(
        key: 'title',
        label: 'placeholder_block_name'.tr(),
        type: 'text',
      ),
      GenericEditorField(
        key: 'role',
        label: 'label_role'.tr(),
        type: 'select',
        options: const [
          {'label': 'System', 'value': 'system'},
          {'label': 'User', 'value': 'user'},
          {'label': 'Assistant', 'value': 'assistant'},
          {'label': 'Tool', 'value': 'tool'},
        ],
      ),
      GenericEditorField(
        key: 'mode',
        label: 'studio_field_mode'.tr(),
        type: 'select',
        options: [
          for (final mode in const ['direct', 'pregenBrief', 'agentResponse', 'functionPrefill'])
            {'label': studioBlockModeLabel(mode), 'value': mode},
        ],
      ),
      GenericEditorField(
        key: 'sourceAgentId',
        label: 'studio_field_source_agent'.tr(),
        type: 'select',
        options: agentOptions,
        showIf: (item) => item['mode'] == 'agentResponse',
      ),
      GenericEditorField(
        key: 'injectionPoint',
        label: 'studio_field_injection_point'.tr(),
        type: 'select',
        options: [
          for (final point in studioInjectionPoints)
            {'label': studioInjectionPointLabel(point), 'value': point},
        ],
      ),
      GenericEditorField(
        key: 'targetAgentId',
        label: 'studio_field_target_agent'.tr(),
        type: 'select',
        options: agentOptions,
        showIf: (item) => item['injectionPoint'] == 'specificAgent',
      ),
      // A brief/agent-response block emits what an agent produced, so it
      // carries no authored text. The field is only hidden, never cleared —
      // GenericEditor keeps untouched keys in its working copy, so the
      // content comes back if the mode is switched to direct again.
      GenericEditorField(
        key: 'content',
        label: 'section_content'.tr(),
        type: 'textarea',
        rows: 8,
        expandable: true,
        showIf: (item) =>
            item['mode'] != 'pregenBrief' && item['mode'] != 'agentResponse',
      ),
      // Depth placement: interleave this block INSIDE the chat-history array
      // instead of concatenating it before/after the whole history via
      // `order` — same concept as the classic (non-Studio) preset editor's
      // Author's Note depth field. Only meaningful for direct instructions
      // that aren't targeting a specific pre-gen agent's brief pipeline.
      GenericEditorField(
        key: 'insertionMode',
        label: 'label_insertion'.tr(),
        type: 'select',
        options: const [
          {'label': 'Relative', 'value': 'relative'},
          {'label': 'Depth', 'value': 'depth'},
        ],
        showIf: (item) => item['mode'] == 'direct',
      ),
      GenericEditorField(
        key: 'depth',
        label: 'label_depth'.tr(),
        type: 'select',
        options: List.generate(
          20,
          (i) => {'label': '${i + 1}', 'value': i + 1},
        ),
        showIf: (item) =>
            item['mode'] == 'direct' && item['insertionMode'] == 'depth',
      ),
      // Append-to-last-user-message: merge this block's (macro-expanded)
      // content into the last user-role history message instead of emitting it
      // as its own message — mirrors the classic preset's `appendToLastMessage`
      // toggle. Only meaningful for instruction blocks.
      GenericEditorField(
        key: 'appendToLastMessage',
        label: 'label_append_last_user'.tr(),
        type: 'switch',
        showIf: (item) => item['type'] == 'instruction',
      ),
    ];
    if (headerPrompt) {
      fields
        ..clear()
        ..add(
          GenericEditorField(
            key: 'content',
            label: 'studio_group_header_prompt'.tr(),
            type: 'textarea',
            rows: 12,
            expandable: true,
          ),
        );
    }
    final config = [GenericEditorSection(title: null, fields: fields)];

    return NavBarSuppressor(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: GenericEditor(
              item: block.toJson(),
              config: config,
              scrollable: true,
              onChanged: (values) =>
                  onChanged(StudioPresetBlock.fromJson(values)),
            ),
          ),
          if (!headerPrompt)
            Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                MediaQuery.paddingOf(context).bottom + 16,
              ),
              child: GlassSurface(
                borderRadius: BorderRadius.circular(12),
                tint: _danger.withValues(alpha: 0.14),
                border: Border.all(color: _danger.withValues(alpha: 0.35)),
                glowColor: _danger,
                onTap: onDelete,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.delete_outlined,
                        size: 20,
                        color: _danger,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'blocks_delete_block'.tr(),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _danger,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

const _danger = Color(0xFFFF4444);
