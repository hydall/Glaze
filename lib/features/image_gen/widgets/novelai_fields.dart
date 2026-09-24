import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';
import 'model_fields.dart';
import 'rows.dart' as rows;

/// Model-field rows for NovelAI Image Generation.
List<Widget> buildNovelAiModelFields(
  ImageGenSettings s, {
  required bool isFetching,
  required VoidCallback onFetchModels,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  final config = s.novelai;
  void update(NovelAIImageSettings next) => onUpdate(s.copyWith(novelai: next));

  final resolutionLabel = NovelAIConstants.resolutionPresets
      .firstWhere(
        (preset) => preset.$2 == config.width && preset.$3 == config.height,
        orElse: () => ('${config.width}x${config.height}', config.width, config.height),
      )
      .$1;
  final samplerLabel = NovelAIConstants.samplers
      .firstWhere(
        (sampler) => sampler.$1 == config.sampler,
        orElse: () => (config.sampler, config.sampler),
      )
      .$2;
  final ucLabel = _ucLabel(config.ucPreset);

  return [
    Row(
      children: [
        Expanded(
          child: MenuSelectorItem(
            label: 'imggen_model'.tr(),
            currentValue: NovelAIConstants.models
                .firstWhere(
                  (model) => model.$1 == config.model,
                  orElse: () => (config.model, config.model),
                )
                .$2,
            onTap: () => showOptions<String>(
              title: 'imggen_model'.tr(),
              items: NovelAIConstants.models.map((model) => model.$1).toList(),
              labelBuilder: (id) => NovelAIConstants.models
                  .firstWhere((model) => model.$1 == id)
                  .$2,
              isSelected: (id) => config.model == id,
              onSelected: (id) => update(config.copyWith(model: id)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: rows.ImageGenFetchButton(
            isFetching: isFetching,
            onPressed: onFetchModels,
          ),
        ),
      ],
    ),
    MenuSelectorItem(
      label: 'Resolution',
      currentValue: config.customSize ? customImageSizeOption : resolutionLabel,
      onTap: () => showOptions<(String, int, int)>(
        title: 'Resolution',
        items: [
          ...NovelAIConstants.resolutionPresets,
          NovelAIConstants.customResolutionPreset,
        ],
        labelBuilder: (preset) => preset.$1 == customImageSizeOption
            ? 'imggen_size_custom'.tr()
            : preset.$1,
        isSelected: (preset) => preset.$1 == customImageSizeOption
            ? config.customSize
            : !config.customSize &&
                  config.width == preset.$2 &&
                  config.height == preset.$3,
        onSelected: (preset) {
          if (preset.$1 == customImageSizeOption) {
            update(config.copyWith(customSize: true));
          } else {
            update(
              config.copyWith(
                width: preset.$2,
                height: preset.$3,
                customSize: false,
              ),
            );
          }
        },
      ),
    ),
    if (config.customSize)
      ...rows.imageGenCustomSizeFields(
        width: config.width,
        height: config.height,
        onWidthChanged: (v) => update(config.copyWith(width: v)),
        onHeightChanged: (v) => update(config.copyWith(height: v)),
      ),
    MenuSelectorItem(
      label: 'Sampler',
      currentValue: samplerLabel,
      onTap: () => showOptions<String>(
        title: 'Sampler',
        items: NovelAIConstants.samplers.map((sampler) => sampler.$1).toList(),
        labelBuilder: (id) => NovelAIConstants.samplers
            .firstWhere((sampler) => sampler.$1 == id)
            .$2,
        isSelected: (id) => config.sampler == id,
        onSelected: (id) => update(config.copyWith(sampler: id)),
      ),
    ),
    MenuSelectorItem(
      label: 'Noise schedule',
      currentValue: config.noiseSchedule,
      onTap: () => showOptions<String>(
        title: 'Noise schedule',
        items: NovelAIConstants.noiseSchedules,
        labelBuilder: (v) => v,
        isSelected: (v) => config.noiseSchedule == v,
        onSelected: (v) => update(config.copyWith(noiseSchedule: v)),
      ),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Steps',
      value: config.steps.toString(),
      hint: '28',
      onChanged: (v) =>
          update(config.copyWith(steps: _int(v, config.steps, 1, 50))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Prompt guidance',
      value: _formatDouble(config.scale),
      hint: '5',
      onChanged: (v) =>
          update(config.copyWith(scale: _double(v, config.scale, 0, 10))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'CFG rescale',
      value: _formatDouble(config.cfgRescale),
      hint: '0',
      onChanged: (v) => update(
        config.copyWith(cfgRescale: _double(v, config.cfgRescale, 0, 1)),
      ),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Seed',
      value: config.seed.toString(),
      hint: '-1',
      onChanged: (v) =>
          update(config.copyWith(seed: _int(v, config.seed, -1, 4294967295))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Negative prompt',
      value: config.negativePrompt,
      hint: 'lowres, bad anatomy',
      onChanged: (v) => update(config.copyWith(negativePrompt: v)),
    ),
    MenuSelectorItem(
      label: 'Undesired content',
      currentValue: ucLabel,
      onTap: () => showOptions<String>(
        title: 'Undesired content',
        items: const [
          'heavy',
          'light',
          'furry_focus',
          'human_focus',
          NovelAIConstants.ucPresetNone,
        ],
        labelBuilder: _ucLabel,
        isSelected: (id) => config.ucPreset == id,
        onSelected: (id) => update(config.copyWith(ucPreset: id)),
      ),
    ),
    MenuSwitchItem(
      label: 'Add quality tags',
      description: 'Appends "very aesthetic, masterpiece, no text"',
      value: config.qualityToggle,
      onChanged: (v) => update(config.copyWith(qualityToggle: v)),
    ),
    MenuSwitchItem(
      label: 'Variety boost',
      description: 'Skip CFG on the early steps for more variation',
      value: config.varietyBoost,
      onChanged: (v) => update(config.copyWith(varietyBoost: v)),
    ),
  ];
}

/// Connection-field rows for NovelAI Image Generation.
List<Widget> buildNovelAiConnectionFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'imggen_api_key'.tr(),
      value: s.novelai.apiKey,
      obscure: true,
      hint: 'pst-...',
      onChanged: (v) =>
          onUpdate(s.copyWith(novelai: s.novelai.copyWith(apiKey: v))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'imggen_endpoint'.tr(),
      value: s.novelai.endpoint,
      hint: NovelAIConstants.defaultEndpoint,
      onChanged: (v) =>
          onUpdate(s.copyWith(novelai: s.novelai.copyWith(endpoint: v))),
    ),
  ];
}

String _ucLabel(String id) {
  if (id == NovelAIConstants.ucPresetNone) return 'None';
  for (final (presetId, label, _) in NovelAIConstants.ucPresets) {
    if (presetId == id) return label;
  }
  return id;
}

int _int(String raw, int fallback, int min, int max) {
  final parsed = int.tryParse(raw.trim());
  if (parsed == null) return fallback;
  return parsed.clamp(min, max);
}

double _double(String raw, double fallback, double min, double max) {
  final parsed = double.tryParse(raw.trim().replaceAll(',', '.'));
  if (parsed == null) return fallback;
  return parsed.clamp(min, max);
}

String _formatDouble(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
