import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../../../shared/widgets/menu_group.dart';
import '../../../models/block_config.dart';
import '../../../models/block_injection.dart';
import '../../../models/block_modes.dart';
import '../../../models/connection_profiles.dart';

/// The block-editor groups that mirror the original ExtBlocks extension:
/// triggers, state flags, injection placement and run order.
///
/// Each group is a plain function of its values plus callbacks, so the editor
/// keeps owning the state and these stay cheap to reason about. Groups hide
/// themselves when the block type has no use for them — a rewrite block does
/// not inject, so it is not offered injection settings.

String injectionRoleLabel(InjectionRole role) => switch (role) {
  InjectionRole.system => 'block_role_system'.tr(),
  InjectionRole.user => 'block_role_user'.tr(),
  InjectionRole.assistant => 'block_role_assistant'.tr(),
};

String injectionPositionLabel(InjectionPosition position) => switch (position) {
  InjectionPosition.afterMainPrompt => 'block_pos_after_main'.tr(),
  InjectionPosition.inChat => 'block_pos_in_chat'.tr(),
  InjectionPosition.beforeMainPrompt => 'block_pos_before_main'.tr(),
};

String runOrderLabel(BlockRunOrder order) => switch (order) {
  BlockRunOrder.before => 'block_order_before'.tr(),
  BlockRunOrder.after => 'block_order_after'.tr(),
};

String rewriteModeLabel(RewriteMode mode) => switch (mode) {
  RewriteMode.full => 'block_rewrite_full'.tr(),
  RewriteMode.searchReplace => 'block_rewrite_diff'.tr(),
};

String scriptTypeLabel(ScriptType type) => switch (type) {
  ScriptType.stScript => 'block_script_type_st'.tr(),
  ScriptType.js => 'block_script_type_js'.tr(),
};

String apiPresetLabel(ConnectionProfile preset) => switch (preset) {
  ConnectionProfile.big => 'block_api_preset_big'.tr(),
  ConnectionProfile.medium => 'block_api_preset_medium'.tr(),
  ConnectionProfile.small => 'block_api_preset_small'.tr(),
};

/// Opens a picker for one of a fixed set of values.
void pickBlockOption<T>({
  required BuildContext context,
  required String title,
  required List<T> options,
  required T current,
  required String Function(T) labelOf,
  required ValueChanged<T> onPicked,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: title,
    items: [
      for (final option in options)
        BottomSheetItem(
          label: labelOf(option),
          icon: option == current
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
          onTap: () {
            Navigator.pop(context);
            onPicked(option);
          },
        ),
    ],
  );
}

/// When the block runs.
///
/// The two sides are independent switches rather than one choice, because the
/// original lets a block answer to both — and collapsing them would silently
/// drop half of an imported block's behavior.
class BlockTriggersGroup extends StatelessWidget {
  const BlockTriggersGroup({
    required this.type,
    required this.onUser,
    required this.onChar,
    required this.onSwipe,
    required this.generationPause,
    required this.periodController,
    required this.keywordController,
    required this.keywordIsRegex,
    required this.onUserChanged,
    required this.onCharChanged,
    required this.onSwipeChanged,
    required this.onGenerationPauseChanged,
    required this.onKeywordIsRegexChanged,
    super.key,
  });

  final BlockType type;
  final bool onUser;
  final bool onChar;
  final bool onSwipe;
  final bool generationPause;
  final TextEditingController periodController;
  final TextEditingController keywordController;
  final bool keywordIsRegex;
  final ValueChanged<bool> onUserChanged;
  final ValueChanged<bool> onCharChanged;
  final ValueChanged<bool> onSwipeChanged;
  final ValueChanged<bool> onGenerationPauseChanged;
  final ValueChanged<bool> onKeywordIsRegexChanged;

  @override
  Widget build(BuildContext context) {
    final isScript = type == BlockType.jsRunner;

    return MenuGroup(
      header: 'block_sec_triggers'.tr(),
      items: [
        MenuSwitchItem(
          label: 'block_trig_user'.tr(),
          value: onUser,
          onChanged: onUserChanged,
        ),
        MenuSwitchItem(
          label: 'block_trig_char'.tr(),
          value: onChar,
          onChanged: onCharChanged,
        ),
        if (isScript)
          MenuSwitchItem(
            label: 'block_trig_swipe'.tr(),
            value: onSwipe,
            onChanged: onSwipeChanged,
          ),
        MenuSwitchItem(
          label: 'block_trig_pause'.tr(),
          description: 'block_trig_pause_desc'.tr(),
          value: generationPause,
          onChanged: onGenerationPauseChanged,
        ),
        MenuFieldItem(
          label: 'block_period_label'.tr(),
          description: 'block_period_desc'.tr(),
          controller: periodController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        MenuFieldItem(
          label: 'block_keyword_label'.tr(),
          description: 'block_keyword_desc'.tr(),
          controller: keywordController,
        ),
        MenuSwitchItem(
          label: 'block_keyword_regex'.tr(),
          value: keywordIsRegex,
          onChanged: onKeywordIsRegexChanged,
        ),
      ],
    );
  }
}

/// Flags that change how a finished result is treated.
class BlockStateGroup extends StatelessWidget {
  const BlockStateGroup({
    required this.hideDisplay,
    required this.background,
    required this.applyRegex,
    required this.onHideDisplayChanged,
    required this.onBackgroundChanged,
    required this.onApplyRegexChanged,
    super.key,
  });

  final bool hideDisplay;
  final bool background;
  final bool applyRegex;
  final ValueChanged<bool> onHideDisplayChanged;
  final ValueChanged<bool> onBackgroundChanged;
  final ValueChanged<bool> onApplyRegexChanged;

  @override
  Widget build(BuildContext context) {
    return MenuGroup(
      header: 'block_sec_state'.tr(),
      items: [
        MenuSwitchItem(
          label: 'block_hide_display'.tr(),
          description: 'block_hide_display_desc'.tr(),
          value: hideDisplay,
          onChanged: onHideDisplayChanged,
        ),
        MenuSwitchItem(
          label: 'block_background'.tr(),
          description: 'block_background_desc'.tr(),
          value: background,
          onChanged: onBackgroundChanged,
        ),
        MenuSwitchItem(
          label: 'block_apply_regex'.tr(),
          description: 'block_apply_regex_desc'.tr(),
          value: applyRegex,
          onChanged: onApplyRegexChanged,
        ),
      ],
    );
  }
}

/// Where the stored result is placed in the next main request.
class BlockInjectionGroup extends StatelessWidget {
  const BlockInjectionGroup({
    required this.role,
    required this.position,
    required this.depthController,
    required this.onRoleChanged,
    required this.onPositionChanged,
    super.key,
  });

  final InjectionRole role;
  final InjectionPosition position;
  final TextEditingController depthController;
  final ValueChanged<InjectionRole> onRoleChanged;
  final ValueChanged<InjectionPosition> onPositionChanged;

  @override
  Widget build(BuildContext context) {
    return MenuGroup(
      header: 'block_sec_injection'.tr(),
      items: [
        MenuSelectorItem(
          label: 'block_injection_role'.tr(),
          currentValue: injectionRoleLabel(role),
          onTap: () => pickBlockOption<InjectionRole>(
            context: context,
            title: 'block_injection_role'.tr(),
            options: InjectionRole.values,
            current: role,
            labelOf: injectionRoleLabel,
            onPicked: onRoleChanged,
          ),
        ),
        MenuSelectorItem(
          label: 'block_injection_position'.tr(),
          currentValue: injectionPositionLabel(position),
          onTap: () => pickBlockOption<InjectionPosition>(
            context: context,
            title: 'block_injection_position'.tr(),
            options: InjectionPosition.values,
            current: position,
            labelOf: injectionPositionLabel,
            onPicked: onPositionChanged,
          ),
        ),
        // Only meaningful in the chat position, where there is a depth to
        // count; the other two positions sit against the main prompt.
        if (position == InjectionPosition.inChat)
          MenuFieldItem(
            label: 'block_injection_depth'.tr(),
            description: 'block_injection_depth_desc'.tr(),
            controller: depthController,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'-?\d*')),
            ],
          ),
      ],
    );
  }
}

/// Run order and the per-type mode selectors.
class BlockOrderGroup extends StatelessWidget {
  const BlockOrderGroup({
    required this.type,
    required this.generationOrder,
    required this.executionOrder,
    required this.rewriteMode,
    required this.scriptType,
    required this.apiPreset,
    required this.onGenerationOrderChanged,
    required this.onExecutionOrderChanged,
    required this.onRewriteModeChanged,
    required this.onScriptTypeChanged,
    required this.onApiPresetChanged,
    super.key,
  });

  final BlockType type;
  final BlockRunOrder generationOrder;
  final BlockRunOrder executionOrder;
  final RewriteMode rewriteMode;
  final ScriptType scriptType;
  final ConnectionProfile apiPreset;
  final ValueChanged<BlockRunOrder> onGenerationOrderChanged;
  final ValueChanged<BlockRunOrder> onExecutionOrderChanged;
  final ValueChanged<RewriteMode> onRewriteModeChanged;
  final ValueChanged<ScriptType> onScriptTypeChanged;
  final ValueChanged<ConnectionProfile> onApiPresetChanged;

  @override
  Widget build(BuildContext context) {
    final isRewrite = type == BlockType.rewrite;
    final isScript = type == BlockType.jsRunner;

    final items = <Widget>[
      if (isRewrite) ...[
        MenuSelectorItem(
          label: 'block_generation_order'.tr(),
          currentValue: runOrderLabel(generationOrder),
          onTap: () => pickBlockOption<BlockRunOrder>(
            context: context,
            title: 'block_generation_order'.tr(),
            options: BlockRunOrder.values,
            current: generationOrder,
            labelOf: runOrderLabel,
            onPicked: onGenerationOrderChanged,
          ),
        ),
        MenuSelectorItem(
          label: 'block_rewrite_mode'.tr(),
          currentValue: rewriteModeLabel(rewriteMode),
          onTap: () => pickBlockOption<RewriteMode>(
            context: context,
            title: 'block_rewrite_mode'.tr(),
            options: RewriteMode.values,
            current: rewriteMode,
            labelOf: rewriteModeLabel,
            onPicked: onRewriteModeChanged,
          ),
        ),
      ],
      if (isScript) ...[
        MenuSelectorItem(
          label: 'block_execution_order'.tr(),
          currentValue: runOrderLabel(executionOrder),
          onTap: () => pickBlockOption<BlockRunOrder>(
            context: context,
            title: 'block_execution_order'.tr(),
            options: BlockRunOrder.values,
            current: executionOrder,
            labelOf: runOrderLabel,
            onPicked: onExecutionOrderChanged,
          ),
        ),
        MenuSelectorItem(
          label: 'block_script_type'.tr(),
          currentValue: scriptTypeLabel(scriptType),
          onTap: () => pickBlockOption<ScriptType>(
            context: context,
            title: 'block_script_type'.tr(),
            options: ScriptType.values,
            current: scriptType,
            labelOf: scriptTypeLabel,
            onPicked: onScriptTypeChanged,
          ),
        ),
      ],
      MenuSelectorItem(
        label: 'block_api_preset'.tr(),
        currentValue: apiPresetLabel(apiPreset),
        onTap: () => pickBlockOption<ConnectionProfile>(
          context: context,
          title: 'block_api_preset'.tr(),
          options: ConnectionProfile.values,
          current: apiPreset,
          labelOf: apiPresetLabel,
          onPicked: onApiPresetChanged,
        ),
      ),
    ];

    return MenuGroup(header: 'block_sec_order'.tr(), items: items);
  }
}
