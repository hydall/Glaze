import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';
import 'rows.dart' as rows;

/// NovelAI Precise Reference settings
/// (https://docs.novelai.net/en/image/precisereference/): what the references
/// carry over — the character, the style or both — and how strongly.
///
/// The type is the default for every reference; a library entry can pick its
/// own, so a character and a style reference can be mixed. Shown only when the
/// model takes references (V4.5).
List<Widget> buildNovelAiPreciseReferenceSection({
  required BuildContext context,
  required ImageGenSettings settings,
  required ValueChanged<ImageGenSettings> onUpdate,
}) {
  final config = settings.novelai;
  if (!NovelAIConstants.supportsReferences(config.model)) return const [];

  void update(NovelAIImageSettings next) =>
      onUpdate(settings.copyWith(novelai: next));

  final type = NovelAIConstants.normalizeReferenceType(config.referenceType);

  return [
    MenuGroup(
      header: 'imggen_nai_ref_title'.tr(),
      description: 'imggen_nai_ref_desc'.tr(),
      items: [
        MenuSelectorItem(
          label: 'imggen_nai_ref_type'.tr(),
          currentValue: rows.novelAiReferenceTypeLabel(type),
          onTap: () => rows.showImageGenOptions<String>(
            context,
            title: 'imggen_nai_ref_type'.tr(),
            items: [for (final (id, _) in NovelAIConstants.referenceTypes) id],
            labelBuilder: rows.novelAiReferenceTypeLabel,
            isSelected: (id) => id == type,
            onSelected: (id) => update(config.copyWith(referenceType: id)),
          ),
        ),
        _valueSlider(
          label: 'imggen_nai_ref_strength'.tr(),
          description: 'imggen_nai_ref_strength_desc'.tr(),
          value: config.referenceStrength,
          onChanged: (v) => update(config.copyWith(referenceStrength: v)),
        ),
        _valueSlider(
          label: 'imggen_nai_ref_fidelity'.tr(),
          description: 'imggen_nai_ref_fidelity_desc'.tr(),
          value: config.referenceFidelity,
          onChanged: (v) => update(config.copyWith(referenceFidelity: v)),
        ),
      ],
    ),
  ];
}

/// A Strength / Fidelity slider. Both default to 1 and accept negative values,
/// as NovelAI's own number field does.
Widget _valueSlider({
  required String label,
  required String description,
  required double value,
  required ValueChanged<double> onChanged,
}) {
  final clamped = value
      .clamp(
        NovelAIConstants.referenceValueMin,
        NovelAIConstants.referenceValueMax,
      )
      .toDouble();
  return MenuRangeItem(
    label: label,
    description: description,
    value: clamped,
    min: NovelAIConstants.referenceValueMin,
    max: NovelAIConstants.referenceValueMax,
    divisions: 200,
    editableValue: true,
    onChanged: onChanged,
    onReset: clamped == 1.0 ? null : () => onChanged(1.0),
  );
}
