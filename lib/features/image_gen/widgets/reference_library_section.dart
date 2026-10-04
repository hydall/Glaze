import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';
import 'rows.dart' as rows;

/// Reference sections of the image-gen sheet: avatars, the shared reference
/// library and the prompt options that travel with references.
///
/// The library is one list for every provider — the number of images actually
/// sent is capped per model ([maxReferences]), following the single reference
/// library of https://github.com/0xl0cal/sillyimages.
List<Widget> buildReferenceSections({
  required BuildContext context,
  required ImageGenSettings settings,
  required int maxReferences,
  required ValueChanged<ImageGenSettings> onUpdate,
  required Future<String?> Function() pickImage,
}) {
  final references = settings.references;

  void updateRef(int index, ReferenceImage Function(ReferenceImage) mutate) {
    final copy = List<ReferenceImage>.from(references);
    copy[index] = mutate(copy[index]);
    onUpdate(settings.copyWith(references: copy));
  }

  return [
    MenuGroup(
      header: 'imggen_refs'.tr(),
      items: [
        MenuSwitchItem(
          label: 'imggen_send_char_avatar'.tr(),
          description: 'imggen_send_char_avatar_desc'.tr(),
          value: settings.sendCharAvatar,
          onChanged: (v) => onUpdate(settings.copyWith(sendCharAvatar: v)),
        ),
        MenuSwitchItem(
          label: 'imggen_send_user_avatar'.tr(),
          description: 'imggen_send_user_avatar_desc'.tr(),
          value: settings.sendUserAvatar,
          onChanged: (v) => onUpdate(settings.copyWith(sendUserAvatar: v)),
        ),
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
          onChanged: (v) =>
              onUpdate(settings.copyWith(refInstructionEnabled: v)),
        ),
        if (settings.refInstructionEnabled)
          rows.ImageGenTextFieldItem(
            label: 'imggen_ref_instruction_text'.tr(),
            value: settings.refInstruction,
            hint: defaultReferenceInstruction,
            onChanged: (v) => onUpdate(settings.copyWith(refInstruction: v)),
          ),
      ],
    ),
    MenuGroup(
      header: 'imggen_additional_refs'.tr(),
      headerTrailing: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Text(
          '${references.length}',
          style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
        ),
      ),
      items: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'imggen_refs_limit_hint'.tr(
              args: ['$maxReferences', '$maxReferences'],
            ),
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
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
      ],
    ),
  ];
}
