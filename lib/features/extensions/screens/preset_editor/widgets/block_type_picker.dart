import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../../shared/widgets/menu_group.dart';
import '../../../models/block_config.dart';
import '../sections/upstream_block_sections.dart';

/// Human-readable name of a block type.
String blockTypeLabel(BlockType type) => switch (type) {
  BlockType.generated => 'block_type_generated'.tr(),
  BlockType.script => 'block_type_script'.tr(),
  BlockType.rewrite => 'block_type_rewrite'.tr(),
  BlockType.accumulation => 'block_type_accumulation'.tr(),
};

/// What a block type does, in one line, under its name in the picker.
String blockTypeDescription(BlockType type) => switch (type) {
  BlockType.generated => 'block_type_generated_desc'.tr(),
  BlockType.script => 'block_type_script_desc'.tr(),
  BlockType.rewrite => 'block_type_rewrite_desc'.tr(),
  BlockType.accumulation => 'block_type_accumulation_desc'.tr(),
};

/// Type row for the block editor.
///
/// There are four types again, and they differ in what the block *does* rather
/// than in what is done with its result: a generated block that draws a picture
/// or opens a panel is the same type as one that writes a card, so those
/// choices live further down the editor instead of here.
class BlockTypePicker extends StatelessWidget {
  const BlockTypePicker({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final BlockType selected;
  final ValueChanged<BlockType> onChanged;

  @override
  Widget build(BuildContext context) {
    return MenuSelectorItem(
      label: 'block_type_label'.tr(),
      currentValue: blockTypeLabel(selected),
      description: selected.isRunnable
          ? blockTypeDescription(selected)
          : 'extblocks_not_executed'.tr(),
      onTap: () => pickBlockOption<BlockType>(
        context: context,
        title: 'block_type_label'.tr(),
        options: BlockType.values,
        current: selected,
        labelOf: blockTypeLabel,
        onPicked: onChanged,
      ),
    );
  }
}
