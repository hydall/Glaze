import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/api_config.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';

/// One parameter in the slot settings sheet: an "Override selected preset
/// value" switch, and under it either the editable control or a read-only row
/// showing what the slot inherits instead.
///
/// Returns the pair as a list so call sites can spread it straight into a
/// [MenuGroup]'s `items`.
List<Widget> studioSlotOverrideBlock({
  required String label,
  required bool overridden,
  required ValueChanged<bool> onOverrideChanged,
  required String inheritedValue,
  required Widget editor,
}) => [
  MenuSwitchItem(
    label: 'studio_slot_override_preset'.tr(),
    value: overridden,
    onChanged: onOverrideChanged,
  ),
  if (overridden)
    editor
  else
    StudioSlotInheritedRow(label: label, value: inheritedValue),
];

/// Read-only counterpart of [MenuSelectorItem]: same boxed field, muted text,
/// no chevron and no tap target. Shows the value the request will carry while
/// the parameter is not overridden.
class StudioSlotInheritedRow extends StatelessWidget {
  final String label;
  final String value;

  const StudioSlotInheritedRow({
    super.key,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            height: 46,
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: const Color(0xFF252525),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              value,
              style: TextStyle(
                color: context.cs.onSurface.withValues(alpha: 0.45),
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Formats what a slot inherits when a parameter is not overridden.
///
/// Sampling and reasoning parameters come from the API preset selected for the
/// slot, so the concrete value can be shown. Temperature, max tokens and the
/// timeout fall back to the per-agent spec instead — a slot can cover several
/// agents with different specs, so there is no single number to print and
/// [agentDefault] is used for those.
class StudioSlotInheritedValues {
  final ApiConfig? preset;

  const StudioSlotInheritedValues(this.preset);

  String get agentDefault => 'studio_slot_override_agent_default'.tr();

  String _wrap(String value) => 'studio_slot_override_preset_value'.tr(
    namedArgs: {'value': value},
  );

  String _omitted() => 'studio_slot_override_preset_omitted'.tr();

  String _number(double value, {int decimals = 2}) {
    final text = value.toStringAsFixed(decimals);
    if (decimals == 0) return text;
    final trimmed = text.replaceAll(RegExp(r'0+$'), '');
    return trimmed.endsWith('.') ? '${trimmed}0' : trimmed;
  }

  String _resolve(
    String Function(ApiConfig config) read, {
    bool omitted = false,
  }) {
    final config = preset;
    if (config == null) return 'studio_slot_override_preset_missing'.tr();
    if (omitted) return _omitted();
    return _wrap(read(config));
  }

  String get topP => _resolve(
    (c) => _number(c.topP),
    omitted: preset?.omitTopP ?? false,
  );

  String get topK => _resolve(
    (c) => _number(c.topK.toDouble(), decimals: 0),
    omitted: preset?.omitTopK ?? false,
  );

  String get frequencyPenalty => _resolve(
    (c) => _number(c.frequencyPenalty),
    omitted: preset?.omitFrequencyPenalty ?? false,
  );

  String get presencePenalty => _resolve(
    (c) => _number(c.presencePenalty),
    omitted: preset?.omitPresencePenalty ?? false,
  );

  String get useResponsesApi => _resolve((c) => _onOff(c.useResponsesApi));

  String get showNativeReasoning =>
      _resolve((c) => _onOff(c.showNativeReasoning));

  String get requestReasoning =>
      _resolve((c) => _onOff(c.requestReasoning && !c.omitReasoning));

  String get reasoningEffort => _resolve(
    (c) => c.reasoningEffort,
    omitted: preset?.omitReasoningEffort ?? false,
  );

  String _onOff(bool value) => value
      ? 'studio_slot_override_on'.tr()
      : 'studio_slot_override_off'.tr();
}
