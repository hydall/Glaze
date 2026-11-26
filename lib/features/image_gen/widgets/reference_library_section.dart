import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';
import '../image_gen_capabilities.dart';
import '../image_gen_models.dart';
import 'novelai_reference_fields.dart';
import 'rows.dart' as rows;

/// How the character travels: as the avatar image, as the appearance text of
/// its card, or not at all. One picker over `sendCharAvatar` +
/// `charAppearanceSource`, so the two can never be read as both on.
enum _CharacterMode { image, text, off }

/// The References group of the image-gen sheet — every reference setting in
/// one place, split by what actually reaches the model:
///
/// - the character, as a picture or as text (one choice);
/// - **pictures**: the persona avatar, previous images, the reference library
///   and, on NovelAI, its Precise Reference settings;
/// - **text in the prompt**: the reference captions and the "copy these
///   appearances" instruction. NovelAI reads neither — it takes the pictures
///   natively and would draw the text — so there the subsection says so
///   instead of offering switches that do nothing.
///
/// A model without reference support ([maxReferences] 0) only gets the
/// character picker, with the text option.
List<Widget> buildReferencesGroup({
  required BuildContext context,
  required ImageGenSettings settings,
  required int maxReferences,
  required ValueChanged<ImageGenSettings> onUpdate,
  required Future<String?> Function() pickImage,
}) {
  final takesImages = maxReferences > 0;
  final mode = !settings.sendCharAvatar
      ? _CharacterMode.off
      : (takesImages &&
                settings.charAppearanceSource == CharacterAppearanceSource.image
            ? _CharacterMode.image
            : _CharacterMode.text);

  void setMode(_CharacterMode next) => onUpdate(switch (next) {
    _CharacterMode.image => settings.copyWith(
      sendCharAvatar: true,
      charAppearanceSource: CharacterAppearanceSource.image,
    ),
    _CharacterMode.text => settings.copyWith(
      sendCharAvatar: true,
      charAppearanceSource: CharacterAppearanceSource.description,
    ),
    _CharacterMode.off => settings.copyWith(sendCharAvatar: false),
  });

  return [
    MenuGroup(
      header: 'imggen_refs'.tr(),
      description: takesImages
          ? 'imggen_refs_desc'.tr()
          : 'imggen_refs_desc_text_only'.tr(),
      items: [
        MenuSelectorItem(
          label: 'imggen_char_mode'.tr(),
          description: switch (mode) {
            _CharacterMode.image => 'imggen_char_mode_image_desc'.tr(),
            _CharacterMode.text => 'imggen_char_mode_text_desc'.tr(),
            _CharacterMode.off => 'imggen_char_mode_off_desc'.tr(),
          },
          currentValue: _modeLabel(mode),
          onTap: () => rows.showImageGenOptions<_CharacterMode>(
            context,
            title: 'imggen_char_mode'.tr(),
            items: [
              if (takesImages) _CharacterMode.image,
              _CharacterMode.text,
              _CharacterMode.off,
            ],
            labelBuilder: _modeLabel,
            isSelected: (v) => v == mode,
            onSelected: setMode,
          ),
        ),
        if (takesImages) ...[
          ..._pictureItems(
            context: context,
            settings: settings,
            maxReferences: maxReferences,
            onUpdate: onUpdate,
            pickImage: pickImage,
          ),
          if (settings.apiType == ImageGenApiType.novelai)
            ...buildNovelAiPreciseReferenceItems(
              context: context,
              settings: settings,
              onUpdate: onUpdate,
            ),
          ..._textItems(
            context: context,
            settings: settings,
            onUpdate: onUpdate,
          ),
        ],
      ],
    ),
  ];
}

String _modeLabel(_CharacterMode mode) => switch (mode) {
  _CharacterMode.image => 'imggen_char_mode_image'.tr(),
  _CharacterMode.text => 'imggen_char_mode_text'.tr(),
  _CharacterMode.off => 'imggen_char_mode_off'.tr(),
};

/// Pictures sent as images: the persona avatar, previous images and the
/// reference library.
List<Widget> _pictureItems({
  required BuildContext context,
  required ImageGenSettings settings,
  required int maxReferences,
  required ValueChanged<ImageGenSettings> onUpdate,
  required Future<String?> Function() pickImage,
}) {
  final references = settings.references;
  final novelAiTypes =
      settings.apiType == ImageGenApiType.novelai &&
      NovelAIConstants.supportsReferences(settings.novelai.model);

  void updateRef(int index, ReferenceImage Function(ReferenceImage) mutate) {
    final copy = List<ReferenceImage>.from(references);
    copy[index] = mutate(copy[index]);
    onUpdate(settings.copyWith(references: copy));
  }

  return [
    MenuSubHeader('imggen_refs_pictures'.tr()),
    referenceCaption(context, 'imggen_refs_pictures_desc'.tr()),
    MenuSwitchItem(
      label: 'imggen_send_user_avatar'.tr(),
      description: 'imggen_send_user_avatar_desc'.tr(),
      value: settings.sendUserAvatar,
      onChanged: (v) => onUpdate(settings.copyWith(sendUserAvatar: v)),
    ),
    MenuSwitchItem(
      label: 'imggen_image_context_enabled'.tr(),
      description: 'imggen_image_context_desc'.tr(),
      value: settings.imageContextEnabled,
      onChanged: (v) => onUpdate(settings.copyWith(imageContextEnabled: v)),
    ),
    if (settings.imageContextEnabled)
      MenuSelectorItem(
        label: 'imggen_image_context_count'.tr(),
        currentValue: settings.imageContextCount.toString(),
        onTap: () => rows.showImageGenOptions<int>(
          context,
          title: 'imggen_image_context_count'.tr(),
          items: const [1, 2, 3],
          labelBuilder: (i) => i.toString(),
          isSelected: (i) => settings.imageContextCount == i,
          onSelected: (i) => onUpdate(settings.copyWith(imageContextCount: i)),
        ),
      ),
    MenuSubHeader('${'imggen_additional_refs'.tr()} · ${references.length}'),
    referenceCaption(
      context,
      'imggen_refs_limit_hint'.tr(args: ['$maxReferences', '$maxReferences']),
    ),
    for (int i = 0; i < references.length; i++)
      rows.ImageGenReferenceRow(
        key: ValueKey('ref_$i'),
        refItem: references[i],
        onNameChanged: (v) => updateRef(i, (ref) => ref.copyWith(name: v)),
        onDescriptionChanged: (v) =>
            updateRef(i, (ref) => ref.copyWith(description: v)),
        onMatchModeChanged: (v) =>
            updateRef(i, (ref) => ref.copyWith(matchMode: v)),
        onEnabledChanged: (v) =>
            updateRef(i, (ref) => ref.copyWith(enabled: v)),
        onNovelAiTypeChanged: novelAiTypes
            ? (v) => updateRef(i, (ref) => ref.copyWith(novelaiType: v))
            : null,
        novelAiTypes: novelAiTypes
            ? NovelAIConstants.referenceTypesFor(settings.novelai.model)
            : const [],
        descriptionHint: providerReadsReferenceText(settings)
            ? 'imggen_ref_description_hint'.tr()
            : 'imggen_ref_description_hint_unused'.tr(),
        onPickImage: () async {
          final imageData = await pickImage();
          if (imageData == null) return;
          updateRef(i, (ref) => ref.copyWith(imageData: imageData));
        },
        onRemove: () {
          final copy = List<ReferenceImage>.from(references)..removeAt(i);
          onUpdate(settings.copyWith(references: copy));
        },
      ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        onTap: () => onUpdate(
          settings.copyWith(
            references: [
              ...references,
              const ReferenceImage(name: '', imageData: ''),
            ],
          ),
        ),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: context.cs.primary.withValues(alpha: 0.4),
            ),
          ),
          child: Center(
            child: Text(
              '+ ${'imggen_add_ref'.tr()}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: context.cs.primary,
              ),
            ),
          ),
        ),
      ),
    ),
  ];
}

/// Text Glaze writes into the prompt about the pictures. Only offered where
/// the provider reads it ([providerReadsReferenceText]).
List<Widget> _textItems({
  required BuildContext context,
  required ImageGenSettings settings,
  required ValueChanged<ImageGenSettings> onUpdate,
}) {
  if (!providerReadsReferenceText(settings)) {
    return [
      MenuSubHeader('imggen_refs_text'.tr()),
      referenceCaption(context, 'imggen_refs_text_novelai'.tr()),
    ];
  }
  return [
    MenuSubHeader('imggen_refs_text'.tr()),
    referenceCaption(context, 'imggen_refs_text_desc'.tr()),
    MenuSwitchItem(
      label: 'imggen_send_ref_descriptions'.tr(),
      description: 'imggen_send_ref_descriptions_desc'.tr(),
      value: settings.sendRefDescriptions,
      onChanged: (v) => onUpdate(settings.copyWith(sendRefDescriptions: v)),
    ),
    MenuSwitchItem(
      label: 'imggen_ref_instruction'.tr(),
      description: 'imggen_ref_instruction_desc'.tr(),
      value: settings.refInstructionEnabled,
      onChanged: (v) => onUpdate(settings.copyWith(refInstructionEnabled: v)),
    ),
    if (settings.refInstructionEnabled)
      rows.ImageGenTextFieldItem(
        label: 'imggen_ref_instruction_text'.tr(),
        value: settings.refInstruction,
        hint: defaultReferenceInstruction,
        onChanged: (v) => onUpdate(settings.copyWith(refInstruction: v)),
      ),
  ];
}

/// A muted explanatory line under a sub-header of the References group.
Widget referenceCaption(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
  child: Text(
    text,
    style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
  ),
);
