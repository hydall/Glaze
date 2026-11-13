import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';
import 'model_fields.dart';
import 'rows.dart' as rows;

/// Connection fields for TensorArt / Tusi.
List<Widget> buildTensorArtConnectionFields(
  ImageGenSettings s,
  BuildContext context,
  ValueChanged<ImageGenSettings> onUpdate,
) {
  final config = s.tensorart;
  void update(TensorArtImageSettings next) =>
      onUpdate(s.copyWith(tensorart: next));

  return [
    rows.ImageGenTextFieldItem(
      label: 'imggen_tensorart_access_key'.tr(),
      value: config.accessKey,
      obscure: true,
      hint: 'ak_tensor_...',
      onChanged: (v) => update(config.copyWith(accessKey: v)),
    ),
    rows.ImageGenTextFieldItem(
      label: 'imggen_endpoint'.tr(),
      value: config.endpoint,
      hint: TensorArtConstants.defaultEndpoint,
      onChanged: (v) => update(config.copyWith(endpoint: v)),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        'imggen_tensorart_hint'.tr(),
        style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
      ),
    ),
  ];
}

/// Tool and parameter fields for TensorArt.
///
/// The catalog is task-based, so the visible size fields follow the selected
/// tool: the classic text-to-image tools take integer width/height, while the
/// newer ones take a `1K/2K/4K` size and an aspect ratio.
List<Widget> buildTensorArtModelFields(
  ImageGenSettings s, {
  required bool isFetching,
  required VoidCallback onFetchModels,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  final config = s.tensorart;
  void update(TensorArtImageSettings next) =>
      onUpdate(s.copyWith(tensorart: next));
  final tool = config.selectedTool;
  final showAspect = tool?.usesAspectRatio ?? true;
  final showStringSize = tool?.usesStringDimensions ?? true;
  final showIntegerSize = tool?.usesIntegerDimensions ?? true;
  final tools = config.tools.map((entry) => entry.name).toList();
  final items = tools.isEmpty ? [config.toolName] : tools;

  return [
    Row(
      children: [
        Expanded(
          child: MenuSelectorItem(
            label: 'imggen_tensorart_tool'.tr(),
            description: 'imggen_tensorart_tool_desc'.tr(),
            currentValue: config.toolLabel(config.toolName),
            onTap: () => showOptions<String>(
              title: 'imggen_tensorart_tool'.tr(),
              items: items,
              labelBuilder: config.toolLabel,
              isSelected: (name) => config.toolName == name,
              onSelected: (name) => update(config.copyWith(toolName: name)),
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
    if (showAspect)
      MenuSelectorItem(
        label: 'imggen_aspect_ratio'.tr(),
        currentValue: config.aspectRatio,
        onTap: () => showOptions<String>(
          title: 'imggen_aspect_ratio'.tr(),
          items: TensorArtConstants.aspectRatios,
          labelBuilder: (value) => value,
          isSelected: (value) => config.aspectRatio == value,
          onSelected: (value) => update(config.copyWith(aspectRatio: value)),
        ),
      ),
    if (showStringSize)
      MenuSelectorItem(
        label: 'imggen_image_size'.tr(),
        currentValue: config.imageSize,
        onTap: () => showOptions<String>(
          title: 'imggen_image_size'.tr(),
          items: TensorArtConstants.imageSizes,
          labelBuilder: (value) => value,
          isSelected: (value) => config.imageSize == value,
          onSelected: (value) => update(config.copyWith(imageSize: value)),
        ),
      ),
    if (showIntegerSize) ...[
      rows.ImageGenTextFieldItem(
        label: 'imggen_width'.tr(),
        value: config.width.toString(),
        hint: '1024',
        onChanged: (v) =>
            update(config.copyWith(width: _clampSize(v, config.width))),
      ),
      rows.ImageGenTextFieldItem(
        label: 'imggen_height'.tr(),
        value: config.height.toString(),
        hint: '1024',
        onChanged: (v) =>
            update(config.copyWith(height: _clampSize(v, config.height))),
      ),
    ],
  ];
}

int _clampSize(String raw, int fallback) {
  final parsed = int.tryParse(raw.trim());
  if (parsed == null) return fallback;
  return parsed.clamp(64, 8192);
}
