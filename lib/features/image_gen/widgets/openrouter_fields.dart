import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_capabilities.dart';
import '../image_gen_models.dart';
import 'model_fields.dart';
import 'rows.dart' as rows;

/// Model-field rows for OpenRouter.
///
/// The aspect-ratio and resolution lists follow the selected model: Gemini
/// models take an `image_size`, FLUX and friends do not (see
/// [openRouterCapabilities]).
List<Widget> buildOpenRouterModelFields(
  ImageGenSettings s, {
  required bool isFetching,
  required VoidCallback onFetchModels,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  final config = s.openrouter;
  final caps = openRouterCapabilities(config.model);

  return [
    rows.ImageGenTextFieldItem(
      label: 'Model',
      value: config.model,
      hint: 'google/gemini-2.5-flash-image',
      onChanged: (v) =>
          onUpdate(s.copyWith(openrouter: config.copyWith(model: v))),
      suffix: rows.ImageGenFetchButton(
        isFetching: isFetching,
        onPressed: onFetchModels,
      ),
    ),
    MenuSelectorItem(
      label: 'Aspect Ratio',
      currentValue: config.aspectRatio,
      onTap: () => showOptions<String>(
        title: 'Aspect Ratio',
        items: caps.aspectRatios,
        labelBuilder: (v) => v,
        isSelected: (v) => config.aspectRatio == v,
        onSelected: (v) =>
            onUpdate(s.copyWith(openrouter: config.copyWith(aspectRatio: v))),
      ),
    ),
    if (caps.imageSizes != null)
      MenuSelectorItem(
        label: 'Resolution',
        currentValue: config.imageSize == customImageSizeOption
            ? customImageSizeOption
            : config.imageSize,
        onTap: () => showOptions<String>(
          title: 'Resolution',
          items: [...caps.imageSizes!, customImageSizeOption],
          labelBuilder: (v) =>
              v == customImageSizeOption ? 'imggen_size_custom'.tr() : v,
          isSelected: (v) => config.imageSize == v,
          onSelected: (v) =>
              onUpdate(s.copyWith(openrouter: config.copyWith(imageSize: v))),
        ),
      ),
    if (caps.imageSizes != null && config.imageSize == customImageSizeOption)
      ...rows.imageGenCustomSizeFields(
        width: config.customWidth,
        height: config.customHeight,
        onWidthChanged: (v) =>
            onUpdate(s.copyWith(openrouter: config.copyWith(customWidth: v))),
        onHeightChanged: (v) =>
            onUpdate(s.copyWith(openrouter: config.copyWith(customHeight: v))),
      ),
  ];
}

/// Model-field rows for Electron Hub. It speaks the OpenAI images API, so the
/// aspect ratio is mapped to a `size` per model family at request time; the
/// explicit size below is the fallback for families without a mapping.
List<Widget> buildElectronHubModelFields(
  ImageGenSettings s, {
  required bool isFetching,
  required VoidCallback onFetchModels,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  final config = s.electronhub;

  return [
    rows.ImageGenTextFieldItem(
      label: 'Model',
      value: config.model,
      hint: 'gpt-image-1',
      onChanged: (v) =>
          onUpdate(s.copyWith(electronhub: config.copyWith(model: v))),
      suffix: rows.ImageGenFetchButton(
        isFetching: isFetching,
        onPressed: onFetchModels,
      ),
    ),
    MenuSelectorItem(
      label: 'Image Size',
      currentValue: config.size == customImageSizeOption
          ? customImageSizeOption
          : config.size,
      onTap: () => showOptions<String>(
        title: 'Image Size',
        items: [...ElectronHubConstants.sizes, customImageSizeOption],
        labelBuilder: (v) =>
            v == customImageSizeOption ? 'imggen_size_custom'.tr() : v,
        isSelected: (v) => config.size == v,
        onSelected: (v) =>
            onUpdate(s.copyWith(electronhub: config.copyWith(size: v))),
      ),
    ),
    if (config.size == customImageSizeOption)
      ...rows.imageGenCustomSizeFields(
        width: config.customWidth,
        height: config.customHeight,
        onWidthChanged: (v) =>
            onUpdate(s.copyWith(electronhub: config.copyWith(customWidth: v))),
        onHeightChanged: (v) =>
            onUpdate(s.copyWith(electronhub: config.copyWith(customHeight: v))),
      ),
    MenuSelectorItem(
      label: 'Quality',
      currentValue: config.quality == 'hd' ? 'HD' : 'Standard',
      onTap: () => showOptions<String>(
        title: 'Quality',
        items: ElectronHubConstants.qualities,
        labelBuilder: (v) => v == 'hd' ? 'HD' : 'Standard',
        isSelected: (v) => config.quality == v,
        onSelected: (v) =>
            onUpdate(s.copyWith(electronhub: config.copyWith(quality: v))),
      ),
    ),
  ];
}
