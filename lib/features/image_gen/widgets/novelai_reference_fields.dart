import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';
import 'rows.dart' as rows;

/// NovelAI Precise Reference settings
/// (https://docs.novelai.net/en/image/precisereference/): what the references
/// carry over — the character, the style, both, or on V5 the outfit — and how
/// strongly.
///
/// The type is the default for every reference; a library entry can pick its
/// own, so a character and a style reference can be mixed. The controls follow
/// the model: V4.5 has Strength up to 1 and Fidelity, V5 has Strength up to 5,
/// Outfit and "Prefer same outfit". Shown only when the model takes references.
List<Widget> buildNovelAiPreciseReferenceSection({
  required BuildContext context,
  required ImageGenSettings settings,
  required ValueChanged<ImageGenSettings> onUpdate,
}) {
  final config = settings.novelai;
  final model = config.model;
  if (!NovelAIConstants.supportsReferences(model)) return const [];

  void update(NovelAIImageSettings next) =>
      onUpdate(settings.copyWith(novelai: next));

  final types = NovelAIConstants.referenceTypesFor(model);
  final type = NovelAIConstants.effectiveReferenceType(
    model,
    config.referenceType,
  );

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
            items: [for (final (id, _) in types) id],
            labelBuilder: rows.novelAiReferenceTypeLabel,
            isSelected: (id) => id == type,
            // As on NovelAI's site, picking a type resets "Prefer same
            // outfit" to on for Character & Style and off otherwise.
            onSelected: (id) => update(
              config.copyWith(
                referenceType: id,
                referenceSameOutfit:
                    id == NovelAIConstants.referenceTypeCharacterStyle,
              ),
            ),
          ),
        ),
        if (NovelAIConstants.referenceHasOutfitChoice(model, type))
          MenuSwitchItem(
            label: 'imggen_nai_ref_same_outfit'.tr(),
            description: 'imggen_nai_ref_same_outfit_desc'.tr(),
            value: config.referenceSameOutfit,
            onChanged: (v) => update(config.copyWith(referenceSameOutfit: v)),
          ),
        _valueSlider(
          label: 'imggen_nai_ref_strength'.tr(),
          description: 'imggen_nai_ref_strength_desc'.tr(),
          value: config.referenceStrength,
          max: NovelAIConstants.referenceStrengthMax(model),
          onChanged: (v) => update(config.copyWith(referenceStrength: v)),
        ),
        if (NovelAIConstants.referenceSupportsFidelity(model))
          _valueSlider(
            label: 'imggen_nai_ref_fidelity'.tr(),
            description: 'imggen_nai_ref_fidelity_desc'.tr(),
            value: config.referenceFidelity,
            max: NovelAIConstants.referenceFidelityMax,
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
  required double max,
  required ValueChanged<double> onChanged,
}) {
  const min = NovelAIConstants.referenceValueMin;
  final clamped = value.clamp(min, max).toDouble();
  return MenuRangeItem(
    label: label,
    description: description,
    value: clamped,
    min: min,
    max: max,
    divisions: ((max - min) * 100).round(),
    editableValue: true,
    onChanged: onChanged,
    onReset: clamped == 1.0 ? null : () => onChanged(1.0),
  );
}
