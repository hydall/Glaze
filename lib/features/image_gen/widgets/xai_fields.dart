import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';
import 'model_fields.dart';
import 'rows.dart' as rows;

/// Connection-field rows for xAI Imagine. The endpoint is optional — empty
/// falls back to `https://api.x.ai`, so an xAI-compatible proxy can be pointed
/// at without any other change.
List<Widget> buildXaiConnectionFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'imggen_api_key'.tr(),
      value: s.xai.apiKey,
      obscure: true,
      hint: 'xai-...',
      onChanged: (v) => onUpdate(s.copyWith(xai: s.xai.copyWith(apiKey: v))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'imggen_endpoint'.tr(),
      value: s.xai.endpoint,
      hint: XaiConstants.defaultEndpoint,
      onChanged: (v) => onUpdate(s.copyWith(xai: s.xai.copyWith(endpoint: v))),
    ),
  ];
}

/// Model-field rows for xAI Imagine. `quality` is only offered for the model
/// family that accepts it — see [XaiConstants.supportsQuality].
List<Widget> buildXaiModelFields(
  ImageGenSettings s, {
  required bool isFetching,
  required VoidCallback onFetchModels,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  final config = s.xai;

  return [
    rows.ImageGenTextFieldItem(
      label: 'imggen_model'.tr(),
      value: config.model,
      hint: 'grok-imagine-image-2.0',
      onChanged: (v) => onUpdate(s.copyWith(xai: config.copyWith(model: v))),
      suffix: rows.ImageGenFetchButton(
        isFetching: isFetching,
        onPressed: onFetchModels,
      ),
    ),
    MenuSelectorItem(
      label: 'imggen_aspect_ratio'.tr(),
      currentValue: config.aspectRatio,
      onTap: () => showOptions<String>(
        title: 'imggen_aspect_ratio'.tr(),
        items: XaiConstants.aspectRatios,
        labelBuilder: (v) => v,
        isSelected: (v) => config.aspectRatio == v,
        onSelected: (v) =>
            onUpdate(s.copyWith(xai: config.copyWith(aspectRatio: v))),
      ),
    ),
    MenuSelectorItem(
      label: 'imggen_image_size'.tr(),
      currentValue: config.resolution == customImageSizeOption
          ? customImageSizeOption
          : config.resolution.toUpperCase(),
      onTap: () => showOptions<String>(
        title: 'imggen_image_size'.tr(),
        items: [...XaiConstants.resolutions, customImageSizeOption],
        labelBuilder: (v) => v == customImageSizeOption
            ? 'imggen_size_custom'.tr()
            : v.toUpperCase(),
        isSelected: (v) => config.resolution == v,
        onSelected: (v) =>
            onUpdate(s.copyWith(xai: config.copyWith(resolution: v))),
      ),
    ),
    if (config.resolution == customImageSizeOption)
      ...rows.imageGenCustomSizeFields(
        width: config.customWidth,
        height: config.customHeight,
        onWidthChanged: (v) =>
            onUpdate(s.copyWith(xai: config.copyWith(customWidth: v))),
        onHeightChanged: (v) =>
            onUpdate(s.copyWith(xai: config.copyWith(customHeight: v))),
      ),
    if (XaiConstants.supportsQuality(config.model))
      MenuSelectorItem(
        label: 'imggen_quality'.tr(),
        currentValue: config.quality == 'low'
            ? 'imggen_quality_low'.tr()
            : 'imggen_quality_medium'.tr(),
        onTap: () => showOptions<String>(
          title: 'imggen_quality'.tr(),
          items: XaiConstants.qualities,
          labelBuilder: (v) => v == 'low'
              ? 'imggen_quality_low'.tr()
              : 'imggen_quality_medium'.tr(),
          isSelected: (v) => config.quality == v,
          onSelected: (v) =>
              onUpdate(s.copyWith(xai: config.copyWith(quality: v))),
        ),
      ),
  ];
}
