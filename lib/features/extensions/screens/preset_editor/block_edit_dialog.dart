import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../../shared/widgets/glaze_scaffold.dart';
import '../../../../shared/widgets/menu_group.dart';
import '../../../../shared/widgets/sheet_view.dart';
import '../../../settings/widgets/api_slot_group.dart';
import '../../models/block_config.dart';
import '../../models/block_injection.dart';
import '../../models/block_modes.dart';
import '../../models/connection_profiles.dart';
import '../../models/extension_context_policy.dart';
import '../../widgets/extension_context_policy_editor.dart';
import 'widgets/block_type_picker.dart';
import 'sections/upstream_block_sections.dart';

class BlockEditDialog extends ConsumerStatefulWidget {
  const BlockEditDialog({required this.block, required this.onSave, super.key});

  final BlockConfig block;
  final void Function(BlockConfig) onSave;

  @override
  ConsumerState<BlockEditDialog> createState() => _BlockEditDialogState();
}

class _BlockEditDialogState extends ConsumerState<BlockEditDialog> {
  late TextEditingController _nameController;
  late TextEditingController _templateController;
  late TextEditingController _promptController;
  late TextEditingController _contextSystemPromptController;
  late TextEditingController _injectPrefixController;
  late TextEditingController _staticHtmlController;
  late TextEditingController _minHeightController;
  late TextEditingController _injectLastNController;
  late TextEditingController _contextMessageCountController;
  late TextEditingController _previousBlocksCountController;
  late BlockType _type;
  late bool _inject;
  late int _injectLastN;
  late bool _dependsOnPrevious;
  late int _contextMessageCount;
  late int _previousBlocksCount;
  late bool _streamToPanel;
  late bool _useStaticHtml;
  late bool _manualOnly;
  late ExtensionContextPolicy _contextPolicy;

  /// The connection and model this block overrides to. Empty means it follows
  /// the preset's own connection.
  late String _apiConfigId;
  late String _model;

  // Settings carried over from the original ExtBlocks extension.
  late TextEditingController _periodController;
  late TextEditingController _keywordController;
  late TextEditingController _injectionDepthController;
  late TextEditingController _updaterNameController;
  late bool _triggerOnUser;
  late bool _triggerOnChar;
  late bool _triggerOnSwipe;
  late bool _generationPause;
  late bool _keywordIsRegex;
  late bool _hideDisplay;
  late bool _background;
  late bool _applyRegex;
  late InjectionRole _injectionRole;
  late InjectionPosition _injectionPosition;
  late BlockRunOrder _generationOrder;
  late BlockRunOrder _executionOrder;
  late RewriteMode _rewriteMode;
  late ScriptType _scriptType;

  /// Not editable here: a Glaze preset runs on one connection, so big /
  /// medium / small all resolve to it. Carried through save so a block
  /// imported from the original extension exports unchanged.
  late ConnectionProfile _apiPreset;
  late bool _periodicTimer;

  @override
  void initState() {
    super.initState();
    final b = widget.block;
    _nameController = TextEditingController(text: b.name);
    _templateController = TextEditingController(text: b.template);
    final promptText =
        b.type == BlockType.imageGen &&
            b.prompt.isEmpty &&
            b.imagePromptInstruction.isNotEmpty
        ? b.imagePromptInstruction
        : b.prompt;
    _promptController = TextEditingController(text: promptText);
    _apiConfigId = b.apiConfigId;
    _model = b.model;
    _contextSystemPromptController = TextEditingController(
      text: b.contextSystemPrompt,
    );
    _injectPrefixController = TextEditingController(text: b.injectPrefix);
    _staticHtmlController = TextEditingController(text: b.script);
    _minHeightController = TextEditingController(text: '120');
    _injectLastNController = TextEditingController(
      text: b.injectLastN.toString(),
    );
    _contextMessageCountController = TextEditingController(
      text: b.contextMessageCount.toString(),
    );
    _previousBlocksCountController = TextEditingController(
      text: b.previousBlocksCount.toString(),
    );
    _type = b.type;
    _inject = b.inject;
    _injectLastN = b.injectLastN;
    _dependsOnPrevious = b.dependsOnPrevious;
    _contextMessageCount = b.contextMessageCount;
    _previousBlocksCount = b.previousBlocksCount;
    _streamToPanel = b.streamToPanel;
    _manualOnly = b.manualOnly;
    _contextPolicy = b.contextPolicy;
    _useStaticHtml =
        b.type == BlockType.interactive && b.script.trim().isNotEmpty;

    _periodController = TextEditingController(text: b.period.toString());
    _keywordController = TextEditingController(text: b.keyword);
    _injectionDepthController = TextEditingController(
      text: b.injectionDepth.toString(),
    );
    _updaterNameController = TextEditingController(text: b.updaterName);
    _triggerOnUser = b.triggerOnUser;
    _triggerOnChar = b.triggerOnChar;
    _triggerOnSwipe = b.triggerOnSwipe;
    _generationPause = b.generationPause;
    _keywordIsRegex = b.keywordIsRegex;
    _hideDisplay = b.hideDisplay;
    _background = b.background;
    _applyRegex = b.applyRegex;
    _injectionRole = b.injectionRole;
    _injectionPosition = b.injectionPosition;
    _generationOrder = b.generationOrder;
    _executionOrder = b.executionOrder;
    _rewriteMode = b.rewriteMode;
    _scriptType = b.scriptType;
    _apiPreset = b.apiPreset;
    _periodicTimer = b.trigger == BlockTrigger.periodic;
    // Blocks saved before the two-sided triggers existed only carry the single
    // enum. Our own derivation never produces afterUser for anything but a
    // user-only block, so reading it back is unambiguous.
    if (b.trigger == BlockTrigger.afterUser && !b.triggerOnUser) {
      _triggerOnUser = true;
      _triggerOnChar = false;
    }
  }

  void _save() {
    widget.onSave(_buildSavedBlock());
    Navigator.pop(context);
  }

  BlockConfig _buildSavedBlock() {
    final isImage = _type == BlockType.imageGen;
    final isJs = _type == BlockType.jsRunner;
    final isInfoblock = _type == BlockType.infoblock;
    final isInteractive = _type == BlockType.interactive;
    final usesLlm =
        isInfoblock || isImage || isJs || (isInteractive && !_useStaticHtml);
    return widget.block.copyWith(
      name: _nameController.text.trim(),
      type: _type,
      trigger: _resolvedTrigger,
      template: isInfoblock ? _templateController.text : '',
      prompt: usesLlm ? _promptController.text : '',
      inject: isInfoblock ? _inject : false,
      injectLastN: isInfoblock ? _injectLastN : 0,
      injectPrefix: isInfoblock ? _injectPrefixController.text : '',
      dependsOnPrevious: _dependsOnPrevious,
      apiConfigId: usesLlm ? _apiConfigId : '',
      model: usesLlm ? _model : '',
      imagePromptInstruction: '',
      imageGenEnabled: true,
      contextMessageCount: usesLlm ? _contextMessageCount : 0,
      previousBlocksCount: usesLlm ? _previousBlocksCount : 0,
      contextSystemPrompt: usesLlm ? _contextSystemPromptController.text : '',
      contextPolicy: _contextPolicy,
      streamToPanel: usesLlm ? _streamToPanel : false,
      manualOnly: _manualOnly,
      script: isInteractive
          ? (_useStaticHtml ? _staticHtmlController.text : '')
          : (isJs ? widget.block.script : ''),
      triggerOnUser: _triggerOnUser,
      triggerOnChar: _triggerOnChar,
      triggerOnSwipe: _triggerOnSwipe,
      generationPause: _generationPause,
      // Never zero: the interval check divides by it.
      period:
          int.tryParse(_periodController.text.trim()) ?? widget.block.period,
      keyword: _keywordController.text,
      keywordIsRegex: _keywordIsRegex,
      hideDisplay: _hideDisplay,
      background: _background,
      applyRegex: _applyRegex,
      injectionRole: _injectionRole,
      injectionPosition: _injectionPosition,
      injectionDepth:
          int.tryParse(_injectionDepthController.text.trim()) ??
          widget.block.injectionDepth,
      generationOrder: _generationOrder,
      executionOrder: _executionOrder,
      rewriteMode: _rewriteMode,
      scriptType: _scriptType,
      apiPreset: _apiPreset,
      updaterName: _updaterNameController.text.trim(),
    );
  }

  void _onTypeChanged(BlockType type) {
    setState(() {
      _type = type;
      if (type == BlockType.imageGen) {
        _dependsOnPrevious = true;
        _inject = false;
      }
      if (type == BlockType.jsRunner && _contextMessageCount == 0) {
        _contextMessageCount = 10;
        _contextMessageCountController.text = '10';
      }
    });
  }

  Future<void> _onInjectChanged(bool value) async {
    if (!value) {
      setState(() => _inject = false);
      return;
    }

    final proceed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'block_inject_warn_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.warning_amber_rounded,
        description: 'block_inject_warn_body'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'block_inject_warn_continue'.tr(),
          centered: true,
          isDestructive: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'common_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (proceed != true) return;

    setState(() => _inject = true);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _templateController.dispose();
    _promptController.dispose();
    _contextSystemPromptController.dispose();
    _injectPrefixController.dispose();
    _staticHtmlController.dispose();
    _minHeightController.dispose();
    _injectLastNController.dispose();
    _contextMessageCountController.dispose();
    _previousBlocksCountController.dispose();
    _periodController.dispose();
    _keywordController.dispose();
    _injectionDepthController.dispose();
    _updaterNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: 'block_edit_title'.tr(),
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check, size: 22),
          tooltip: 'btn_save'.tr(),
          onPressed: _save,
        ),
      ],
      body: Material(
        type: MaterialType.transparency,
        child: ListView(
          children: [
            const SizedBox(height: 8),
            MenuGroup(
              header: 'block_sec_basics'.tr(),
              items: [
                MenuFieldItem(
                  label: 'block_edit_name_label'.tr(),
                  controller: _nameController,
                ),
                BlockTypePicker(selected: _type, onChanged: _onTypeChanged),
                if (_type == BlockType.accumulation)
                  MenuFieldItem(
                    label: 'block_updater_name'.tr(),
                    description: 'block_updater_name_desc'.tr(),
                    controller: _updaterNameController,
                  ),
                MenuSwitchItem(
                  label: 'block_manual_only_title'.tr(),
                  description: 'block_manual_only_sub'.tr(),
                  value: _manualOnly,
                  onChanged: (v) => setState(() => _manualOnly = v),
                ),
                if (_type == BlockType.jsRunner)
                  MenuSwitchItem(
                    label: 'block_trig_periodic'.tr(),
                    value: _periodicTimer,
                    onChanged: (v) => setState(() => _periodicTimer = v),
                  ),
              ],
            ),
            BlockTriggersGroup(
              type: _type,
              onUser: _triggerOnUser,
              onChar: _triggerOnChar,
              onSwipe: _triggerOnSwipe,
              generationPause: _generationPause,
              periodController: _periodController,
              keywordController: _keywordController,
              keywordIsRegex: _keywordIsRegex,
              onUserChanged: (v) => setState(() => _triggerOnUser = v),
              onCharChanged: (v) => setState(() => _triggerOnChar = v),
              onSwipeChanged: (v) => setState(() => _triggerOnSwipe = v),
              onGenerationPauseChanged: (v) =>
                  setState(() => _generationPause = v),
              onKeywordIsRegexChanged: (v) =>
                  setState(() => _keywordIsRegex = v),
            ),
            BlockStateGroup(
              hideDisplay: _hideDisplay,
              background: _background,
              applyRegex: _applyRegex,
              onHideDisplayChanged: (v) => setState(() => _hideDisplay = v),
              onBackgroundChanged: (v) => setState(() => _background = v),
              onApplyRegexChanged: (v) => setState(() => _applyRegex = v),
            ),
            // A rewrite block replaces the reply instead of being injected
            // alongside it, so placement settings would mean nothing for it.
            if (_type != BlockType.rewrite)
              BlockInjectionGroup(
                role: _injectionRole,
                position: _injectionPosition,
                depthController: _injectionDepthController,
                onRoleChanged: (v) => setState(() => _injectionRole = v),
                onPositionChanged: (v) =>
                    setState(() => _injectionPosition = v),
              ),
            BlockOrderGroup(
              type: _type,
              generationOrder: _generationOrder,
              executionOrder: _executionOrder,
              rewriteMode: _rewriteMode,
              scriptType: _scriptType,
              onGenerationOrderChanged: (v) =>
                  setState(() => _generationOrder = v),
              onExecutionOrderChanged: (v) =>
                  setState(() => _executionOrder = v),
              onRewriteModeChanged: (v) => setState(() => _rewriteMode = v),
              onScriptTypeChanged: (v) => setState(() => _scriptType = v),
            ),
            ..._outputItems(),
            ..._promptItems(),
            if (_type == BlockType.interactive) _interactiveGroup(),
            ..._contextItems(),
            if (_usesLlm)
              ApiSlotGroup(
                header: switch (_type) {
                  BlockType.imageGen ||
                  BlockType.jsRunner => 'block_api_agent_label'.tr(),
                  _ => 'block_api_section_label'.tr(),
                },
                apiConfigId: _apiConfigId,
                onApiConfigChanged: (id) => setState(() {
                  _apiConfigId = id;
                  // Endpoint and key come from the connection; a model picked
                  // against the previous one would not resolve.
                  _model = '';
                }),
                modelRows: [
                  ApiSlotModelRow(
                    value: _model,
                    onChanged: (value) => setState(() => _model = value),
                  ),
                ],
              ),
            if (_type == BlockType.imageGen)
              const _HelpText('block_image_gen_help'),
            if (_type == BlockType.jsRunner)
              const _HelpText('block_js_runner_help'),
            if (_type == BlockType.interactive)
              const _HelpText('block_interactive_help'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: GlazePillButton(
                  icon: Icons.check_rounded,
                  label: 'btn_save'.tr(),
                  onTap: _save,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What the block does with its result: whether it follows the block before
  /// it, whether it is injected into the prompt, and whether it streams.
  List<Widget> _outputItems() {
    final dependsLabelled =
        _type == BlockType.infoblock ||
        _type == BlockType.imageGen ||
        _type == BlockType.jsRunner;
    final items = <Widget>[
      if (dependsLabelled)
        MenuSwitchItem(
          label: 'block_depends_on_prev'.tr(),
          description: switch (_type) {
            BlockType.imageGen => 'block_depends_sub_image'.tr(),
            BlockType.jsRunner => 'block_depends_sub_js'.tr(),
            _ => 'block_depends_sub_default'.tr(),
          },
          value: _dependsOnPrevious,
          onChanged: (v) => setState(() => _dependsOnPrevious = v),
        ),
      if (_type == BlockType.interactive && !_useStaticHtml)
        MenuSwitchItem(
          label: 'block_interactive_depends'.tr(),
          description: 'block_interactive_depends_sub'.tr(),
          value: _dependsOnPrevious,
          onChanged: (v) => setState(() => _dependsOnPrevious = v),
        ),
      if (_type == BlockType.infoblock) ...[
        MenuSwitchItem(
          label: 'block_inject_title'.tr(),
          description: 'block_inject_desc'.tr(),
          value: _inject,
          onChanged: _onInjectChanged,
        ),
        if (_inject) ...[
          MenuFieldItem(
            label: 'block_inject_last_n_label'.tr(),
            helper: 'block_inject_last_n_helper'.tr(),
            controller: _injectLastNController,
            keyboardType: TextInputType.number,
            onChanged: (v) => _injectLastN = int.tryParse(v) ?? 0,
          ),
          MenuFieldItem(
            label: 'block_inject_prefix_label'.tr(),
            helper: 'block_inject_prefix_helper'.tr(),
            controller: _injectPrefixController,
            maxLines: 4,
          ),
        ],
      ],
      if (_usesLlm)
        MenuSwitchItem(
          label: _type == BlockType.interactive
              ? 'block_interactive_stream_title'.tr()
              : 'block_stream_title'.tr(),
          description: switch (_type) {
            BlockType.imageGen => 'block_stream_sub_image'.tr(),
            BlockType.jsRunner => 'block_stream_sub_js'.tr(),
            BlockType.interactive => 'block_interactive_stream_sub'.tr(),
            _ => 'block_stream_sub_default'.tr(),
          },
          value: _streamToPanel,
          onChanged: (v) => setState(() => _streamToPanel = v),
        ),
    ];
    if (items.isEmpty) return const [];
    return [MenuGroup(header: 'block_sec_output'.tr(), items: items)];
  }

  /// The instruction the block is generated from, and the layout its result is
  /// wrapped in. An interactive block keeps its own, in [_interactiveGroup].
  List<Widget> _promptItems() {
    if (!_usesStandardLlmFields) return const [];
    return [
      MenuGroup(
        header: switch (_type) {
          BlockType.imageGen => 'block_prompt_image_agent'.tr(),
          BlockType.jsRunner => 'block_prompt_js_agent'.tr(),
          _ => 'block_prompt_and_format'.tr(),
        },
        items: [
          MenuFieldItem(
            label: switch (_type) {
              BlockType.imageGen => 'block_prompt_label_image'.tr(),
              BlockType.jsRunner => 'block_prompt_label_js'.tr(),
              _ => 'block_prompt_label_default'.tr(),
            },
            placeholder: switch (_type) {
              BlockType.imageGen => 'block_prompt_hint_image'.tr(),
              BlockType.jsRunner => 'block_prompt_hint_js'.tr(),
              _ => 'block_prompt_hint_default'.tr(),
            },
            helper: switch (_type) {
              BlockType.imageGen => 'block_prompt_helper_image'.tr(),
              BlockType.jsRunner => 'block_prompt_helper_js'.tr(),
              _ => 'block_prompt_helper_default'.tr(),
            },
            controller: _promptController,
            maxLines: _type == BlockType.infoblock ? 4 : 12,
          ),
          if (_type == BlockType.infoblock)
            MenuFieldItem(
              label: 'block_template_label'.tr(),
              placeholder: 'block_template_hint'.tr(),
              helper: 'block_template_helper'.tr(),
              controller: _templateController,
              maxLines: 5,
            ),
        ],
      ),
    ];
  }

  /// Where an interactive block's HTML comes from: written by hand, or asked
  /// of the model.
  Widget _interactiveGroup() {
    return MenuGroup(
      header: 'block_html_source_label'.tr(),
      items: [
        MenuSelectorItem(
          label: 'block_html_source_label'.tr(),
          currentValue: _useStaticHtml
              ? 'block_html_static'.tr()
              : 'block_html_llm'.tr(),
          onTap: _pickHtmlSource,
        ),
        if (_useStaticHtml)
          MenuFieldItem(
            label: 'block_static_html_label'.tr(),
            helper: 'block_static_html_helper'.tr(),
            controller: _staticHtmlController,
            maxLines: 18,
          )
        else
          MenuFieldItem(
            label: 'block_llm_html_label'.tr(),
            helper: 'block_llm_html_helper'.tr(),
            controller: _promptController,
            maxLines: 12,
          ),
        MenuFieldItem(
          label: 'block_min_height_label'.tr(),
          helper: 'block_min_height_helper'.tr(),
          controller: _minHeightController,
          keyboardType: TextInputType.number,
        ),
      ],
    );
  }

  Future<void> _pickHtmlSource() async {
    await GlazeBottomSheet.show<void>(
      context,
      title: 'block_html_source_label'.tr(),
      items: [
        for (final static in const [false, true])
          BottomSheetItem(
            label: static ? 'block_html_static'.tr() : 'block_html_llm'.tr(),
            icon: _useStaticHtml == static
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              setState(() => _useStaticHtml = static);
            },
          ),
      ],
    );
  }

  /// What the block's own request is built from.
  List<Widget> _contextItems() {
    if (!_usesLlm) return const [];
    final policy = ExtensionContextPolicyEditor(
      policy: _contextPolicy,
      onChanged: (value) => setState(() => _contextPolicy = value),
    );
    return [
      MenuGroup(
        header: 'block_sec_context'.tr(),
        items: [
          policy.mainSwitch(),
          MenuFieldItem(
            label: 'block_context_count_label'.tr(),
            helper: _usesStandardLlmFields
                ? 'block_context_count_helper_full'.tr()
                : 'block_context_count_helper'.tr(),
            controller: _contextMessageCountController,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            onChanged: (v) =>
                _contextMessageCount = int.tryParse(v) ?? _contextMessageCount,
          ),
          MenuFieldItem(
            label: 'block_context_prompt_label'.tr(),
            placeholder: 'block_context_prompt_hint'.tr(),
            helper: 'block_context_prompt_helper'.tr(),
            controller: _contextSystemPromptController,
            maxLines: 5,
          ),
          if (_usesStandardLlmFields)
            MenuFieldItem(
              label: 'block_previous_blocks_label'.tr(),
              helper: 'block_previous_blocks_helper'.tr(),
              controller: _previousBlocksCountController,
              keyboardType: TextInputType.number,
              onChanged: (v) => _previousBlocksCount =
                  int.tryParse(v) ?? _previousBlocksCount,
            ),
        ],
      ),
      ?policy.detailsGroup(),
    ];
  }

  /// The single-valued trigger our pipeline selects on, derived from the
  /// switches the editor actually shows.
  BlockTrigger get _resolvedTrigger {
    if (_periodicTimer && _type == BlockType.jsRunner) {
      return BlockTrigger.periodic;
    }
    return _triggerOnUser && !_triggerOnChar
        ? BlockTrigger.afterUser
        : BlockTrigger.afterAssistant;
  }

  bool get _usesStandardLlmFields =>
      _type == BlockType.infoblock ||
      _type == BlockType.imageGen ||
      _type == BlockType.jsRunner;

  bool get _usesLlm =>
      _usesStandardLlmFields ||
      (_type == BlockType.interactive && !_useStaticHtml);
}

/// A muted paragraph under a type's settings, explaining what that type does.
class _HelpText extends StatelessWidget {
  const _HelpText(this.labelKey);

  final String labelKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 8),
      child: Text(
        labelKey.tr(),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.4,
        ),
      ),
    );
  }
}
