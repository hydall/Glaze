import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../image_gen_models.dart';
import 'rows.dart' as rows;

/// Callback for showing a single-select options bottom sheet from a
/// model-field row. Kept here so the row constructors don't have to
/// know about [BuildContext] or modal sheet plumbing.
typedef ShowOptionsCallback =
    void Function<T>({
      required String title,
      required List<T> items,
      required String Function(T) labelBuilder,
      required bool Function(T) isSelected,
      required void Function(T) onSelected,
    });

/// Model-field rows for the Naistera image-gen API.
List<Widget> buildNaisteraModelFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
  ShowOptionsCallback showOptions,
) {
  return [
    rows.ImageGenSelectorRow(
      label: 'Model',
      value: NaisteraConstants.models
          .firstWhere(
            (e) => e.$1 == s.naisteraModel,
            orElse: () => (s.naisteraModel, s.naisteraModel),
          )
          .$2,
      onTap: () => showOptions<String>(
        title: 'Model',
        items: NaisteraConstants.models.map((e) => e.$1).toList(),
        labelBuilder: (v) =>
            NaisteraConstants.models.firstWhere((e) => e.$1 == v).$2,
        isSelected: (v) => s.naisteraModel == v,
        onSelected: (v) => onUpdate(s.copyWith(naisteraModel: v)),
      ),
    ),
    rows.ImageGenSelectorRow(
      label: 'Aspect Ratio',
      value: s.naisteraAspectRatio,
      onTap: () => showOptions<String>(
        title: 'Aspect Ratio',
        items: NaisteraConstants.aspectRatios,
        labelBuilder: (v) => v,
        isSelected: (v) => s.naisteraAspectRatio == v,
        onSelected: (v) => onUpdate(s.copyWith(naisteraAspectRatio: v)),
      ),
    ),
  ];
}

/// Model-field rows for the rout.my image-gen API. The Russian variant
/// shares the same shape and only differs in the settings field it
/// writes to, controlled by [isRu].
List<Widget> buildRoutmyModelFields(
  ImageGenSettings s, {
  required bool isRu,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  final model = isRu ? s.ruRoutmyModel : s.routmyModel;
  final aspect = isRu ? s.ruRoutmyAspectRatio : s.routmyAspectRatio;
  final size = isRu ? s.ruRoutmyImageSize : s.routmyImageSize;
  final quality = isRu ? s.ruRoutmyQuality : s.routmyQuality;
  final constantsModels = isRu
      ? RuRoutMyConstants.models
      : RoutMyConstants.models;
  final aspectRatios = isRu
      ? RuRoutMyConstants.aspectRatios
      : RoutMyConstants.aspectRatios;
  final imageSizes = isRu
      ? RuRoutMyConstants.imageSizes
      : RoutMyConstants.imageSizes;
  final availableImageSizes = model == 'bytedance/seedream-5.0-pro'
      ? RoutMyConstants.seedreamImageSizes
      : imageSizes;

  return [
    rows.ImageGenSelectorRow(
      label: 'Model',
      value: constantsModels
          .firstWhere((e) => e.$1 == model, orElse: () => (model, model))
          .$2,
      onTap: () => showOptions<String>(
        title: 'Model',
        items: constantsModels.map((e) => e.$1).toList(),
        labelBuilder: (v) => constantsModels.firstWhere((e) => e.$1 == v).$2,
        isSelected: (v) => model == v,
        onSelected: (v) {
          final seedreamSize =
              v == 'bytedance/seedream-5.0-pro' &&
                  !RoutMyConstants.seedreamImageSizes.contains(size)
              ? '2K'
              : size;
          isRu
              ? onUpdate(
                  s.copyWith(ruRoutmyModel: v, ruRoutmyImageSize: seedreamSize),
                )
              : onUpdate(
                  s.copyWith(routmyModel: v, routmyImageSize: seedreamSize),
                );
        },
      ),
    ),
    rows.ImageGenSelectorRow(
      label: 'Aspect Ratio',
      value: aspect,
      onTap: () => showOptions<String>(
        title: 'Aspect Ratio',
        items: aspectRatios,
        labelBuilder: (v) => v,
        isSelected: (v) => aspect == v,
        onSelected: (v) => isRu
            ? onUpdate(s.copyWith(ruRoutmyAspectRatio: v))
            : onUpdate(s.copyWith(routmyAspectRatio: v)),
      ),
    ),
    rows.ImageGenSelectorRow(
      label: 'Resolution',
      value: size,
      onTap: () => showOptions<String>(
        title: 'Resolution',
        items: availableImageSizes,
        labelBuilder: (v) => v,
        isSelected: (v) => size == v,
        onSelected: (v) => isRu
            ? onUpdate(s.copyWith(ruRoutmyImageSize: v))
            : onUpdate(s.copyWith(routmyImageSize: v)),
      ),
    ),
    if (model != 'bytedance/seedream-5.0-pro')
      rows.ImageGenSelectorRow(
        label: 'Quality',
        value: quality == 'hd' ? 'HD' : 'Standard',
        onTap: () => showOptions<String>(
          title: 'Quality',
          items: ['standard', 'hd'],
          labelBuilder: (v) => v == 'hd' ? 'HD' : 'Standard',
          isSelected: (v) => quality == v,
          onSelected: (v) => isRu
              ? onUpdate(s.copyWith(ruRoutmyQuality: v))
              : onUpdate(s.copyWith(routmyQuality: v)),
        ),
      ),
  ];
}

/// Model-field rows for the OpenAI image-gen API. The "fetch models"
/// suffix is rendered inline — the spinner is bound to [isFetching]
/// and the refresh icon calls [onFetchModels].
List<Widget> buildOpenaiModelFields(
  BuildContext context,
  ImageGenSettings s, {
  required bool isFetching,
  required VoidCallback onFetchModels,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'Model',
      value: s.customModel,
      hint: 'dall-e-3',
      onChanged: (v) => onUpdate(s.copyWith(customModel: v)),
      suffix: InkWell(
        onTap: onFetchModels,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: context.cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.black12),
          ),
          child: isFetching
              ? const Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Icon(Icons.refresh, size: 18, color: context.cs.primary),
        ),
      ),
    ),
    rows.ImageGenSelectorRow(
      label: 'Image Size',
      value: s.openaiSize,
      onTap: () => showOptions<String>(
        title: 'Image Size',
        items: OpenAIConstants.sizes,
        labelBuilder: (v) => v,
        isSelected: (v) => s.openaiSize == v,
        onSelected: (v) => onUpdate(s.copyWith(openaiSize: v)),
      ),
    ),
    rows.ImageGenSelectorRow(
      label: 'Quality',
      value: s.openaiQuality == 'hd' ? 'HD' : 'Standard',
      onTap: () => showOptions<String>(
        title: 'Quality',
        items: OpenAIConstants.qualities,
        labelBuilder: (v) => v == 'hd' ? 'HD' : 'Standard',
        isSelected: (v) => s.openaiQuality == v,
        onSelected: (v) => onUpdate(s.copyWith(openaiQuality: v)),
      ),
    ),
  ];
}

/// Model-field rows for the Gemini image-gen API. Currently Gemini is
/// the default `else` branch — it shares the openai-compatible
/// connection path but uses its own aspect-ratio and resolution lists.
List<Widget> buildGeminiModelFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
  ShowOptionsCallback showOptions,
) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'Model',
      value: s.customModel,
      hint: 'imagen-3.0-generate-002',
      onChanged: (v) => onUpdate(s.copyWith(customModel: v)),
    ),
    rows.ImageGenSelectorRow(
      label: 'Aspect Ratio',
      value: s.geminiAspectRatio,
      onTap: () => showOptions<String>(
        title: 'Aspect Ratio',
        items: GeminiConstants.aspectRatios,
        labelBuilder: (v) => v,
        isSelected: (v) => s.geminiAspectRatio == v,
        onSelected: (v) => onUpdate(s.copyWith(geminiAspectRatio: v)),
      ),
    ),
    rows.ImageGenSelectorRow(
      label: 'Resolution',
      value: s.geminiImageSize,
      onTap: () => showOptions<String>(
        title: 'Resolution',
        items: GeminiConstants.imageSizes,
        labelBuilder: (v) => v,
        isSelected: (v) => s.geminiImageSize == v,
        onSelected: (v) => onUpdate(s.copyWith(geminiImageSize: v)),
      ),
    ),
  ];
}
