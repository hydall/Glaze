import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/agent_definition.dart';
import '../../core/models/preset.dart';
import '../../core/state/agent_providers.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_switch.dart';
import '../../shared/widgets/list_controls.dart';
import '../../shared/widgets/menu_group.dart';
import '../settings/widgets/api_slot_group.dart';
import 'agent_block_editor.dart';
import 'agent_labels.dart';

/// Edits one agent in place. Every change is saved shortly after it is made;
/// [flush] saves at once (leaving the editor).
class AgentEditorBody extends ConsumerStatefulWidget {
  final AgentDefinition agent;

  const AgentEditorBody({super.key, required this.agent});

  @override
  ConsumerState<AgentEditorBody> createState() => AgentEditorBodyState();
}

class AgentEditorBodyState extends ConsumerState<AgentEditorBody> {
  late AgentDefinition _agent = widget.agent;
  Timer? _saveTimer;
  bool _dirty = false;

  late final _name = TextEditingController(text: _agent.name);
  late final _description = TextEditingController(text: _agent.description);
  late final _contextSize = TextEditingController(
    text: '${_agent.contextSize}',
  );
  late final _temperature = TextEditingController(
    text: _agent.params.temperature?.toString() ?? '',
  );
  late final _maxTokens = TextEditingController(
    text: _agent.params.maxTokens?.toString() ?? '',
  );
  late final _timeout = TextEditingController(
    text: _agent.params.timeoutMs == null
        ? ''
        : '${_agent.params.timeoutMs! ~/ 1000}',
  );
  late final _everyN = TextEditingController(text: '${_agent.cadence.everyN}');
  late final _keywords = TextEditingController(
    text: _agent.cadence.keywords.join(', '),
  );
  late final _scanDepth = TextEditingController(
    text: '${_agent.cadence.scanDepth}',
  );
  late final _depth = TextEditingController(text: '${_agent.injection.depth}');

  @override
  void dispose() {
    flush();
    for (final controller in [
      _name,
      _description,
      _contextSize,
      _temperature,
      _maxTokens,
      _timeout,
      _everyN,
      _keywords,
      _scanDepth,
      _depth,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _update(AgentDefinition next) {
    setState(() => _agent = next);
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), flush);
  }

  /// Saves pending edits now.
  void flush() {
    _saveTimer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    unawaited(ref.read(agentLibraryProvider.notifier).save(_agent));
  }

  static int? _int(String text) => int.tryParse(text.trim());
  static double? _double(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));

  @override
  Widget build(BuildContext context) {
    final agent = _agent;
    final builtin = agent.isBuiltin;
    final library = ref.watch(agentLibraryProvider).value ?? const [];
    final others = [
      for (final other in library)
        if (other.id != agent.id) other,
    ];
    return ListView(
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 8,
        bottom: MediaQuery.paddingOf(context).bottom + 32,
      ),
      children: [
        if (builtin)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'agents_builtin_note'.tr(),
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
        MenuGroup(
          header: 'agents_section_basics'.tr(),
          items: [
            MenuFieldItem(
              label: 'agents_field_name'.tr(),
              controller: _name,
              onChanged: (v) => _update(_agent.copyWith(name: v)),
            ),
            MenuFieldItem(
              label: 'agents_field_description'.tr(),
              controller: _description,
              maxLines: 3,
              minLines: 1,
              onChanged: (v) => _update(_agent.copyWith(description: v)),
            ),
            MenuSelectorItem(
              label: 'agents_field_phase'.tr(),
              currentValue: agentPhaseLabel(agent.phase),
              description: agentPhaseHint(agent.phase),
              onTap: builtin ? () {} : () => _pickPhase(context),
            ),
            MenuSelectorItem(
              label: 'agents_field_result'.tr(),
              currentValue: agentResultLabel(agent.resultType),
              onTap: builtin ? () {} : () => _pickResult(context),
            ),
          ],
        ),
        _promptGroup(context),
        if (agent.resultType == AgentResultType.contextInjection)
          _injectionGroup(context),
        _connectionGroup(context),
        MenuGroup(
          header: 'agents_section_params'.tr(),
          description: 'agents_param_default'.tr(),
          items: [
            if (agent.phase != AgentPhase.postProcessing)
              _numberField(
                'agents_context_size'.tr(),
                _contextSize,
                (v) => _update(
                  _agent.copyWith(contextSize: (_int(v) ?? 5).clamp(1, 200)),
                ),
              ),
            _numberField(
              'agents_param_temperature'.tr(),
              _temperature,
              (v) => _update(
                _agent.copyWith(
                  params: _agent.params.copyWith(temperature: _double(v)),
                ),
              ),
              decimal: true,
            ),
            _numberField(
              'agents_param_max_tokens'.tr(),
              _maxTokens,
              (v) => _update(
                _agent.copyWith(
                  params: _agent.params.copyWith(maxTokens: _int(v)),
                ),
              ),
            ),
            _numberField('agents_param_timeout'.tr(), _timeout, (v) {
              final seconds = _int(v);
              _update(
                _agent.copyWith(
                  params: _agent.params.copyWith(
                    timeoutMs: seconds == null ? null : seconds * 1000,
                  ),
                ),
              );
            }),
            if (agent.phase != AgentPhase.postProcessing)
              MenuSwitchItem(
                label: 'agents_param_reasoning'.tr(),
                value: agent.params.requestReasoning ?? false,
                onChanged: (v) => _update(
                  _agent.copyWith(
                    params: _agent.params.copyWith(requestReasoning: v),
                  ),
                ),
              ),
          ],
        ),
        MenuGroup(
          header: 'agents_section_cadence'.tr(),
          items: [
            _numberField(
              'agents_every_n'.tr(),
              _everyN,
              (v) => _update(
                _agent.copyWith(
                  cadence: _agent.cadence.copyWith(
                    everyN: (_int(v) ?? 1).clamp(1, 1000),
                  ),
                ),
              ),
            ),
            MenuFieldItem(
              label: 'agents_keywords'.tr(),
              placeholder: 'agents_keywords_hint'.tr(),
              controller: _keywords,
              onChanged: (v) => _update(
                _agent.copyWith(
                  cadence: _agent.cadence.copyWith(
                    keywords: [
                      for (final word in v.split(','))
                        if (word.trim().isNotEmpty) word.trim(),
                    ],
                  ),
                ),
              ),
            ),
            if (agent.cadence.keywords.isNotEmpty)
              _numberField(
                'agents_scan_depth'.tr(),
                _scanDepth,
                (v) => _update(
                  _agent.copyWith(
                    cadence: _agent.cadence.copyWith(
                      scanDepth: (_int(v) ?? 3).clamp(1, 200),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (others.isNotEmpty)
          MenuGroup(
            header: 'agents_section_links'.tr(),
            items: [
              MenuSelectorItem(
                label: 'agents_depends_on'.tr(),
                currentValue: _names(agent.dependsOn, library),
                onTap: () => _pickAgents(
                  context,
                  title: 'agents_depends_on'.tr(),
                  candidates: others,
                  selected: agent.dependsOn,
                  onChanged: (ids) => _update(_agent.copyWith(dependsOn: ids)),
                ),
              ),
              if (agent.phase == AgentPhase.preGeneration)
                MenuSelectorItem(
                  label: 'agents_sees'.tr(),
                  currentValue: _names(agent.seesOutputsOf, library),
                  onTap: () => _pickAgents(
                    context,
                    title: 'agents_sees'.tr(),
                    candidates: [
                      for (final other in others)
                        if (other.phase != AgentPhase.postProcessing) other,
                    ],
                    selected: agent.seesOutputsOf,
                    onChanged: (ids) =>
                        _update(_agent.copyWith(seesOutputsOf: ids)),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _numberField(
    String label,
    TextEditingController controller,
    ValueChanged<String> onChanged, {
    bool decimal = false,
  }) => MenuFieldItem(
    label: label,
    controller: controller,
    keyboardType: TextInputType.numberWithOptions(decimal: decimal),
    inputFormatters: [
      FilteringTextInputFormatter.allow(
        RegExp(decimal ? r'[0-9.,]' : r'[0-9]'),
      ),
    ],
    onChanged: onChanged,
  );

  String _names(List<String> ids, List<AgentDefinition> library) {
    if (ids.isEmpty) return 'agents_none'.tr();
    return [
      for (final id in ids)
        library.where((a) => a.id == id).firstOrNull?.displayName ?? id,
    ].join(', ');
  }

  Widget _promptGroup(BuildContext context) {
    final blocks = _agent.blocks;
    return MenuGroup(
      header: 'agents_section_prompt'.tr(),
      description: 'agents_prompt_hint'.tr(),
      items: [
        for (var i = 0; i < blocks.length; i++)
          MenuItem(
            icon: Icons.notes,
            label: blocks[i].name.trim().isEmpty
                ? 'agents_block_new'.tr()
                : blocks[i].name,
            subtitle:
                '${blocks[i].role} · ${blocks[i].content.trim().split('\n').first}',
            trailing: GlazeSwitch(
              value: blocks[i].enabled,
              onChanged: (v) => _setBlock(i, blocks[i].copyWith(enabled: v)),
            ),
            onTap: () => _editBlock(context, i),
          ),
        MenuItem(
          icon: Icons.add,
          label: 'agents_add_block'.tr(),
          onTap: () {
            final block = PresetBlock(
              id: 'block_${DateTime.now().microsecondsSinceEpoch}',
              name: 'agents_block_new'.tr(),
              role: 'system',
              content: '',
            );
            _update(_agent.copyWith(blocks: [..._agent.blocks, block]));
            _editBlock(context, _agent.blocks.length - 1);
          },
        ),
      ],
    );
  }

  void _setBlock(int index, PresetBlock block) {
    final blocks = [..._agent.blocks];
    blocks[index] = block;
    _update(_agent.copyWith(blocks: blocks));
  }

  void _editBlock(BuildContext context, int index) {
    showAgentBlockEditor(
      context,
      block: _agent.blocks[index],
      canMoveUp: index > 0,
      canMoveDown: index < _agent.blocks.length - 1,
      onChanged: (block) => _setBlock(index, block),
      onDelete: () {
        final blocks = [..._agent.blocks]..removeAt(index);
        _update(_agent.copyWith(blocks: blocks));
      },
      onMove: (delta) {
        final blocks = [..._agent.blocks];
        final target = index + delta;
        if (target < 0 || target >= blocks.length) return;
        final moved = blocks.removeAt(index);
        blocks.insert(target, moved);
        _update(_agent.copyWith(blocks: blocks));
      },
    );
  }

  Widget _injectionGroup(BuildContext context) {
    final injection = _agent.injection;
    return MenuGroup(
      header: 'agents_section_injection'.tr(),
      description: 'agents_macro_hint'.tr(args: ['{{agent::${_agent.id}}}']),
      items: [
        MenuSelectorItem(
          label: 'agents_section_injection'.tr(),
          currentValue: agentPlacementLabel(injection.placement),
          onTap: () => showGlazePickerSheet(
            context,
            title: 'agents_section_injection'.tr(),
            items: [
              for (final placement in AgentPlacement.all)
                GlazePickerItem(
                  label: agentPlacementLabel(placement),
                  isActive: placement == injection.placement,
                  value: placement,
                ),
            ],
            onSelect: (v) => _update(
              _agent.copyWith(
                injection: _agent.injection.copyWith(placement: v as String),
              ),
            ),
          ),
        ),
        if (injection.placement == AgentPlacement.depth)
          _numberField(
            'agents_depth'.tr(),
            _depth,
            (v) => _update(
              _agent.copyWith(
                injection: _agent.injection.copyWith(
                  depth: (_int(v) ?? 1).clamp(0, 1000),
                ),
              ),
            ),
          ),
        if (injection.placement != AgentPlacement.macroOnly)
          MenuSelectorItem(
            label: 'agents_role'.tr(),
            currentValue: injection.role,
            onTap: () => showGlazePickerSheet(
              context,
              title: 'agents_role'.tr(),
              items: [
                for (final role in const ['system', 'user', 'assistant'])
                  GlazePickerItem(
                    label: role,
                    isActive: role == injection.role,
                    value: role,
                  ),
              ],
              onSelect: (v) => _update(
                _agent.copyWith(
                  injection: _agent.injection.copyWith(role: v as String),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _connectionGroup(BuildContext context) {
    final connection = _agent.connection;
    final helper = connection.mode == AgentConnectionMode.helper;
    return ApiSlotGroup(
      key: ValueKey('agent-connection-${_agent.id}'),
      header: 'agents_section_connection'.tr(),
      description: agentConnectionLabel(connection.mode),
      apiConfigId: helper ? '' : connection.apiConfigId,
      showSlotRows: !helper,
      onApiConfigChanged: (id) => _update(
        _agent.copyWith(
          connection: connection.copyWith(
            mode: id.isEmpty
                ? AgentConnectionMode.chat
                : AgentConnectionMode.config,
            apiConfigId: id,
            model: '',
          ),
        ),
      ),
      modelRows: [
        ApiSlotModelRow(
          value: connection.model,
          description: 'agents_model_hint'.tr(),
          onChanged: (v) => _update(
            _agent.copyWith(connection: connection.copyWith(model: v)),
          ),
        ),
      ],
      leadingItems: [
        MenuSwitchItem(
          label: 'agents_connection_helper'.tr(),
          description: 'agents_helper_desc'.tr(),
          value: helper,
          onChanged: (v) => _update(
            _agent.copyWith(
              connection: connection.copyWith(
                mode: v
                    ? AgentConnectionMode.helper
                    : (connection.apiConfigId.isEmpty
                          ? AgentConnectionMode.chat
                          : AgentConnectionMode.config),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _pickPhase(BuildContext context) {
    showGlazePickerSheet(
      context,
      title: 'agents_field_phase'.tr(),
      items: [
        for (final phase in AgentPhase.all)
          GlazePickerItem(
            label: agentPhaseLabel(phase),
            hint: agentPhaseHint(phase),
            icon: agentPhaseIcon(phase),
            isActive: phase == _agent.phase,
            value: phase,
          ),
      ],
      onSelect: (v) {
        final phase = v as String;
        final allowed = AgentResultType.allowedFor(phase);
        _update(
          _agent.copyWith(
            phase: phase,
            resultType: allowed.contains(_agent.resultType)
                ? _agent.resultType
                : allowed.first,
            seesOutputsOf: phase == AgentPhase.preGeneration
                ? _agent.seesOutputsOf
                : const [],
          ),
        );
      },
    );
  }

  void _pickResult(BuildContext context) {
    // A user agent after the reply can only borrow the Post Clean engine.
    final allowed = _agent.phase == AgentPhase.postProcessing
        ? const [AgentResultType.textRewrite]
        : AgentResultType.allowedFor(_agent.phase);
    showGlazePickerSheet(
      context,
      title: 'agents_field_result'.tr(),
      items: [
        for (final type in allowed)
          GlazePickerItem(
            label: agentResultLabel(type),
            isActive: type == _agent.resultType,
            value: type,
          ),
      ],
      onSelect: (v) => _update(_agent.copyWith(resultType: v as String)),
    );
  }

  void _pickAgents(
    BuildContext context, {
    required String title,
    required List<AgentDefinition> candidates,
    required List<String> selected,
    required ValueChanged<List<String>> onChanged,
  }) {
    final picked = {...selected};
    GlazeBottomSheet.show<void>(
      context,
      title: title,
      child: StatefulBuilder(
        builder: (context, setSheetState) => MenuGroup(
          items: [
            for (final candidate in candidates)
              MenuSwitchItem(
                label: candidate.displayName,
                description: agentPhaseLabel(candidate.phase),
                value: picked.contains(candidate.id),
                onChanged: (v) {
                  setSheetState(() {
                    v ? picked.add(candidate.id) : picked.remove(candidate.id);
                  });
                  onChanged([
                    for (final c in candidates)
                      if (picked.contains(c.id)) c.id,
                  ]);
                },
              ),
          ],
        ),
      ),
    );
  }
}
