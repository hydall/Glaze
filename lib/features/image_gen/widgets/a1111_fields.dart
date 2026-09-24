import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';
import 'model_fields.dart';
import 'rows.dart' as rows;

/// Model-field rows for AUTOMATIC1111 / Forge / reForge.
///
/// Ported from https://github.com/0xl0cal/sillyimages (`src/providers.js`,
/// `A1111Provider`). Local Stable Diffusion backends want a tag-style prompt,
/// so the tag prefix and negative prompt below take the place of the style
/// block used by the hosted providers.
List<Widget> buildA1111ModelFields(
  ImageGenSettings s, {
  required bool isFetching,
  required VoidCallback onFetchModels,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  final config = s.a1111;
  void update(A1111ImageSettings next) => onUpdate(s.copyWith(a1111: next));

  return [
    rows.ImageGenTextFieldItem(
      label: 'Checkpoint',
      value: config.model,
      hint: 'currently loaded',
      onChanged: (v) => update(config.copyWith(model: v)),
      suffix: rows.ImageGenFetchButton(
        isFetching: isFetching,
        onPressed: onFetchModels,
      ),
    ),
    MenuSelectorItem(
      label: 'Resolution',
      currentValue: config.customSize
          ? customImageSizeOption
          : '${config.width}x${config.height}',
      onTap: () => showOptions<(String, int, int, String)>(
        title: 'Resolution',
        items: [
          ...A1111Constants.resolutionPresets,
          A1111Constants.customResolutionPreset,
        ],
        labelBuilder: (preset) => preset.$1 == customImageSizeOption
            ? 'imggen_size_custom'.tr()
            : preset.$4,
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
      currentValue: config.sampler,
      onTap: () => showOptions<String>(
        title: 'Sampler',
        items: A1111Constants.samplers,
        labelBuilder: (v) => v,
        isSelected: (v) => config.sampler == v,
        onSelected: (v) => update(config.copyWith(sampler: v)),
      ),
    ),
    MenuSelectorItem(
      label: 'Scheduler',
      currentValue: config.scheduler,
      onTap: () => showOptions<String>(
        title: 'Scheduler',
        items: A1111Constants.schedulers,
        labelBuilder: (v) => v,
        isSelected: (v) => config.scheduler == v,
        onSelected: (v) => update(config.copyWith(scheduler: v)),
      ),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Steps',
      value: config.steps.toString(),
      hint: '20',
      onChanged: (v) =>
          update(config.copyWith(steps: _int(v, config.steps, 1, 150))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'CFG scale',
      value: _formatDouble(config.cfgScale),
      hint: '7',
      onChanged: (v) =>
          update(config.copyWith(cfgScale: _double(v, config.cfgScale, 1, 30))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'CLIP skip',
      value: config.clipSkip.toString(),
      hint: '1',
      onChanged: (v) =>
          update(config.copyWith(clipSkip: _int(v, config.clipSkip, 1, 12))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Seed',
      value: config.seed.toString(),
      hint: '-1',
      onChanged: (v) =>
          update(config.copyWith(seed: _int(v, config.seed, -1, 2147483647))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Prompt prefix',
      value: config.promptPrefix,
      hint: 'masterpiece, best quality',
      onChanged: (v) => update(config.copyWith(promptPrefix: v)),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Negative prompt',
      value: config.negativePrompt,
      hint: 'lowres, bad anatomy',
      onChanged: (v) => update(config.copyWith(negativePrompt: v)),
    ),
    rows.ImageGenTextFieldItem(
      label: 'VAE',
      value: config.vae,
      hint: 'Automatic',
      onChanged: (v) => update(config.copyWith(vae: v)),
    ),
    MenuSwitchItem(
      label: 'Restore faces',
      value: config.restoreFaces,
      onChanged: (v) => update(config.copyWith(restoreFaces: v)),
    ),
    MenuSwitchItem(
      label: 'ADetailer (face)',
      description: 'Runs the face_yolov8n ADetailer pass after generation',
      value: config.adetailerFace,
      onChanged: (v) => update(config.copyWith(adetailerFace: v)),
    ),
    MenuSwitchItem(
      label: 'Hires. fix',
      value: config.enableHr,
      onChanged: (v) => update(config.copyWith(enableHr: v)),
    ),
    if (config.enableHr) ...[
      rows.ImageGenTextFieldItem(
        label: 'Upscaler',
        value: config.hrUpscaler,
        hint: 'Latent',
        onChanged: (v) => update(config.copyWith(hrUpscaler: v)),
      ),
      rows.ImageGenTextFieldItem(
        label: 'Upscale by',
        value: _formatDouble(config.hrScale),
        hint: '2',
        onChanged: (v) =>
            update(config.copyWith(hrScale: _double(v, config.hrScale, 1, 4))),
      ),
      rows.ImageGenTextFieldItem(
        label: 'Denoising strength',
        value: _formatDouble(config.denoisingStrength),
        hint: '0.7',
        onChanged: (v) => update(
          config.copyWith(
            denoisingStrength: _double(v, config.denoisingStrength, 0, 1),
          ),
        ),
      ),
      rows.ImageGenTextFieldItem(
        label: 'Hires steps',
        value: config.hrSecondPassSteps.toString(),
        hint: '0',
        onChanged: (v) => update(
          config.copyWith(
            hrSecondPassSteps: _int(v, config.hrSecondPassSteps, 0, 150),
          ),
        ),
      ),
    ],
  ];
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
