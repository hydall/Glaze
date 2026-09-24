import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';
import 'model_fields.dart';
import 'rows.dart' as rows;

/// Connection-field rows for a local ComfyUI server. The API key is only
/// needed when ComfyUI sits behind a basic-auth reverse proxy.
List<Widget> buildComfyUiConnectionFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'imggen_endpoint'.tr(),
      value: s.comfyui.endpoint,
      hint: ComfyUiConstants.defaultEndpoint,
      onChanged: (v) =>
          onUpdate(s.copyWith(comfyui: s.comfyui.copyWith(endpoint: v))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'imggen_comfyui_auth'.tr(),
      value: s.comfyui.apiKey,
      obscure: true,
      hint: 'user:password',
      onChanged: (v) =>
          onUpdate(s.copyWith(comfyui: s.comfyui.copyWith(apiKey: v))),
    ),
  ];
}

/// Model-field rows for ComfyUI.
///
/// Ported from SillyTavern's stable-diffusion extension: the workflow is an
/// API-format graph with `%placeholder%` tokens, and the sampler parameters
/// below are substituted into it. Checkpoints come from `/object_info`; the
/// sampler / scheduler / VAE fields stay free text because their accepted
/// values depend on the installed nodes.
List<Widget> buildComfyUiModelFields(
  ImageGenSettings s, {
  required bool isFetching,
  required VoidCallback onFetchModels,
  required VoidCallback onManageWorkflows,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  final config = s.comfyui;
  void update(ComfyUiImageSettings next) => onUpdate(s.copyWith(comfyui: next));
  final activeWorkflow = config.activeWorkflow;

  return [
    MenuSelectorItem(
      label: 'imggen_comfyui_workflow'.tr(),
      description: 'imggen_comfyui_workflow_desc'.tr(),
      currentValue:
          activeWorkflow?.name ?? 'imggen_comfyui_workflow_default'.tr(),
      onTap: onManageWorkflows,
    ),
    rows.ImageGenTextFieldItem(
      label: 'Checkpoint',
      value: config.model,
      hint: 'model.safetensors',
      onChanged: (v) => update(config.copyWith(model: v)),
      suffix: rows.ImageGenFetchButton(
        isFetching: isFetching,
        onPressed: onFetchModels,
      ),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Sampler',
      value: config.sampler,
      hint: ComfyUiConstants.defaultSampler,
      onChanged: (v) => update(config.copyWith(sampler: v)),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Scheduler',
      value: config.scheduler,
      hint: ComfyUiConstants.defaultScheduler,
      onChanged: (v) => update(config.copyWith(scheduler: v)),
    ),
    rows.ImageGenTextFieldItem(
      label: 'VAE',
      value: config.vae,
      hint: 'Automatic',
      onChanged: (v) => update(config.copyWith(vae: v)),
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
    rows.ImageGenTextFieldItem(
      label: 'Steps',
      value: config.steps.toString(),
      hint: ComfyUiConstants.defaultSteps.toString(),
      onChanged: (v) =>
          update(config.copyWith(steps: _int(v, config.steps, 1, 150))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'CFG scale',
      value: _formatDouble(config.cfgScale),
      hint: _formatDouble(ComfyUiConstants.defaultCfgScale),
      onChanged: (v) =>
          update(config.copyWith(cfgScale: _double(v, config.cfgScale, 1, 30))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Seed',
      value: config.seed.toString(),
      hint: '-1',
      onChanged: (v) =>
          update(config.copyWith(seed: _int(v, config.seed, -1, 2147483647))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'Denoise',
      value: _formatDouble(config.denoise),
      hint: _formatDouble(ComfyUiConstants.defaultDenoise),
      onChanged: (v) =>
          update(config.copyWith(denoise: _double(v, config.denoise, 0, 1))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'CLIP skip',
      value: config.clipSkip.toString(),
      hint: ComfyUiConstants.defaultClipSkip.toString(),
      onChanged: (v) =>
          update(config.copyWith(clipSkip: _int(v, config.clipSkip, 1, 12))),
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
