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

/// Editor for one block.
///
/// The editor used to branch six ways on the block's type, because the type
/// decided everything: whether there was a prompt, whether the result could be
/// injected, what the labels said. It branches on two questions now — where
/// the content comes from, and where it goes — and both are settings the
/// reader can change without turning the block into a different kind of thing.
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
  late TextEditingController _staticContentController;
  late TextEditingController _scriptController;
  late TextEditingController _panelMinHeightController;
  late TextEditingController _injectLastNController;
  late TextEditingController _contextMessageCountController;
  late TextEditingController _previousBlocksCountController;
  late BlockType _type;
  late BlockRender _render;
  late bool _inject;
  late int _injectLastN;
  late bool _dependsOnPrevious;
  late int _contextMessageCount;
  late int _previousBlocksCount;
  late bool _streamToPanel;

  /// Content written on the block instead of asked of the model.
  late bool _useStaticSource;
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
    _promptController = TextEditingController(text: b.prompt);
    _apiConfigId = b.apiConfigId;
    _model = b.model;
    _contextSystemPromptController = TextEditingController(
      text: b.contextSystemPrompt,
    );
    _injectPrefixController = TextEditingController(text: b.injectPrefix);
    _staticContentController = TextEditingController(text: b.staticContent);
    _scriptController = TextEditingController(text: b.script);
    _panelMinHeightController = TextEditingController(
      text: b.panelMinHeight.toString(),
    );
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
    _render = b.render;
    _inject = b.inject;
    _injectLastN = b.injectLastN;
    _dependsOnPrevious = b.dependsOnPrevious;
    _contextMessageCount = b.contextMessageCount;
    _previousBlocksCount = b.previousBlocksCount;
    _streamToPanel = b.streamToPanel;
    _manualOnly = b.manualOnly;
    _contextPolicy = b.contextPolicy;
    // An empty prompt next to content the block carries is what "written here"
    // means at runtime, so the switch reads the same thing the handler does.
    _useStaticSource =
        b.prompt.trim().isEmpty &&
        (b.staticContent.trim().isNotEmpty || b.script.trim().isNotEmpty);

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
    final isGenerated = _type == BlockType.generated;
    final isScript = _type == BlockType.script;
    return widget.block.copyWith(
      name: _nameController.text.trim(),
      type: _type,
      trigger: _resolvedTrigger,
      template: isGenerated && _usesLlm ? _templateController.text : '',
      prompt: _usesLlm ? _promptController.text : '',
      staticContent: isGenerated ? _staticContentController.text : '',
      script: isScript ? _scriptController.text : '',
      render: isGenerated ? _render : BlockRender.card,
      panelMinHeight:
          int.tryParse(_panelMinHeightController.text.trim()) ??
          widget.block.panelMinHeight,
      inject: isGenerated ? _inject : false,
      injectLastN: isGenerated ? _injectLastN : 0,
      injectPrefix: isGenerated ? _injectPrefixController.text : '',
      dependsOnPrevious: _dependsOnPrevious,
      apiConfigId: _usesLlm ? _apiConfigId : '',
      model: _usesLlm ? _model : '',
      contextMessageCount: _usesLlm ? _contextMessageCount : 0,
      previousBlocksCount: _usesLlm ? _previousBlocksCount : 0,
      contextSystemPrompt: _usesLlm ? _contextSystemPromptController.text : '',
      contextPolicy: _contextPolicy,
      streamToPanel: _usesLlm ? _streamToPanel : false,
      manualOnly: _manualOnly,
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
      if (type == BlockType.script && _contextMessageCount == 0) {
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
    _staticContentController.dispose();
    _scriptController.dispose();
    _panelMinHeightController.dispose();
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
                if (_type == BlockType.script)
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
            ..._sourceItems(),
            ..._outputItems(),
            ..._contextItems(),
            if (_usesLlm)
              ApiSlotGroup(
                header: 'block_api_section_label'.tr(),
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
            if (_type == BlockType.generated)
              const _HelpText('block_generated_help'),
            if (_type == BlockType.generated && _render == BlockRender.panel)
              const _HelpText('block_render_panel_help'),
            if (_type == BlockType.script) const _HelpText('block_script_help'),
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

  /// Where the block's content comes from: the model, or written here.
  ///
  /// This is one question for every runnable block now. It used to be asked
  /// only of interactive panels, which is why a JS block's stored script and a
  /// static card were not editable at all.
  List<Widget> _sourceItems() {
    if (!_producesContent) return const [];
    final isScript = _type == BlockType.script;
    return [
      MenuGroup(
        header: 'block_sec_source'.tr(),
        items: [
          MenuSelectorItem(
            label: 'block_source_label'.tr(),
            currentValue: _useStaticSource
                ? 'block_source_static'.tr()
                : 'block_source_llm'.tr(),
            onTap: _pickSource,
          ),
          if (_useStaticSource)
            MenuFieldItem(
              label: isScript
                  ? 'block_script_label'.tr()
                  : 'block_static_content_label'.tr(),
              helper: isScript
                  ? 'block_script_helper'.tr()
                  : 'block_static_content_helper'.tr(),
              controller: isScript
                  ? _scriptController
                  : _staticContentController,
              maxLines: 18,
            )
          else ...[
            MenuFieldItem(
              label: isScript
                  ? 'block_prompt_label_js'.tr()
                  : 'block_prompt_label_default'.tr(),
              placeholder: isScript
                  ? 'block_prompt_hint_js'.tr()
                  : 'block_prompt_hint_default'.tr(),
              helper: isScript
                  ? 'block_prompt_helper_js'.tr()
                  : 'block_prompt_helper_default'.tr(),
              controller: _promptController,
              maxLines: isScript ? 12 : 6,
            ),
            if (!isScript)
              MenuFieldItem(
                label: 'block_template_label'.tr(),
                placeholder: 'block_template_hint'.tr(),
                helper: 'block_template_helper'.tr(),
                controller: _templateController,
                maxLines: 5,
              ),
          ],
        ],
      ),
    ];
  }

  Future<void> _pickSource() async {
    await GlazeBottomSheet.show<void>(
      context,
      title: 'block_source_label'.tr(),
      items: [
        for (final static in const [false, true])
          BottomSheetItem(
            label: static
                ? 'block_source_static'.tr()
                : 'block_source_llm'.tr(),
            icon: _useStaticSource == static
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              setState(() => _useStaticSource = static);
            },
          ),
      ],
    );
  }

  /// What happens to the block's result: where it is shown, whether it goes
  /// back into the prompt, whether it streams.
  List<Widget> _outputItems() {
    final items = <Widget>[
      if (_type == BlockType.generated) ...[
        MenuSelectorItem(
          label: 'block_render_label'.tr(),
          currentValue: _renderLabel(_render),
          description: 'block_render_desc'.tr(),
          onTap: _pickRender,
        ),
        if (_render == BlockRender.panel)
          MenuFieldItem(
            label: 'block_min_height_label'.tr(),
            helper: 'block_min_height_helper'.tr(),
            controller: _panelMinHeightController,
            keyboardType: TextInputType.number,
          ),
      ],
      if (_producesContent)
        MenuSwitchItem(
          label: 'block_depends_on_prev'.tr(),
          description: 'block_depends_sub_default'.tr(),
          value: _dependsOnPrevious,
          onChanged: (v) => setState(() => _dependsOnPrevious = v),
        ),
      if (_type == BlockType.generated) ...[
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
          label: 'block_stream_title'.tr(),
          description: 'block_stream_sub_default'.tr(),
          value: _streamToPanel,
          onChanged: (v) => setState(() => _streamToPanel = v),
        ),
    ];
    if (items.isEmpty) return const [];
    return [MenuGroup(header: 'block_sec_output'.tr(), items: items)];
  }

  String _renderLabel(BlockRender render) => switch (render) {
    BlockRender.card => 'block_render_card'.tr(),
    BlockRender.panel => 'block_render_panel'.tr(),
  };

  Future<void> _pickRender() async {
    await GlazeBottomSheet.show<void>(
      context,
      title: 'block_render_label'.tr(),
      items: [
        for (final option in BlockRender.values)
          BottomSheetItem(
            label: _renderLabel(option),
            icon: _render == option
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              setState(() => _render = option);
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
            helper: 'block_context_count_helper_full'.tr(),
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
          MenuFieldItem(
            label: 'block_previous_blocks_label'.tr(),
            helper: 'block_previous_blocks_helper'.tr(),
            controller: _previousBlocksCountController,
            keyboardType: TextInputType.number,
            onChanged: (v) =>
                _previousBlocksCount = int.tryParse(v) ?? _previousBlocksCount,
          ),
        ],
      ),
      ?policy.detailsGroup(),
    ];
  }

  /// The single-valued trigger our pipeline selects on, derived from the
  /// switches the editor actually shows.
  BlockTrigger get _resolvedTrigger {
    if (_periodicTimer && _type == BlockType.script) {
      return BlockTrigger.periodic;
    }
    return _triggerOnUser && !_triggerOnChar
        ? BlockTrigger.afterUser
        : BlockTrigger.afterAssistant;
  }

  /// Whether this type produces something for the reader at all. Rewrite and
  /// accumulation blocks are editable but have no runtime yet.
  bool get _producesContent =>
      _type == BlockType.generated || _type == BlockType.script;

  bool get _usesLlm => _producesContent && !_useStaticSource;
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
