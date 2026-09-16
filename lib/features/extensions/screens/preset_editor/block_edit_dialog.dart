import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../../shared/widgets/menu_group.dart';
import '../../../../shared/widgets/sheet_view.dart';
import '../../models/block_config.dart';
import '../../models/block_injection.dart';
import '../../models/block_modes.dart';
import '../../models/connection_profiles.dart';
import '../../models/extension_context_policy.dart';
import '../../widgets/extension_context_policy_editor.dart';
import 'widgets/api_config_selector.dart';
import 'widgets/block_type_picker.dart';
import 'widgets/model_field.dart';
import 'widgets/section_label.dart';
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
  late TextEditingController _apiConfigController;
  late TextEditingController _modelController;
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
  bool _fetchingModels = false;

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
    _apiConfigController = TextEditingController(text: b.apiConfigId);
    _modelController = TextEditingController(text: b.model);
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
      apiConfigId: usesLlm ? _apiConfigController.text.trim() : '',
      model: usesLlm ? _modelController.text.trim() : '',
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
      period: int.tryParse(_periodController.text.trim()) ?? widget.block.period,
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
      title: 'Not recommended with Studio Canon',
      bigInfo: const BottomSheetBigInfo(
        icon: Icons.warning_amber_rounded,
        description:
            'User InfBlocks can conflict with Studio Canon State and may '
            'cause duplicated, stale, or lower-authority facts to enter the '
            'prompt. Studio Canon already tracks scene, entity, relationship, '
            'arc, and world state.\n\n'
            'Recommended: keep user InfBlocks visible in panels only.\n\n'
            'Allowed alternatives: image generation services, JS runner '
            'tools, and manual panel workflows.\n\n'
            'If you continue, user InfBlocks will be injected only as '
            'low-authority hints. They must never outrank Studio Canon State.',
      ),
      items: [
        BottomSheetItem(
          label: 'Continue anyway',
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
    _apiConfigController.dispose();
    _modelController.dispose();
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
              apiPreset: _apiPreset,
              onGenerationOrderChanged: (v) =>
                  setState(() => _generationOrder = v),
              onExecutionOrderChanged: (v) =>
                  setState(() => _executionOrder = v),
              onRewriteModeChanged: (v) => setState(() => _rewriteMode = v),
              onScriptTypeChanged: (v) => setState(() => _scriptType = v),
              onApiPresetChanged: (v) => setState(() => _apiPreset = v),
            ),
            // Not yet rebuilt on the UI kit; keeps the gutter the body used
            // to supply for everyone.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
            if (_type == BlockType.infoblock ||
                _type == BlockType.imageGen ||
                _type == BlockType.jsRunner) ...[
              const SizedBox(height: 8),
              _DependsOnPreviousSwitch(
                type: _type,
                value: _dependsOnPrevious,
                onChanged: (v) => setState(() => _dependsOnPrevious = v),
              ),
            ],
            if (_type == BlockType.infoblock) ...[
              const SizedBox(height: 16),
              _InfoblockInjectFields(
                inject: _inject,
                injectPrefixController: _injectPrefixController,
                injectLastNController: _injectLastNController,
                onInjectChanged: (v) {
                  _onInjectChanged(v);
                },
                onLastNChanged: (v) => _injectLastN = v,
              ),
            ],
            if (_usesStandardLlmFields) ...[
              const SizedBox(height: 16),
              _PromptFields(type: _type, controller: _promptController),
            ],
            if (_type == BlockType.infoblock) ...[
              const SizedBox(height: 8),
              _TemplateField(controller: _templateController),
            ],
            if (_usesLlm) ...[
              const SizedBox(height: 16),
              SectionLabel('block_sec_context'.tr()),
              ExtensionContextPolicyEditor(
                policy: _contextPolicy,
                onChanged: (policy) => setState(() => _contextPolicy = policy),
              ),
            ],
            if (_usesStandardLlmFields) ...[
              const SizedBox(height: 16),
              _LlmOptionsFields(
                type: _type,
                apiConfigController: _apiConfigController,
                modelController: _modelController,
                contextSystemPromptController: _contextSystemPromptController,
                contextMessageCountController: _contextMessageCountController,
                previousBlocksCountController: _previousBlocksCountController,
                contextMessageCount: _contextMessageCount,
                previousBlocksCount: _previousBlocksCount,
                streamToPanel: _streamToPanel,
                fetchingModels: _fetchingModels,
                onContextMessageCountChanged: (v) => _contextMessageCount = v,
                onPreviousBlocksCountChanged: (v) => _previousBlocksCount = v,
                onStreamToPanelChanged: (v) =>
                    setState(() => _streamToPanel = v),
                onApiChanged: (id) {
                  setState(() {
                    _apiConfigController.text = id ?? '';
                    _modelController.clear();
                  });
                },
                onFetchStart: () => setState(() => _fetchingModels = true),
                onFetchEnd: () => setState(() => _fetchingModels = false),
              ),
            ],
            if (_type == BlockType.imageGen) const _ImageGenHelpText(),
            if (_type == BlockType.jsRunner) const _JsRunnerHelpText(),
            if (_type == BlockType.interactive) ...[
              const SizedBox(height: 16),
              _InteractiveFields(
                useStaticHtml: _useStaticHtml,
                staticHtmlController: _staticHtmlController,
                promptController: _promptController,
                minHeightController: _minHeightController,
                dependsOnPrevious: _dependsOnPrevious,
                contextMessageCount: _contextMessageCount,
                contextMessageCountController: _contextMessageCountController,
                contextSystemPromptController: _contextSystemPromptController,
                apiConfigController: _apiConfigController,
                modelController: _modelController,
                fetchingModels: _fetchingModels,
                streamToPanel: _streamToPanel,
                onUseStaticHtmlChanged: (v) =>
                    setState(() => _useStaticHtml = v),
                onMinHeightChanged: (_) {},
                onDependsOnPreviousChanged: (v) =>
                    setState(() => _dependsOnPrevious = v),
                onContextMessageCountChanged: (v) => _contextMessageCount = v,
                onApiChanged: (id) {
                  setState(() {
                    _apiConfigController.text = id ?? '';
                    _modelController.clear();
                  });
                },
                onFetchStart: () => setState(() => _fetchingModels = true),
                onFetchEnd: () => setState(() => _fetchingModels = false),
                onStreamToPanelChanged: (v) =>
                    setState(() => _streamToPanel = v),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: Text('btn_save'.tr())),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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

class _DependsOnPreviousSwitch extends StatelessWidget {
  const _DependsOnPreviousSwitch({
    required this.type,
    required this.value,
    required this.onChanged,
  });

  final BlockType type;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text('block_depends_on_prev'.tr()),
      subtitle: Text(
        type == BlockType.imageGen
            ? 'block_depends_sub_image'.tr()
            : type == BlockType.jsRunner
            ? 'block_depends_sub_js'.tr()
            : 'block_depends_sub_default'.tr(),
      ),
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
    );
  }
}

class _InfoblockInjectFields extends StatelessWidget {
  const _InfoblockInjectFields({
    required this.inject,
    required this.injectPrefixController,
    required this.injectLastNController,
    required this.onInjectChanged,
    required this.onLastNChanged,
  });

  final bool inject;
  final TextEditingController injectPrefixController;
  final TextEditingController injectLastNController;
  final ValueChanged<bool> onInjectChanged;
  final ValueChanged<int> onLastNChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          title: Text('block_inject_title'.tr()),
          subtitle: Text('block_inject_desc'.tr()),
          value: inject,
          onChanged: onInjectChanged,
          contentPadding: EdgeInsets.zero,
        ),
        if (inject) ...[
          const SizedBox(height: 8),
          TextField(
            controller: injectLastNController,
            decoration: InputDecoration(
              labelText: 'block_inject_last_n_label'.tr(),
              helperText: 'block_inject_last_n_helper'.tr(),
            ),
            keyboardType: TextInputType.number,
            onChanged: (v) => onLastNChanged(int.tryParse(v) ?? 0),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: injectPrefixController,
            decoration: InputDecoration(
              labelText: 'block_inject_prefix_label'.tr(),
              helperText: 'block_inject_prefix_helper'.tr(),
              alignLabelWithHint: true,
            ),
            minLines: 1,
            maxLines: 4,
          ),
        ],
      ],
    );
  }
}

class _PromptFields extends StatelessWidget {
  const _PromptFields({required this.type, required this.controller});

  final BlockType type;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SectionLabel(switch (type) {
          BlockType.imageGen => 'block_prompt_image_agent'.tr(),
          BlockType.jsRunner => 'block_prompt_js_agent'.tr(),
          _ => 'block_prompt_and_format'.tr(),
        }),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: switch (type) {
              BlockType.imageGen => 'block_prompt_label_image'.tr(),
              BlockType.jsRunner => 'block_prompt_label_js'.tr(),
              _ => 'block_prompt_label_default'.tr(),
            },
            hintText: switch (type) {
              BlockType.imageGen => 'block_prompt_hint_image'.tr(),
              BlockType.jsRunner => 'block_prompt_hint_js'.tr(),
              _ => 'block_prompt_hint_default'.tr(),
            },
            helperText: switch (type) {
              BlockType.imageGen => 'block_prompt_helper_image'.tr(),
              BlockType.jsRunner => 'block_prompt_helper_js'.tr(),
              _ => 'block_prompt_helper_default'.tr(),
            },
            alignLabelWithHint: true,
          ),
          maxLines: type == BlockType.infoblock ? 4 : 12,
          minLines: type == BlockType.infoblock ? 2 : 6,
        ),
      ],
    );
  }
}

class _TemplateField extends StatelessWidget {
  const _TemplateField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: 'block_template_label'.tr(),
        hintText: 'block_template_hint'.tr(),
        helperText: 'block_template_helper'.tr(),
        alignLabelWithHint: true,
      ),
      maxLines: 5,
      minLines: 2,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    );
  }
}

class _LlmOptionsFields extends StatelessWidget {
  const _LlmOptionsFields({
    required this.type,
    required this.apiConfigController,
    required this.modelController,
    required this.contextSystemPromptController,
    required this.contextMessageCountController,
    required this.previousBlocksCountController,
    required this.contextMessageCount,
    required this.previousBlocksCount,
    required this.streamToPanel,
    required this.fetchingModels,
    required this.onContextMessageCountChanged,
    required this.onPreviousBlocksCountChanged,
    required this.onStreamToPanelChanged,
    required this.onApiChanged,
    required this.onFetchStart,
    required this.onFetchEnd,
  });

  final BlockType type;
  final TextEditingController apiConfigController;
  final TextEditingController modelController;
  final TextEditingController contextSystemPromptController;
  final TextEditingController contextMessageCountController;
  final TextEditingController previousBlocksCountController;
  final int contextMessageCount;
  final int previousBlocksCount;
  final bool streamToPanel;
  final bool fetchingModels;
  final ValueChanged<int> onContextMessageCountChanged;
  final ValueChanged<int> onPreviousBlocksCountChanged;
  final ValueChanged<bool> onStreamToPanelChanged;
  final ValueChanged<String?> onApiChanged;
  final VoidCallback onFetchStart;
  final VoidCallback onFetchEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SectionLabel('block_chat_context_section'.tr()),
        _ContextMessageCountField(
          controller: contextMessageCountController,
          value: contextMessageCount,
          onChanged: onContextMessageCountChanged,
          fullHelper: true,
        ),
        const SizedBox(height: 8),
        _ContextSystemPromptField(controller: contextSystemPromptController),
        const SizedBox(height: 8),
        _PreviousBlocksCountField(
          controller: previousBlocksCountController,
          value: previousBlocksCount,
          onChanged: onPreviousBlocksCountChanged,
        ),
        const SizedBox(height: 16),
        SectionLabel(switch (type) {
          BlockType.imageGen => 'block_api_agent_label'.tr(),
          BlockType.jsRunner => 'block_api_agent_label'.tr(),
          _ => 'block_api_section_label'.tr(),
        }),
        ApiConfigSelector(
          selectedId: apiConfigController.text,
          onSelected: onApiChanged,
        ),
        const SizedBox(height: 8),
        ModelField(
          controller: modelController,
          apiConfigId: apiConfigController.text,
          fetching: fetchingModels,
          onFetchStart: onFetchStart,
          onFetchEnd: onFetchEnd,
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          title: Text('block_stream_title'.tr()),
          subtitle: Text(switch (type) {
            BlockType.imageGen => 'block_stream_sub_image'.tr(),
            BlockType.jsRunner => 'block_stream_sub_js'.tr(),
            _ => 'block_stream_sub_default'.tr(),
          }),
          value: streamToPanel,
          onChanged: onStreamToPanelChanged,
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }
}

class _InteractiveFields extends StatelessWidget {
  const _InteractiveFields({
    required this.useStaticHtml,
    required this.staticHtmlController,
    required this.promptController,
    required this.minHeightController,
    required this.dependsOnPrevious,
    required this.contextMessageCount,
    required this.contextMessageCountController,
    required this.contextSystemPromptController,
    required this.apiConfigController,
    required this.modelController,
    required this.fetchingModels,
    required this.streamToPanel,
    required this.onUseStaticHtmlChanged,
    required this.onMinHeightChanged,
    required this.onDependsOnPreviousChanged,
    required this.onContextMessageCountChanged,
    required this.onApiChanged,
    required this.onFetchStart,
    required this.onFetchEnd,
    required this.onStreamToPanelChanged,
  });

  final bool useStaticHtml;
  final TextEditingController staticHtmlController;
  final TextEditingController promptController;
  final TextEditingController minHeightController;
  final bool dependsOnPrevious;
  final int contextMessageCount;
  final TextEditingController contextMessageCountController;
  final TextEditingController contextSystemPromptController;
  final TextEditingController apiConfigController;
  final TextEditingController modelController;
  final bool fetchingModels;
  final bool streamToPanel;
  final ValueChanged<bool> onUseStaticHtmlChanged;
  final ValueChanged<int> onMinHeightChanged;
  final ValueChanged<bool> onDependsOnPreviousChanged;
  final ValueChanged<int> onContextMessageCountChanged;
  final ValueChanged<String?> onApiChanged;
  final VoidCallback onFetchStart;
  final VoidCallback onFetchEnd;
  final ValueChanged<bool> onStreamToPanelChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SectionLabel('block_html_source_label'.tr()),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
              value: false,
              label: Text('block_html_llm'.tr()),
              icon: const Icon(Icons.auto_awesome),
            ),
            ButtonSegment(
              value: true,
              label: Text('block_html_static'.tr()),
              icon: const Icon(Icons.code),
            ),
          ],
          selected: {useStaticHtml},
          onSelectionChanged: (s) => onUseStaticHtmlChanged(s.first),
          style: ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 8),
        if (useStaticHtml)
          TextField(
            controller: staticHtmlController,
            decoration: InputDecoration(
              labelText: 'block_static_html_label'.tr(),
              helperText: 'block_static_html_helper'.tr(),
              alignLabelWithHint: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            minLines: 6,
            maxLines: 18,
          )
        else
          TextField(
            controller: promptController,
            decoration: InputDecoration(
              labelText: 'block_llm_html_label'.tr(),
              helperText: 'block_llm_html_helper'.tr(),
              alignLabelWithHint: true,
            ),
            minLines: 4,
            maxLines: 12,
          ),
        const SizedBox(height: 8),
        TextField(
          controller: minHeightController,
          decoration: InputDecoration(
            labelText: 'block_min_height_label'.tr(),
            helperText: 'block_min_height_helper'.tr(),
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) => onMinHeightChanged(int.tryParse(v) ?? 120),
        ),
        if (!useStaticHtml) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            title: Text('block_interactive_depends'.tr()),
            subtitle: Text('block_interactive_depends_sub'.tr()),
            value: dependsOnPrevious,
            onChanged: onDependsOnPreviousChanged,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 16),
          SectionLabel('block_chat_context_section'.tr()),
          _ContextMessageCountField(
            controller: contextMessageCountController,
            value: contextMessageCount,
            onChanged: onContextMessageCountChanged,
            fullHelper: false,
          ),
          const SizedBox(height: 8),
          _ContextSystemPromptField(controller: contextSystemPromptController),
          const SizedBox(height: 16),
          SectionLabel('block_api_section_label'.tr()),
          ApiConfigSelector(
            selectedId: apiConfigController.text,
            onSelected: onApiChanged,
          ),
          const SizedBox(height: 8),
          ModelField(
            controller: modelController,
            apiConfigId: apiConfigController.text,
            fetching: fetchingModels,
            onFetchStart: onFetchStart,
            onFetchEnd: onFetchEnd,
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            title: Text('block_interactive_stream_title'.tr()),
            subtitle: Text('block_interactive_stream_sub'.tr()),
            value: streamToPanel,
            onChanged: onStreamToPanelChanged,
            contentPadding: EdgeInsets.zero,
          ),
        ],
        const _InteractiveHelpText(),
      ],
    );
  }
}

class _ContextMessageCountField extends StatelessWidget {
  const _ContextMessageCountField({
    required this.controller,
    required this.value,
    required this.onChanged,
    required this.fullHelper,
  });

  final TextEditingController controller;
  final int value;
  final ValueChanged<int> onChanged;
  final bool fullHelper;

  @override
  Widget build(BuildContext context) {
    return TextField(
      decoration: InputDecoration(
        labelText: 'block_context_count_label'.tr(),
        helperText: fullHelper
            ? 'block_context_count_helper_full'.tr()
            : 'block_context_count_helper'.tr(),
      ),
      keyboardType: const TextInputType.numberWithOptions(signed: true),
      controller: controller,
      onChanged: (v) => onChanged(int.tryParse(v) ?? value),
    );
  }
}

class _PreviousBlocksCountField extends StatelessWidget {
  const _PreviousBlocksCountField({
    required this.controller,
    required this.value,
    required this.onChanged,
  });

  final TextEditingController controller;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      decoration: InputDecoration(
        labelText: 'block_previous_blocks_label'.tr(),
        helperText: 'block_previous_blocks_helper'.tr(),
      ),
      keyboardType: TextInputType.number,
      controller: controller,
      onChanged: (v) => onChanged(int.tryParse(v) ?? value),
    );
  }
}

class _ContextSystemPromptField extends StatelessWidget {
  const _ContextSystemPromptField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: 'block_context_prompt_label'.tr(),
        hintText: 'block_context_prompt_hint'.tr(),
        helperText: 'block_context_prompt_helper'.tr(),
        alignLabelWithHint: true,
      ),
      maxLines: 5,
      minLines: 2,
    );
  }
}

class _ImageGenHelpText extends StatelessWidget {
  const _ImageGenHelpText();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        'block_image_gen_help'.tr(),
        style: const TextStyle(fontSize: 12, height: 1.4),
      ),
    );
  }
}

class _JsRunnerHelpText extends StatelessWidget {
  const _JsRunnerHelpText();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        'block_js_runner_help'.tr(),
        style: const TextStyle(fontSize: 12, height: 1.4),
      ),
    );
  }
}

class _InteractiveHelpText extends StatelessWidget {
  const _InteractiveHelpText();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        'block_interactive_help'.tr(),
        style: const TextStyle(fontSize: 12, height: 1.4),
      ),
    );
  }
}
